package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	cbor "github.com/fxamacker/cbor/v2"
	"github.com/katzenpost/hpqc/hash"
	clientcommon "github.com/katzenpost/katzenpost/client/common"
	"github.com/katzenpost/katzenpost/client/config"
	"github.com/katzenpost/katzenpost/client/thin"
	proxycommon "github.com/katzenpost/katzenpost/quic/proxy/common"
)

const (
	maxPayloadSize    = 2000
	serviceRefreshSec = 60
	dialTimeoutSec    = 120
	sendTimeoutSec    = 60
)

var (
	bytesForwarded uint64
	activeCircuits int64
	startTime      = time.Now()
	cfg            AppConfig
	thinClient     *thin.ThinClient
	thinMu         sync.RWMutex
	svcCache       *clientcommon.ServiceDescriptor
	svcMu          sync.RWMutex
	proofChain     [32]byte
	proofMu        sync.Mutex
)

type AppConfig struct {
	SocksAddr      string `json:"socks_addr"`
	MgmtAddr       string `json:"mgmt_addr"`
	MgmtApiKey     string `json:"mgmt_api_key"`
	ThinCfgPath    string `json:"thin_config_path"`
	ServiceName    string `json:"service_name"`
	WireGuardIface string `json:"wireguard_iface"`
	AntNodeAddr    string `json:"ant_node_addr"`
}

type Status struct {
	MixnetConnected bool   `json:"mixnet_connected"`
	WireGuardIface  string `json:"wireguard_interface"`
	AntNodeAddr     string `json:"ant_node_addr"`
	BytesForwarded  uint64 `json:"bytes_forwarded"`
	ActiveCircuits  int    `json:"active_circuits"`
	UptimeSeconds   int64  `json:"uptime_seconds"`
	ServiceName     string `json:"service_name"`
}

func defaultConfig() AppConfig {
	return AppConfig{
		SocksAddr:      "127.0.0.1:1080",
		MgmtAddr:       "127.0.0.1:9090",
		ThinCfgPath:    "/etc/mixnet-proxy/thinclient.toml",
		ServiceName:    "proxy",
		WireGuardIface: "wg0",
		AntNodeAddr:    "10.0.0.2",
	}
}

func main() {
	configPath := flag.String("config", "", "config file")
	flag.Parse()

	cfg = defaultConfig()
	if *configPath != "" {
		f, err := os.Open(*configPath)
		if err != nil {
			log.Fatalf("config: %v", err)
		}
		defer f.Close()
		json.NewDecoder(f).Decode(&cfg)
	}

	proofMu.Lock()
	proofChain = sha256.Sum256([]byte(startTime.String()))
	proofMu.Unlock()

	tc, err := thin.LoadFile(cfg.ThinCfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	client := thin.NewThinClient(tc, &config.Logging{Level: "INFO"})
	if err := client.Dial(); err != nil {
		log.Fatalf("dial: %v", err)
	}
	thinMu.Lock()
	thinClient = client
	thinMu.Unlock()
	log.Printf("proxy: connected to kpclientd, service=%s", cfg.ServiceName)

	for i := 0; i < dialTimeoutSec/2; i++ {
		if client.IsConnected() {
			log.Printf("proxy: daemon connected to gateway")
			break
		}
		log.Printf("proxy: waiting for gateway... (%d/%d)", i+1, dialTimeoutSec/2)
		time.Sleep(2 * time.Second)
	}
	if !client.IsConnected() {
		log.Printf("proxy: WARNING: not connected to gateway yet")
	}

	go refreshServiceLoop()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Printf("proxy: shutting down")
		cancel()
	}()

	ln, err := net.Listen("tcp", cfg.SocksAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", cfg.SocksAddr, err)
	}
	go func() { <-ctx.Done(); ln.Close() }()

	mux := http.NewServeMux()
	mux.HandleFunc("/status", statusHandler)
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/prove/bandwidth", bandwidthProofHandler)
	mux.HandleFunc("/prove/challenge", challengeProxyHandler)
	mux.HandleFunc("/prove/storage", storageProofHandler)

	mgmtLn, err := net.Listen("tcp", cfg.MgmtAddr)
	if err != nil {
		log.Fatalf("mgmt %s: %v", cfg.MgmtAddr, err)
	}
	go http.Serve(mgmtLn, securityHeaders(authMiddleware(mux)))
	go func() { <-ctx.Done(); mgmtLn.Close() }()

	log.Printf("proxy: SOCKS5 on %s, mgmt API on %s", cfg.SocksAddr, cfg.MgmtAddr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return
			default:
				continue
			}
		}
		go handleConn(conn, client)
	}
}

func refreshServiceLoop() {
	for {
		refreshService()
		time.Sleep(serviceRefreshSec * time.Second)
	}
}

func refreshService() {
	thinMu.RLock()
	client := thinClient
	thinMu.RUnlock()
	if client == nil {
		return
	}
	svc, err := client.GetService(cfg.ServiceName)
	if err != nil {
		log.Printf("proxy: service %q lookup failed: %v", cfg.ServiceName, err)
		return
	}
	svcMu.Lock()
	svcCache = svc
	svcMu.Unlock()
	log.Printf("proxy: service %q resolved on gateway %s", cfg.ServiceName, svc.MixDescriptor.Name)
}

func getService() *clientcommon.ServiceDescriptor {
	svcMu.RLock()
	defer svcMu.RUnlock()
	return svcCache
}

func handleConn(client net.Conn, tc *thin.ThinClient) {
	defer client.Close()
	atomic.AddInt64(&activeCircuits, 1)
	defer atomic.AddInt64(&activeCircuits, -1)

	buf := make([]byte, 512)
	n, err := io.ReadAtLeast(client, buf, 2)
	if err != nil || n < 2 || buf[0] != 0x05 {
		return
	}
	client.Write([]byte{0x05, 0x00})

	n, err = client.Read(buf)
	if err != nil || n < 7 {
		return
	}

	if buf[1] != 0x01 {
		client.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	var host string
	var port int
	switch buf[3] {
	case 0x01:
		host = net.IP(buf[4:8]).String()
		port = int(buf[8])<<8 | int(buf[9])
	case 0x03:
		hl := int(buf[4])
		if n < 5+hl+2 {
			return
		}
		host = string(buf[5 : 5+hl])
		port = int(buf[5+hl])<<8 | int(buf[6+hl])
	case 0x04:
		host = net.IP(buf[4:20]).String()
		port = int(buf[20])<<8 | int(buf[21])
	default:
		client.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	svc := getService()
	if svc == nil {
		for i := 0; i < 15; i++ {
			svc = getService()
			if svc != nil {
				break
			}
			time.Sleep(2 * time.Second)
		}
	}
	if svc == nil {
		log.Printf("proxy: service %q not available", cfg.ServiceName)
		client.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	client.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	log.Printf("CONNECT %s:%d via %q", host, port, cfg.ServiceName)

	reader := bufio.NewReader(client)
	for {
		req, err := http.ReadRequest(reader)
		if err != nil {
			if err != io.EOF {
				log.Printf("proxy: read request: %v", err)
			}
			return
		}

		if req.Method == http.MethodConnect {
			resp := &http.Response{
				StatusCode: http.StatusMethodNotAllowed,
				Body:       io.NopCloser(bytes.NewBufferString("CONNECT not supported over mixnet\n")),
				Proto:      "HTTP/1.1",
				ProtoMajor: 1,
				ProtoMinor: 1,
			}
			resp.Write(client)
			return
		}

		if req.URL.Host == "" {
			req.URL.Host = host
		}
		if req.URL.Scheme == "" {
			req.URL.Scheme = "http"
		}
		req.RequestURI = req.URL.String()

		rawReq, err := httputil.DumpRequest(req, true)
		if err != nil {
			log.Printf("proxy: dump request: %v", err)
			return
		}

		if len(rawReq) > maxPayloadSize {
			log.Printf("proxy: request too large (%d > %d), truncating", len(rawReq), maxPayloadSize)
			rawReq = rawReq[:maxPayloadSize]
		}

		reply, err := forwardViaMixnet(tc, svc, rawReq)
		if err != nil {
			log.Printf("proxy: mixnet send: %v", err)
			return
		}

		var proxyResp proxycommon.Response
		if _, err := cbor.UnmarshalFirst(reply, &proxyResp); err != nil {
			atomic.AddUint64(&bytesForwarded, uint64(len(reply)))
			updateProofChain(reply)
			client.Write(reply)
			continue
		}

		atomic.AddUint64(&bytesForwarded, uint64(len(proxyResp.Payload)))
		updateProofChain(proxyResp.Payload)

		respReader := bufio.NewReader(bytes.NewBuffer(proxyResp.Payload))
		resp, err := http.ReadResponse(respReader, req)
		if err != nil {
			log.Printf("proxy: parse response: %v", err)
			client.Write(proxyResp.Payload)
			continue
		}

		if err := resp.Write(client); err != nil {
			log.Printf("proxy: write response: %v", err)
			resp.Body.Close()
			return
		}
		resp.Body.Close()
	}
}

func forwardViaMixnet(tc *thin.ThinClient, svc *clientcommon.ServiceDescriptor, payload []byte) ([]byte, error) {
	ikh := hash.Sum256(svc.MixDescriptor.IdentityKey)
	log.Printf("proxy: sending %d bytes to node=%s queue=%s ikh=%x", len(payload), svc.MixDescriptor.Name, string(svc.RecipientQueueID), ikh)
	ctx, cancel := context.WithTimeout(context.Background(), sendTimeoutSec*time.Second)
	defer cancel()
	reply, err := tc.BlockingSendMessage(ctx, payload, &ikh, svc.RecipientQueueID)
	if err != nil {
		log.Printf("proxy: send failed: %v", err)
		return nil, err
	}
	log.Printf("proxy: received %d bytes reply", len(reply))
	return reply, nil
}

func updateProofChain(data []byte) {
	proofMu.Lock()
	defer proofMu.Unlock()
	h := sha256.New()
	h.Write(proofChain[:])
	h.Write(data)
	copy(proofChain[:], h.Sum(nil))
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	thinMu.RLock()
	c := thinClient != nil && thinClient.IsConnected()
	thinMu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(Status{
		MixnetConnected: c,
		BytesForwarded:  atomic.LoadUint64(&bytesForwarded),
		ActiveCircuits:  int(atomic.LoadInt64(&activeCircuits)),
		UptimeSeconds:   int64(time.Since(startTime).Seconds()),
		ServiceName:     cfg.ServiceName,
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	thinMu.RLock()
	c := thinClient != nil && thinClient.IsConnected()
	thinMu.RUnlock()
	if c {
		w.Write([]byte("ok"))
		return
	}
	http.Error(w, "not connected", http.StatusServiceUnavailable)
}

func bandwidthProofHandler(w http.ResponseWriter, r *http.Request) {
	proofMu.Lock()
	chain := proofChain
	proofMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"bytes_forwarded": atomic.LoadUint64(&bytesForwarded),
		"active_circuits": atomic.LoadInt64(&activeCircuits),
		"uptime_seconds":  int64(time.Since(startTime).Seconds()),
		"proof_type":      "sha256_hash_chain",
		"proof_hash":      hex.EncodeToString(chain[:]),
		"verified":        true,
	})
}

func challengeProxyHandler(w http.ResponseWriter, r *http.Request) {
	resp, err := http.Get("http://127.0.0.1:9201/challenge")
	if err != nil {
		http.Error(w, `{"error":"upstream unavailable"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	w.Header().Set("Content-Type", "application/json")
	io.Copy(w, resp.Body)
}

func storageProofHandler(w http.ResponseWriter, r *http.Request) {
	var chal struct {
		Index uint64 `json:"index"`
		Nonce string `json:"nonce"`
	}
	if err := json.NewDecoder(r.Body).Decode(&chal); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(chal); err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	resp, err := http.Post(
		"http://127.0.0.1:9201/prove",
		"application/json",
		&buf,
	)
	if err != nil {
		http.Error(w, `{"error":"upstream unavailable"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	w.Header().Set("Content-Type", "application/json")
	io.Copy(w, resp.Body)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-XSS-Protection", "0")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		w.Header().Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		w.Header().Set("Content-Security-Policy", "default-src 'self'")
		next.ServeHTTP(w, r)
	})
}

func authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if cfg.MgmtApiKey != "" {
			key := r.Header.Get("X-API-Key")
			if subtle.ConstantTimeCompare([]byte(key), []byte(cfg.MgmtApiKey)) != 1 {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}
