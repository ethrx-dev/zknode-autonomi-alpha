package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/katzenpost/katzenpost/client"
	"github.com/katzenpost/katzenpost/client/config"
	"github.com/katzenpost/katzenpost/core/epochtime"
)

func main() {
	if len(os.Args) < 3 || os.Args[1] != "-c" {
		log.Fatalf("usage: zkclientd -c <config.toml>")
	}
	cfgFile := os.Args[2]

	// Shift the genesis epoch forward by one period (20 minutes)
	// This fixes the 1-epoch skew between the hardcoded genesis
	// (2017-06-01) and the actual PKI document availability.
	// Without this, WaitForCurrentDocument() calculates the current
	// epoch as 1 ahead of any available PKI document.
	epochtime.Epoch = epochtime.Epoch.Add(-20 * time.Minute)

	clientCfg, err := config.LoadFile(cfgFile)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	d, err := client.NewDaemon(clientCfg)
	if err != nil {
		log.Fatalf("daemon: %v", err)
	}

	if err := d.Start(); err != nil {
		log.Fatalf("start: %v", err)
	}

	// Wait for PKI document with timeout
	log.Printf("zkclientd: waiting for PKI document...")
	for i := 0; i < 120; i++ {
		_, doc := d.CurrentDocument()
		if doc != nil {
			log.Printf("zkclientd: connected, epoch=%d id=%s", doc.Epoch, doc.GenesisEpoch)
			break
		}
		time.Sleep(1 * time.Second)
	}

	// Wait for shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	log.Printf("zkclientd: shutting down")
	d.Shutdown()
}

func init() {
	log.SetFlags(log.Lmicroseconds | log.Lshortfile)
}
