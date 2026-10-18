package proxy

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"time"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/diagnostics"
	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/vtest"
	quic "github.com/quic-go/quic-go"
)

type Config struct {
	UnixSocket, PresentSocket, ListenAddr, PairingToken string
	TLSConfig                                           *tls.Config
	Diagnostics                                         *diagnostics.Collector
	HelloTimeout, ClientWaitTimeout                     time.Duration
}

type Bridge struct{ Config Config }

func (b Bridge) Serve(ctx context.Context) error {
	if b.Config.TLSConfig == nil {
		return errors.New("remotegpu: TLS config is required")
	}
	_ = os.Remove(b.Config.UnixSocket)
	_ = os.Remove(b.Config.PresentSocket)
	unix, err := net.Listen("unix", b.Config.UnixSocket)
	if err != nil {
		return err
	}
	defer unix.Close()
	presentAddr, err := net.ResolveUnixAddr("unixgram", b.Config.PresentSocket)
	if err != nil {
		return err
	}
	present, err := net.ListenUnixgram("unixgram", presentAddr)
	if err != nil {
		return err
	}
	defer present.Close()
	listener, err := quic.ListenAddr(b.Config.ListenAddr, b.Config.TLSConfig, renderQUICConfig())
	if err != nil {
		return err
	}
	defer listener.Close()
	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			return err
		}
		if err := b.serveSession(ctx, unix, present, conn); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			// Keep the actual failure stage; never include HELLO/token bytes.
			log.Printf("SESSION_ERROR peer=%s: %v", conn.RemoteAddr(), err)
		}
	}
}

// serveSession deliberately isolates one iPhone connection. A lost mobile
// connection must release the associated Mesa client and allow a later paired
// connection to establish a fresh vtest session on the same proxy listener.
func (b Bridge) serveSession(ctx context.Context, unix net.Listener, present *net.UnixConn, conn quic.Connection) error {
	defer conn.CloseWithError(0, "session closed")
	// A peer disappearing while we wait for HELLO or a local client must not
	// occupy the sole diagnostic session until another network packet arrives.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stopPeer := context.AfterFunc(conn.Context(), cancel)
	defer stopPeer()
	helloTimeout := b.Config.HelloTimeout
	if helloTimeout <= 0 {
		helloTimeout = 10 * time.Second
	}
	helloDeadline := time.Now().Add(helloTimeout)
	helloCtx, stopHello := context.WithDeadline(ctx, helloDeadline)
	stream, err := conn.AcceptStream(helloCtx)
	stopHello()
	if err != nil {
		return fmt.Errorf("accept QUIC stream: %w", err)
	}
	stopRead := context.AfterFunc(ctx, func() { stream.CancelRead(0) })
	defer stopRead()
	if err := stream.SetReadDeadline(helloDeadline); err != nil {
		return fmt.Errorf("HELLO deadline: %w", err)
	}
	if err := authenticate(stream, b.Config.PairingToken); err != nil {
		return fmt.Errorf("authenticate HELLO: %w", err)
	}
	if err := stream.SetReadDeadline(time.Time{}); err != nil {
		return fmt.Errorf("clear HELLO deadline: %w", err)
	}
	log.Printf("SESSION_AUTHENTICATED peer=%s; waiting for local Mesa client", conn.RemoteAddr())
	wait := b.Config.ClientWaitTimeout
	if wait <= 0 {
		wait = 30 * time.Second
	}
	client, err := acceptMesa(ctx, unix, wait)
	if err != nil {
		return fmt.Errorf("accept local Mesa client: %w", err)
	}
	defer client.Close()
	log.Printf("SESSION_MESA_ATTACHED peer=%s", conn.RemoteAddr())
	if err := bridge(ctx, client, stream, present, b.Config.Diagnostics); err != nil {
		return fmt.Errorf("bridge vtest/PRESENT: %w", err)
	}
	return nil
}

// QUIC PINGs keep a quiet live session reachable. This is transport liveness,
// not an application ACK, frame retransmission or proof of visual acceptance.
func renderQUICConfig() *quic.Config {
	return &quic.Config{MaxIdleTimeout: 30 * time.Second, KeepAlivePeriod: 5 * time.Second}
}

func acceptMesa(ctx context.Context, listener net.Listener, timeout time.Duration) (net.Conn, error) {
	unix, ok := listener.(*net.UnixListener)
	if !ok {
		return nil, errors.New("Mesa listener must be a Unix listener")
	}
	if err := unix.SetDeadline(time.Now().Add(timeout)); err != nil {
		return nil, err
	}
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		_ = unix.SetDeadline(time.Now())
		close(done)
	})
	defer func() {
		if !stop() {
			<-done
		}
		// The listener is reused by the next session. Do not leave a stale
		// cancellation deadline that would reject a later valid phone/client.
		_ = unix.SetDeadline(time.Time{})
	}()
	client, err := unix.Accept()
	if ctx.Err() != nil {
		if client != nil {
			_ = client.Close()
		}
		return nil, ctx.Err()
	}
	return client, err
}

func authenticate(stream io.Reader, token string) error {
	e, err := protocol.Read(stream)
	if err != nil {
		return err
	}
	if e.Type != protocol.TypeHello {
		return fmt.Errorf("remotegpu: expected HELLO type=%d, received type=%d", protocol.TypeHello, e.Type)
	}
	if string(e.Payload) != token {
		return fmt.Errorf("remotegpu: pairing rejected (received %d bytes, expected %d bytes)", len(e.Payload), len(token))
	}
	return nil
}

func bridge(ctx context.Context, unix net.Conn, stream quic.Stream, present *net.UnixConn, stats *diagnostics.Collector) error {
	ctx, cancel := context.WithCancel(ctx)
	var workers sync.WaitGroup
	workers.Add(3)
	defer func() {
		cancel()
		_ = unix.Close()
		stream.CancelRead(0)
		stream.CancelWrite(0)
		_ = present.SetReadDeadline(time.Now())
		workers.Wait()
		_ = present.SetReadDeadline(time.Time{})
	}()
	var writeMu sync.Mutex
	var stateMu sync.Mutex
	var forwarded uint64
	var sequence uint64
	var failed bool
	stateChanged := make(chan struct{})
	done := make(chan error, 1)
	var failOnce sync.Once
	fail := func(err error) {
		failOnce.Do(func() {
			stateMu.Lock()
			failed = true
			close(stateChanged)
			stateMu.Unlock()
			done <- err
		})
	}
	notifyStateLocked := func() {
		close(stateChanged)
		stateChanged = make(chan struct{})
	}

	// Mesa-to-iPhone raw vtest bytes. Chunks are sequence-numbered by this
	// proxy, preserving exact byte order on the QUIC render stream.
	go func() {
		defer workers.Done()
		buf := make([]byte, 32*1024)
		var decoder vtest.LegacyDecoder
		for {
			n, err := unix.Read(buf)
			if n > 0 {
				messages, decodeErr := decoder.Feed(buf[:n])
				if decodeErr != nil {
					fail(decodeErr)
					return
				}
				for _, message := range messages {
					if stats != nil {
						stats.ObserveUpload(message)
					}
					writeMu.Lock()
					stateMu.Lock()
					seq := sequence + 1
					stateMu.Unlock()
					err2 := protocol.Write(stream, protocol.VTestChunk(seq, message))
					if err2 != nil {
						writeMu.Unlock()
						fail(err2)
						return
					}
					stateMu.Lock()
					sequence = seq
					forwarded += uint64(len(message))
					notifyStateLocked()
					stateMu.Unlock()
					writeMu.Unlock()
				}
			}
			if err != nil {
				fail(err)
				return
			}
		}
	}()

	// Renderer-to-Mesa replies must be vtest bytes only; iOS may not inject a
	// presentation marker into the reverse direction.
	go func() {
		defer workers.Done()
		for {
			e, err := protocol.Read(stream)
			if err != nil {
				fail(err)
				return
			}
			if e.Type != protocol.TypeVTest {
				fail(fmt.Errorf("remotegpu: unexpected renderer envelope %d", e.Type))
				return
			}
			_, data, err := protocol.ParseVTestChunk(e.Payload)
			if err != nil {
				fail(err)
				return
			}
			if _, err = unix.Write(data); err != nil {
				fail(err)
				return
			}
			if stats != nil {
				stats.ObserveDownload(len(data))
			}
		}
	}()

	go func() {
		defer workers.Done()
		buf := make([]byte, presentSignalSize+1)
		for {
			n, sender, err := present.ReadFromUnix(buf)
			if err != nil {
				fail(err)
				return
			}
			signal, err := ParsePresentSignal(buf[:n])
			if err != nil {
				fail(err)
				return
			}
			if stats != nil {
				stats.ObservePresent()
			}
			stateMu.Lock()
			for forwarded < signal.ByteOffset {
				if failed {
					stateMu.Unlock()
					return
				}
				waitForForward := stateChanged
				stateMu.Unlock()
				select {
				case <-ctx.Done():
					return
				case <-waitForForward:
				}
				stateMu.Lock()
			}
			stateMu.Unlock()
			writeMu.Lock()
			stateMu.Lock()
			after := sequence
			stateMu.Unlock()
			p := protocol.Present{FrameID: signal.FrameID, ResourceID: signal.ResourceID, AfterSequence: after, Level: signal.Level, Layer: signal.Layer, X: signal.X, Y: signal.Y, Width: signal.Width, Height: signal.Height}
			err = protocol.Write(stream, protocol.Envelope{Type: protocol.TypePresent, Payload: p.MarshalBinary()})
			writeMu.Unlock()
			if err != nil {
				fail(err)
				return
			}
			if sender == nil {
				fail(errors.New("remotegpu: Mesa present sender has no reply address"))
				return
			}
			ack := PresentAck(signal.FrameID)
			if _, err := present.WriteToUnix(ack, sender); err != nil {
				fail(err)
				return
			}
		}
	}()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-done:
		return err
	}
}

func LoadTLS(certFile, keyFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, err
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13, NextProtos: []string{"remotegpu/1"}}, nil
}
