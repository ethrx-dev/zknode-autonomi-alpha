// SPDX-FileCopyrightText: © 2023 David Stainton
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"bufio"
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/katzenpost/hpqc/hash"
	"github.com/katzenpost/hpqc/rand"

	"github.com/katzenpost/katzenpost/client2"
	"github.com/katzenpost/katzenpost/client2/config"
	thinclt "github.com/ZeroKnowledgeNetwork/opt/apps/walletshield/thin"
	sConstants "github.com/katzenpost/katzenpost/core/sphinx/constants"
)

var (
	timeout          = 20 // (default) context timeout
	ProxyHTTPService = "proxy"

	// Note: UserForwardPayloadLength should match the same value passed to genconfig.
	UserForwardPayloadLength = 3000
)

func sendRequest(thin *thinclt.ThinClient, httpRequestBytes []byte) ([]byte, error) {
	// Validate payload size
	if len(httpRequestBytes) > UserForwardPayloadLength {
		return nil, fmt.Errorf("payload size %d exceeds maximum %d bytes", len(httpRequestBytes), UserForwardPayloadLength)
	}

	surbID := &[sConstants.SURBIDLength]byte{}
	_, err := rand.Reader.Read(surbID[:])
	if err != nil {
		panic(err)
	}

	// Debug: show PKI doc epoch
	doc := thin.PKIDocument()
	if doc == nil {
		return nil, fmt.Errorf("PKI document is not available")
	}
	fmt.Printf("PKI doc epoch=%d, num service nodes=%d\n", doc.Epoch, len(doc.ServiceNodes))

	target, err := thin.GetService(ProxyHTTPService)
	if err != nil {
		return nil, fmt.Errorf("GetService(%s) failed: %w", ProxyHTTPService, err)
	}
	nodeIdBytes := hash.Sum256(target.MixDescriptor.IdentityKey)
	fmt.Printf("GetService(%s) ok: endpoint=%s, node=%x\n", ProxyHTTPService, target.RecipientQueueID, nodeIdBytes[:8])
	nodeId := hash.Sum256(target.MixDescriptor.IdentityKey)

	timeoutCtx, cancel := context.WithTimeout(context.TODO(), time.Duration(timeout)*time.Second)
	defer cancel()
	return thin.BlockingSendMessage(timeoutCtx, httpRequestBytes, &nodeId, target.RecipientQueueID)
}

type Server struct {
	log        *log.Logger
	daemon     *client2.Daemon
	thin       *thinclt.ThinClient
	configPath string
	logLevel   string
	mu         sync.Mutex
}

func (s *Server) reconnect() *thinclt.ThinClient {
	s.mu.Lock()
	defer s.mu.Unlock()

	logging := &config.Logging{
		Disable: false,
		Level:   s.logLevel,
	}
	cfgThin, err := thinclt.LoadFile(s.configPath)
	if err != nil {
		s.log.Errorf("Failed to load config for reconnect: %s", err)
		return s.thin
	}

	client := thinclt.NewThinClient(cfgThin, logging)
	err = client.Dial()
	if err != nil {
		s.log.Errorf("Failed to reconnect: %s", err)
		return s.thin
	}
	s.thin.Close()
	s.thin = client
	s.log.Info("Reconnected to client daemon")
	return client
}

func (s *Server) getThin() *thinclt.ThinClient {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.thin
}

func main() {
	var logLevel string
	var listenAddr string
	var listenAddrClient string
	var configPath string
	var delayStart int
	var testProbe bool
	var testProbeCount int
	var testProbeResponseDelay int
	var testProbeSendDelay int
	var thinClientOnly bool

	flag.StringVar(&configPath, "config", "", "file path of the client configuration TOML file")
	flag.IntVar(&delayStart, "delay_start", 0, "max random seconds to delay start")
	flag.StringVar(&logLevel, "log_level", "DEBUG", "logging level could be set to: DEBUG, INFO, WARNING, ERROR, CRITICAL")
	flag.StringVar(&listenAddr, "listen", "", "local socket to listen HTTP on")
	flag.StringVar(&listenAddrClient, "listen_client", "", "local network address for the client daemon")
	flag.BoolVar(&testProbe, "probe", false, "send test probes instead of handling requests")
	flag.IntVar(&testProbeCount, "probe_count", 1, "number of test probes to send")
	flag.IntVar(&testProbeResponseDelay, "probe_response_delay", 0, "test probe response deplay")
	flag.IntVar(&testProbeSendDelay, "probe_send_delay", 10, "test probe delay between probes")
	flag.IntVar(&timeout, "timeout", timeout, "seconds to wait for a request")
	flag.BoolVar(&thinClientOnly, "thin", false, "use thin client mode (connect to existing daemon)")
	flag.Parse()

	if listenAddr == "" && !testProbe {
		panic("listen flag must be set")
	}
	if configPath == "" {
		panic("config flag must be set")
	}

	// logging
	level, err := log.ParseLevel(logLevel)
	if err != nil {
		panic(err)
	}
	mylog := log.NewWithOptions(os.Stdout, log.Options{
		Prefix: "walletshield:",
		Level:  level,
	})

	if delayStart > 0 {
		d := rand.NewMath().Intn(delayStart)
		mylog.Infof("Delaying start for %d seconds...", d)
		time.Sleep(time.Duration(d) * time.Second)
	}

	// start client2 daemon
	var d *client2.Daemon
	var cfgThin *thinclt.Config
	if !thinClientOnly {
		cfg, err := config.LoadFile(configPath)
		if err != nil {
			panic(err)
		}

		if listenAddrClient != "" {
			cfg.ListenAddress = listenAddrClient
		}

		d, err := client2.NewDaemon(cfg)
		if err != nil {
			panic(err)
		}
		err = d.Start()
		if err != nil {
			panic(err)
		}

		cfgThin = thinclt.FromConfig(cfg)

		fmt.Println("Sleeping for 3 seconds to let the client daemon startup...")
		time.Sleep(time.Second * 3) // XXX ugly hack but works: FIXME
	} else {
		cfgThin, err = thinclt.LoadFile(configPath)

		if listenAddrClient != "" {
			cfgThin.Address = listenAddrClient
		}
		if err != nil {
			panic(fmt.Errorf("failed to open thin client config: %s", err))
		}
	}

	logging := &config.Logging{
		Disable: false,
		Level:   level.String(),
	}

	thin := thinclt.NewThinClient(cfgThin, logging)
	err = thin.Dial()
	if err != nil {
		panic(err)
	}

	// http server
	server := &Server{
		log:        mylog,
		thin:       thin,
		daemon:     d,
		configPath: configPath,
		logLevel:   level.String(),
	}

	// Start event monitoring goroutine for auto-reconnect
	go func() {
		eventSink := thin.EventSink()
		defer thin.StopEventSink(eventSink)
		everConnected := false
		for event := range eventSink {
			switch v := event.(type) {
			case *thinclt.ConnectionStatusEvent:
				if v.IsConnected {
					everConnected = true
				} else if everConnected {
					mylog.Warn("Connection lost, attempting reconnect...")
					server.reconnect()
					everConnected = false
				}
			}
		}
		mylog.Warn("Event sink closed, connection to daemon may be lost")
	}()

	if testProbe {
		server.SendTestProbes(testProbeSendDelay, testProbeCount, testProbeResponseDelay)
		d.Shutdown()
	} else {
		http.HandleFunc("/", server.Handler)
		err := http.ListenAndServe(listenAddr, nil)
		if err != nil {
			// Check if the error is related to the port being in use
			if strings.Contains(err.Error(), "bind: address already in use") {
				mylog.Errorf("Cannot start server: Listen port %s is already in use. Please check if another instance of walletshield is running or use another port.", listenAddr)
			} else {
				mylog.Errorf("Failed to start HTTP server: %s", err)
			}
		}
	}
}

func (s *Server) Handler(w http.ResponseWriter, req *http.Request) {
	s.log.Infof("Received HTTP request for %s", req.URL)

	myurl, err := url.Parse(req.RequestURI)
	if err != nil {
		s.log.Errorf("url.Parse(req.RequestURI) failed: %s", err)
		return
	}
	req.URL = myurl
	req.RequestURI = ""

	buf := new(bytes.Buffer)
	req.Write(buf)

	s.log.Debugf("RAW HTTP REQUEST:\n%s", string(buf.Bytes()))

	thin := s.getThin()
	rawReply, err := sendRequest(thin, buf.Bytes())
	if err != nil {
		if strings.Contains(err.Error(), "errHalting") || strings.Contains(err.Error(), "errNotConnected") || strings.Contains(err.Error(), "i/o timeout") || strings.Contains(err.Error(), "context deadline exceeded") {
			s.log.Warnf("Thin client error, reconnecting: %s", err)
			thin = s.reconnect()
			rawReply, err = sendRequest(thin, buf.Bytes())
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

	// Parse the raw HTTP response
	resp, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(rawReply)), nil)
	if err != nil {
		s.log.Errorf("Failed to parse response: %s", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	responsePayload, err := io.ReadAll(resp.Body)
	if err != nil {
		s.log.Errorf("Failed to read response body: %s", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	responsePayload = bytes.TrimRight(responsePayload, "\x00")

	s.log.Infof("Response: %s", responsePayload)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(responsePayload)))
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
	fmt.Fprintf(w, string(responsePayload))
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

		// probe indefinitely if testProbeCount is 0
		if testProbeCount != 0 && packetsTransmitted >= testProbeCount {
			os.Exit(0)
		}

		time.Sleep(time.Duration(testProbeSendDelay) * time.Second)
	}
}
