package main

import (
	"bufio"
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	cbor "github.com/fxamacker/cbor/v2"
	"github.com/charmbracelet/log"
	"github.com/katzenpost/hpqc/hash"

	"github.com/katzenpost/katzenpost/client/config"
	"github.com/katzenpost/katzenpost/client/thin"
	"github.com/katzenpost/katzenpost/client/thin/transport"
)

var (
	timeout          = 300 // (default) context timeout
	ProxyHTTPService = "proxy"

	// Note: UserForwardPayloadLength should match the same value passed to genconfig.
	UserForwardPayloadLength = 2000
	thinClientOnly           = true // thin client mode (connects to existing daemon)
)

type Server struct {
	log        *log.Logger
	thin       *thin.ThinClient
	configPath string
	logLevel   string
	upstream   string
	mu         sync.Mutex
}

func (s *Server) reconnect() *thin.ThinClient {
	s.mu.Lock()
	defer s.mu.Unlock()

	cfgThin, err := thin.LoadFile(s.configPath)
	if err != nil {
		s.log.Errorf("Failed to load config for reconnect: %s", err)
		return s.thin
	}

	logging := &config.Logging{
		Disable: false,
		Level:   s.logLevel,
	}
	client := thin.NewThinClient(cfgThin, logging)
	err = client.Dial()
	if err != nil {
		s.log.Errorf("Failed to reconnect: %s", err)
		return s.thin
	}
	s.thin.Close()
	s.thin = client
	s.log.Info("Reconnected to client daemon")
	s.startEventHandler(client)
	return client
}

func (s *Server) startEventHandler(thinClient *thin.ThinClient) {
	go func() {
		eventSink := thinClient.EventSink()
		defer thinClient.StopEventSink(eventSink)
		everConnected := false
		for event := range eventSink {
			switch v := event.(type) {
			case *thin.ConnectionStatusEvent:
				if v.IsConnected {
					everConnected = true
				} else if everConnected {
					s.log.Warn("Connection lost, attempting reconnect...")
					s.reconnect()
					everConnected = false
				}
			}
		}
		s.log.Warn("Event sink closed, connection to daemon may be lost")
	}()
}

func (s *Server) getThin() *thin.ThinClient {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.thin
}

func main() {
	var logLevel string
	var listenAddr string
	var listenAddrClient string
	var upstream string
	var configPath string
	var delayStart int
	var testProbe bool
	var testProbeCount int
	var testProbeResponseDelay int
	var testProbeSendDelay int

	flag.StringVar(&configPath, "config", "", "file path of the thin client configuration TOML file")
	flag.IntVar(&delayStart, "delay_start", 0, "max random seconds to delay start")
	flag.StringVar(&logLevel, "log_level", "DEBUG", "logging level could be set to: DEBUG, INFO, WARNING, ERROR, CRITICAL")
	flag.StringVar(&listenAddr, "listen", "", "local socket to listen HTTP on")
	flag.StringVar(&listenAddrClient, "listen_client", "", "local network address for the client daemon")
	flag.StringVar(&upstream, "upstream", "", "upstream base URL to rewrite requests to")
	flag.BoolVar(&thinClientOnly, "thin", true, "use thin client mode (connect to existing daemon)")
	flag.BoolVar(&testProbe, "probe", false, "send test probes instead of handling requests")
	flag.IntVar(&testProbeCount, "probe_count", 1, "number of test probes to send")
	flag.IntVar(&testProbeResponseDelay, "probe_response_delay", 0, "test probe response deplay")
	flag.IntVar(&testProbeSendDelay, "probe_send_delay", 10, "test probe delay between probes")
	flag.IntVar(&timeout, "timeout", timeout, "seconds to wait for a request")
	flag.Parse()

	if listenAddr == "" && !testProbe {
		panic("listen flag must be set")
	}
	if configPath == "" {
		panic("config flag must be set")
	}

	level, err := log.ParseLevel(logLevel)
	if err != nil {
		panic(err)
	}
	mylog := log.NewWithOptions(os.Stdout, log.Options{
		Prefix: "walletshield:",
		Level:  level,
	})

	if delayStart > 0 {
		d := rand.Intn(delayStart)
		mylog.Infof("Delaying start for %d seconds...", d)
		time.Sleep(time.Duration(d) * time.Second)
	}

	cfgThin, err := thin.LoadFile(configPath)
	if err != nil {
		panic(fmt.Errorf("failed to load thin client config: %s", err))
	}

	if listenAddrClient != "" {
		if cfgThin.Dial == nil {
			cfgThin.Dial = &transport.DialConfig{}
		}
		if cfgThin.Dial.Tcp == nil {
			cfgThin.Dial.Tcp = &transport.TcpDialConfig{}
		}
		cfgThin.Dial.Tcp.Address = listenAddrClient
	}

	logging := &config.Logging{
		Disable: false,
		Level:   level.String(),
	}

	thinClient := thin.NewThinClient(cfgThin, logging)
	err = thinClient.Dial()
	if err != nil {
		panic(err)
	}

	server := &Server{
		log:        mylog,
		thin:       thinClient,
		configPath: configPath,
		logLevel:   level.String(),
		upstream:   upstream,
	}

	server.startEventHandler(thinClient)

	if testProbe {
		server.SendTestProbes(testProbeSendDelay, testProbeCount, testProbeResponseDelay)
	} else {
		http.HandleFunc("/", server.Handler)
		http.ListenAndServe(listenAddr, nil)
	}
}

func (s *Server) Handler(w http.ResponseWriter, req *http.Request) {
	s.log.Infof("Received HTTP request for %s", req.URL)

	// Build the raw request payload sent through the mixnet.
	// When an upstream is configured, use an absolute-form request line so the
	// mixnet http-proxy can forward to the correct scheme://host.
	var buf bytes.Buffer
	if s.upstream != "" {
		body, rerr := io.ReadAll(req.Body)
		if rerr != nil {
			s.log.Errorf("io.ReadAll failed: %s", rerr)
			return
		}
		u, uerr := url.Parse(s.upstream)
		if uerr != nil {
			s.log.Errorf("url.Parse(upstream) failed: %s", uerr)
			return
		}
		fmt.Fprintf(&buf, "POST %s HTTP/1.1\r\n", s.upstream)
		fmt.Fprintf(&buf, "Host: %s\r\n", u.Host)
		fmt.Fprintf(&buf, "Content-Type: application/json\r\n")
		fmt.Fprintf(&buf, "Content-Length: %d\r\n", len(body))
		fmt.Fprintf(&buf, "\r\n")
		buf.Write(body)
	} else {
		myurl, err := url.Parse(req.RequestURI)
		if err != nil {
			s.log.Errorf("url.Parse(req.RequestURI) failed: %s", err)
			return
		}
		req.URL = myurl
		req.RequestURI = ""
		req.Write(&buf)
	}

	s.log.Debugf("RAW HTTP REQUEST:\n%s", string(buf.Bytes()))

	thin := s.getThin()
	rawReply, err := sendRequest(thin, buf.Bytes())
	if err != nil {
		s.log.Warnf("Thin client error, reconnecting: %s", err)
		// Retry the reconnect up to 3 times with backoff: a single
		// reconnect may fail while the daemon is still re-establishing
		// its gateway link (offline mode), and reusing the stale client
		// guarantees a second failure. Each attempt gets a fresh Dial.
		for attempt := 1; attempt <= 3; attempt++ {
			thin = s.reconnect()
			rawReply, err = sendRequest(thin, buf.Bytes())
			if err == nil {
				break
			}
			s.log.Warnf("Retry %d/3 after reconnect failed: %s", attempt, err)
			time.Sleep(time.Duration(attempt) * 2 * time.Second)
		}
	}
	if err != nil {
		s.log.Errorf("Failed to send message: %s", err)
		if strings.Contains(err.Error(), "exceeds maximum") {
			http.Error(w, "custom 500", http.StatusInternalServerError)
		} else {
			http.Error(w, "custom 404", http.StatusNotFound)
		}
		return
	}

	// The http_proxy Kaetzchen service wraps its reply in a CBOR-encoded
	// common.Response{Payload: rawHTTP}. Decode it first; fall back to
	// treating the reply as a raw HTTP response for compatibility with
	// services that do not wrap.
	responsePayload := rawReply
	var proxyResp proxyCommonResponse
	if _, err := cbor.UnmarshalFirst(rawReply, &proxyResp); err == nil && len(proxyResp.Payload) > 0 {
		responsePayload = proxyResp.Payload
	}

	resp, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(responsePayload)), nil)
	if err != nil {
		s.log.Errorf("Failed to parse response: %s", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	bodyPayload, err := io.ReadAll(resp.Body)
	if err != nil {
		s.log.Errorf("Failed to read response body: %s", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	bodyPayload = bytes.TrimRight(bodyPayload, "\x00")

	s.log.Infof("Response: %s", bodyPayload)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(bodyPayload)))
	for k, v := range resp.Header {
		kLower := strings.ToLower(k)
		if kLower == "content-type" || kLower == "content-length" || kLower == "date" || kLower == "host" || kLower == "transfer-encoding" || kLower == "connection" {
			continue
		}
		for _, hv := range v {
			w.Header().Add(k, hv)
		}
	}
	w.WriteHeader(resp.StatusCode)
	fmt.Fprintf(w, string(bodyPayload))
}

// proxyCommonResponse mirrors quic/proxy/common.Response — the CBOR
// envelope the http_proxy Kaetzchen service wraps its raw HTTP reply in.
type proxyCommonResponse struct {
	Payload []byte
}

func sendRequest(thin *thin.ThinClient, httpRequestBytes []byte) ([]byte, error) {
	if len(httpRequestBytes) > UserForwardPayloadLength {
		return nil, fmt.Errorf("payload size %d exceeds maximum %d bytes", len(httpRequestBytes), UserForwardPayloadLength)
	}

	doc := thin.PKIDocument()
	if doc == nil {
		return nil, fmt.Errorf("PKI document is not available")
	}
	fmt.Printf("PKI doc epoch=%d, num service nodes=%d\n", doc.Epoch, len(doc.ServiceNodes))

	target, err := thin.GetService(ProxyHTTPService)
	if err != nil {
		return nil, fmt.Errorf("GetService(%s) failed: %w", ProxyHTTPService, err)
	}
	nodeId := hash.Sum256(target.MixDescriptor.IdentityKey)
	fmt.Printf("GetService(%s) ok: endpoint=%s, node=%x identityKeyLen=%d identityKeyBytes=%x\n", ProxyHTTPService, target.RecipientQueueID, nodeId[:8], len(target.MixDescriptor.IdentityKey), target.MixDescriptor.IdentityKey)

	timeoutCtx, cancel := context.WithTimeout(context.TODO(), time.Duration(timeout)*time.Second)
	defer cancel()
	return thin.BlockingSendMessage(timeoutCtx, httpRequestBytes, &nodeId, target.RecipientQueueID)
}

func (s *Server) SendTestProbes(testProbeSendDelay int, testProbeCount int, testProbeResponseDelay int) {
	url := fmt.Sprintf("http://nowhere/_/probe/%d", testProbeResponseDelay)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		s.log.Errorf("http.NewRequest failed: %s", err)
		return
	}
	buf := new(bytes.Buffer)
	req.Write(buf)
	httpRequestBytes := buf.Bytes()

	var packetsTransmitted, packetsReceived int
	var rttMin, rttMax, rttTotal float64
	rttMin = math.MaxFloat64

	for {
		packetsTransmitted++
		t := time.Now()

		_, err = sendRequest(s.getThin(), httpRequestBytes)
		elapsed := time.Since(t).Seconds()
		if err != nil {
			s.log.Errorf("Probe failed after %.2fs: %s", elapsed, err)
		} else {
			packetsReceived++
			rttTotal += elapsed
			if elapsed < rttMin {
				rttMin = elapsed
			}
			if elapsed > rttMax {
				rttMax = elapsed
			}
		}

		packetLoss := float64(packetsTransmitted-packetsReceived) / float64(packetsTransmitted) * 100
		rttAvg := rttTotal / float64(packetsReceived)
		if packetsReceived == 0 {
			rttMin = math.NaN()
		}
		s.log.Infof("Probe packet transmitted/received/loss = %d/%d/%.1f%% | rtt min/avg/max = %.2f/%.2f/%.2f s",
			packetsTransmitted, packetsReceived, packetLoss, rttMin, rttAvg, rttMax)

		if testProbeCount != 0 && packetsTransmitted >= testProbeCount {
			os.Exit(0)
		}

		time.Sleep(time.Duration(testProbeSendDelay) * time.Second)
	}
}
