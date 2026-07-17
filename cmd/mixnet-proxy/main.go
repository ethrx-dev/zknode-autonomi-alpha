package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

type Config struct {
	ListenAddr     string `json:"listen_addr"`
	SocksAddr      string `json:"socks_addr"`
	MgmtAddr       string `json:"mgmt_addr"`
	MixnetGateway  string `json:"mixnet_gateway"`
	WireGuardIface string `json:"wireguard_iface"`
	AntNodeAddr    string `json:"ant_node_addr"`
}

type Status struct {
	MixnetConnected  bool   `json:"mixnet_connected"`
	WireGuardIface   string `json:"wireguard_interface"`
	AntNodeAddr      string `json:"ant_node_addr"`
	BytesForwarded   uint64 `json:"bytes_forwarded"`
	ActiveCircuits   int    `json:"active_circuits"`
	UptimeSeconds    int64  `json:"uptime_seconds"`
}

var (
	bytesForwarded uint64
	activeCircuits int64
	startTime      = time.Now()
	cfg            Config
)

func defaultConfig() Config {
	return Config{
		ListenAddr:     "0.0.0.0:1080",
		SocksAddr:      "0.0.0.0:1080",
		MgmtAddr:       "0.0.0.0:9090",
		MixnetGateway:  "mix-gateway:12348",
		WireGuardIface: "wg0",
		AntNodeAddr:    "10.0.0.2",
	}
}

func main() {
	configPath := flag.String("config", "", "path to config file (JSON)")
	flag.Parse()

	cfg = defaultConfig()

	if *configPath != "" {
		f, err := os.Open(*configPath)
		if err != nil {
			log.Fatalf("failed to open config: %v", err)
		}
		defer f.Close()
		if err := json.NewDecoder(f).Decode(&cfg); err != nil {
			log.Fatalf("failed to parse config: %v", err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	ln, err := net.Listen("tcp", cfg.SocksAddr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", cfg.SocksAddr, err)
	}
	log.Printf("mixnet-proxy: SOCKS5 listening on %s", cfg.SocksAddr)

	go acceptLoop(ctx, ln)

	mux := http.NewServeMux()
	mux.HandleFunc("/status", statusHandler)
	mux.HandleFunc("/health", healthHandler)

	mgmtLn, err := net.Listen("tcp", cfg.MgmtAddr)
	if err != nil {
		log.Fatalf("failed to listen on management port %s: %v", cfg.MgmtAddr, err)
	}
	go func() {
		log.Printf("mixnet-proxy: management API on %s", cfg.MgmtAddr)
		http.Serve(mgmtLn, mux)
	}()

	log.Printf("mixnet-proxy: started, gateway=%s wg=%s ant=%s",
		cfg.MixnetGateway, cfg.WireGuardIface, cfg.AntNodeAddr)

	<-sigCh
	log.Printf("mixnet-proxy: shutting down")
	cancel()
	ln.Close()
	mgmtLn.Close()
}

func acceptLoop(ctx context.Context, ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return
			default:
				log.Printf("accept error: %v", err)
				continue
			}
		}
		go handleConnection(ctx, conn)
	}
}

func handleConnection(ctx context.Context, client net.Conn) {
	defer client.Close()

	atomic.AddInt64(&activeCircuits, 1)
	defer atomic.AddInt64(&activeCircuits, -1)

	buf := make([]byte, 512)
	n, err := client.Read(buf)
	if err != nil {
		log.Printf("socks read error: %v", err)
		return
	}

	if buf[0] != 0x05 {
		return
	}

	client.Write([]byte{0x05, 0x00})

	n, err = client.Read(buf)
	if err != nil || n < 7 {
		return
	}

	var targetHost string
	var targetPort int

	switch buf[3] {
	case 0x01:
		targetHost = net.IP(buf[4:8]).String()
		targetPort = int(buf[8])<<8 | int(buf[9])
	case 0x03:
		hostLen := int(buf[4])
		if n < 5+hostLen+2 {
			return
		}
		targetHost = string(buf[5 : 5+hostLen])
		targetPort = int(buf[5+hostLen])<<8 | int(buf[6+hostLen])
	case 0x04:
		targetHost = net.IP(buf[4:20]).String()
		targetPort = int(buf[20])<<8 | int(buf[21])
	default:
		return
	}

	target := fmt.Sprintf("%s:%d", targetHost, targetPort)

	remote, err := dialThroughMixnet(ctx, target)
	if err != nil {
		log.Printf("mixnet dial %s: %v", target, err)
		client.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer remote.Close()

	client.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})

	pipe(client, remote)
}

func dialThroughMixnet(ctx context.Context, target string) (net.Conn, error) {
	dialer := net.Dialer{Timeout: 30 * time.Second}

	conn, err := dialer.DialContext(ctx, "tcp", cfg.MixnetGateway)
	if err != nil {
		return nil, fmt.Errorf("gateway dial: %w", err)
	}

	header := buildMixnetHeader(target)
	if _, err := conn.Write(header); err != nil {
		conn.Close()
		return nil, fmt.Errorf("header write: %w", err)
	}

	return conn, nil
}

func buildMixnetHeader(target string) []byte {
	host, port := splitHostPort(target)
	header := []byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}
	header = append(header, []byte(host)...)
	header = append(header, byte(port>>8), byte(port&0xff))
	return header
}

func splitHostPort(target string) (string, int) {
	host, port, err := net.SplitHostPort(target)
	if err != nil {
		return target, 443
	}
	p := 0
	for _, b := range []byte(port) {
		p = p*10 + int(b-'0')
	}
	return host, p
}

func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst io.Writer, src io.Reader) {
		buf := make([]byte, 32*1024)
		for {
			n, err := src.Read(buf)
			if n > 0 {
				atomic.AddUint64(&bytesForwarded, uint64(n))
				if _, werr := dst.Write(buf[:n]); werr != nil {
					done <- struct{}{}
					return
				}
			}
			if err != nil {
				done <- struct{}{}
				return
			}
		}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(Status{
		MixnetConnected: true,
		WireGuardIface:  cfg.WireGuardIface,
		AntNodeAddr:     cfg.AntNodeAddr,
		BytesForwarded:  atomic.LoadUint64(&bytesForwarded),
		ActiveCircuits:  int(atomic.LoadInt64(&activeCircuits)),
		UptimeSeconds:   int64(time.Since(startTime).Seconds()),
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
