package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sort"
	"syscall"
	"time"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/diagnostics"
	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/proxy"
)

func main() {
	var unixSock, presentSock, listen, cert, key, token string
	var statsInterval time.Duration
	flag.StringVar(&unixSock, "unix", "/tmp/.virgl_test", "vtest Unix socket to create")
	flag.StringVar(&presentSock, "present-socket", "/tmp/remotegpu-present.sock", "Mesa PRESENT Unix datagram socket")
	flag.StringVar(&listen, "listen", ":4433", "QUIC UDP listener")
	flag.StringVar(&cert, "cert", "", "TLS certificate PEM")
	flag.StringVar(&key, "key", "", "TLS private key PEM")
	flag.StringVar(&token, "pairing-token", "", "required iOS pairing token")
	flag.DurationVar(&statsInterval, "stats-interval", time.Second, "protocol metrics interval; 0 disables")
	flag.Parse()
	if cert == "" || key == "" || token == "" {
		fmt.Fprintln(os.Stderr, "-cert, -key and -pairing-token are required")
		os.Exit(2)
	}
	tlsConfig, err := proxy.LoadTLS(cert, key)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	stats := diagnostics.NewCollector()
	if statsInterval > 0 {
		go reportStats(ctx, stats, statsInterval)
	}
	log.Fatal((proxy.Bridge{Config: proxy.Config{UnixSocket: unixSock, PresentSocket: presentSock, ListenAddr: listen, PairingToken: token, TLSConfig: tlsConfig, Diagnostics: stats}}).Serve(ctx))
}

func reportStats(ctx context.Context, stats *diagnostics.Collector, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s := stats.Take()
			if s.UploadBytes == 0 && s.DownloadBytes == 0 && s.PresentEvents == 0 {
				continue
			}
			ids := make([]int, 0, len(s.VTestCommands))
			for id := range s.VTestCommands {
				ids = append(ids, int(id))
			}
			sort.Ints(ids)
			log.Printf("vtest interval=%s upload=%dB download=%dB presents=%d commands=%v", interval, s.UploadBytes, s.DownloadBytes, s.PresentEvents, orderedCounts(ids, s.VTestCommands))
		}
	}
}

func orderedCounts(ids []int, counts map[uint32]uint64) []string {
	result := make([]string, 0, len(ids))
	for _, id := range ids {
		result = append(result, fmt.Sprintf("%d:%d", id, counts[uint32(id)]))
	}
	return result
}
