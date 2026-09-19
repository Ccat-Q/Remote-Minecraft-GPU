package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/proxy"
)

func main() {
	var unixSock, presentSock, listen, cert, key, token string
	flag.StringVar(&unixSock, "unix", "/tmp/.virgl_test", "vtest Unix socket to create")
	flag.StringVar(&presentSock, "present-socket", "/tmp/remotegpu-present.sock", "Mesa PRESENT Unix datagram socket")
	flag.StringVar(&listen, "listen", ":4433", "QUIC UDP listener")
	flag.StringVar(&cert, "cert", "", "TLS certificate PEM")
	flag.StringVar(&key, "key", "", "TLS private key PEM")
	flag.StringVar(&token, "pairing-token", "", "required iOS pairing token")
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
	log.Fatal((proxy.Bridge{Config: proxy.Config{UnixSocket: unixSock, PresentSocket: presentSock, ListenAddr: listen, PairingToken: token, TLSConfig: tlsConfig}}).Serve(ctx))
}
