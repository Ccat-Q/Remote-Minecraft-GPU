// remotegpu-vtest-receiver is a Linux-only diagnostic endpoint. It proves
// that RemoteGPU's ordered QUIC stream can carry unmodified vtest traffic to
// a normal virgl_test_server. It deliberately does not implement PRESENT:
// production presentation belongs to the iOS renderer adapter.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
	quic "github.com/quic-go/quic-go"
)

func main() {
	var connectAddr, unixSocket, token, serverName string
	var insecure bool
	flag.StringVar(&connectAddr, "connect", "127.0.0.1:4433", "RemoteGPU proxy QUIC address")
	flag.StringVar(&unixSocket, "socket", "/tmp/.virgl_test", "virgl_test_server Unix socket")
	flag.StringVar(&token, "pairing-token", "", "required proxy pairing token")
	flag.StringVar(&serverName, "server-name", "", "TLS server name")
	flag.BoolVar(&insecure, "insecure-skip-verify", false, "disable TLS verification (CI-only)")
	flag.Parse()
	if token == "" {
		fmt.Fprintln(os.Stderr, "remotegpu-vtest-receiver: -pairing-token is required")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, connectAddr, unixSocket, token, serverName, insecure); err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "remotegpu-vtest-receiver:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, connectAddr, unixSocket, token, serverName string, insecure bool) error {
	tlsConfig := &tls.Config{
		MinVersion:         tls.VersionTLS13,
		NextProtos:         []string{"remotegpu/1"},
		ServerName:         serverName,
		InsecureSkipVerify: insecure, // #nosec G402 -- explicit CI-only flag.
	}
	conn, err := quic.DialAddr(ctx, connectAddr, tlsConfig, nil)
	if err != nil {
		return err
	}
	defer conn.CloseWithError(0, "receiver stopped")
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return err
	}
	if err := protocol.Write(stream, protocol.Envelope{Type: protocol.TypeHello, Payload: []byte(token)}); err != nil {
		return err
	}
	unix, err := net.Dial("unix", unixSocket)
	if err != nil {
		return err
	}
	defer unix.Close()

	bridgeCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	errCh := make(chan error, 2)
	var writeMu sync.Mutex

	go func() {
		for {
			envelope, err := protocol.Read(stream)
			if err != nil {
				errCh <- err
				return
			}
			if envelope.Type == protocol.TypePresent {
				errCh <- errors.New("PRESENT reached Linux diagnostic receiver")
				return
			}
			if envelope.Type != protocol.TypeVTest {
				errCh <- fmt.Errorf("unexpected RemoteGPU envelope %d", envelope.Type)
				return
			}
			_, data, err := protocol.ParseVTestChunk(envelope.Payload)
			if err != nil {
				errCh <- err
				return
			}
			if err := writeAll(unix, data); err != nil {
				errCh <- err
				return
			}
		}
	}()

	go func() {
		buf := make([]byte, 32*1024)
		var sequence uint64
		for {
			n, err := unix.Read(buf)
			if n > 0 {
				sequence++
				writeMu.Lock()
				writeErr := protocol.Write(stream, protocol.VTestChunk(sequence, buf[:n]))
				writeMu.Unlock()
				if writeErr != nil {
					errCh <- writeErr
					return
				}
			}
			if err != nil {
				errCh <- err
				return
			}
		}
	}()

	select {
	case <-bridgeCtx.Done():
		return bridgeCtx.Err()
	case err := <-errCh:
		if errors.Is(err, io.EOF) && ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}
