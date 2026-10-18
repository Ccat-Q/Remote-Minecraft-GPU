package proxy

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"math/big"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
	quic "github.com/quic-go/quic-go"
)

func sessionPair(t *testing.T, config *quic.Config) (quic.Connection, quic.Connection) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := quic.ListenAddr("127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, NextProtos: []string{"session-test"}}, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := quic.DialAddr(ctx, listener.Addr().String(), &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"session-test"}}, nil) // CI self-signed fixture only.
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.CloseWithError(0, "test done") })
	server, err := listener.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.CloseWithError(0, "test done") })
	return client, server
}

func mesaListener(t *testing.T) *net.UnixListener {
	t.Helper()
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(t.TempDir(), "vtest.sock"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	return listener
}

func TestHelloWaitIsBounded(t *testing.T) {
	for _, partial := range []bool{false, true} {
		t.Run(map[bool]string{false: "no stream", true: "partial HELLO"}[partial], func(t *testing.T) {
			client, server := sessionPair(t, renderQUICConfig())
			if partial {
				stream, err := client.OpenStreamSync(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				if _, err = stream.Write([]byte("RGP")); err != nil {
					t.Fatal(err)
				}
			}
			started := time.Now()
			err := (Bridge{Config: Config{PairingToken: "test", HelloTimeout: 100 * time.Millisecond}}).serveSession(context.Background(), mesaListener(t), nil, server)
			if err == nil || time.Since(started) > 2*time.Second {
				t.Fatalf("HELLO did not time out: %v", err)
			}
		})
	}
}

func TestMesaWaitCancellationTimeoutAndListenerReuse(t *testing.T) {
	listener := mesaListener(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := acceptMesa(ctx, listener, time.Second); done <- err }()
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled Mesa wait: %v", err)
	}
	if _, err := acceptMesa(context.Background(), listener, 20*time.Millisecond); err == nil {
		t.Fatal("missing Mesa client did not time out")
	}
	// Cancelled/timed out sessions must not poison the next accept deadline.
	client, err := net.Dial("unix", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	accepted, err := acceptMesa(context.Background(), listener, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = accepted.Close()
}

func TestPeerCancellationReleasesPairedSessionWaitingForMesa(t *testing.T) {
	client, server := sessionPair(t, renderQUICConfig())
	stream, err := client.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := protocol.Write(stream, protocol.Envelope{Type: protocol.TypeHello, Payload: []byte("test")}); err != nil {
		t.Fatal(err)
	}
	listener := mesaListener(t)
	done := make(chan error, 1)
	go func() {
		done <- (Bridge{Config: Config{PairingToken: "test", ClientWaitTimeout: 5 * time.Second}}).serveSession(context.Background(), listener, nil, server)
	}()
	// Whether cancellation wins during HELLO or Mesa wait, neither can hang.
	_ = client.CloseWithError(0, "user cancelled")
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled session unexpectedly succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("disconnected peer still owns the session")
	}
}

func TestQuietQUICSessionKeepAliveAndNegativeControl(t *testing.T) {
	for _, keepAlive := range []bool{false, true} {
		t.Run(map[bool]string{false: "idle timeout control", true: "transport keepalive"}[keepAlive], func(t *testing.T) {
			config := renderQUICConfig()
			if config.KeepAlivePeriod <= 0 || config.KeepAlivePeriod >= config.MaxIdleTimeout {
				t.Fatal("production liveness policy invalid")
			}
			config.MaxIdleTimeout = 750 * time.Millisecond
			config.KeepAlivePeriod = 100 * time.Millisecond
			if !keepAlive {
				config.KeepAlivePeriod = 0
			}
			client, server := sessionPair(t, config)
			// No render stream, vtest data or application-level ACK is sent.
			time.Sleep(2250 * time.Millisecond)
			if keepAlive {
				if client.Context().Err() != nil || server.Context().Err() != nil {
					t.Fatal("transport PING did not preserve the quiet session")
				}
			} else if server.Context().Err() == nil || !strings.Contains(context.Cause(server.Context()).Error(), "timeout") {
				t.Fatal("negative control did not hit the negotiated idle timeout")
			}
		})
	}
}
