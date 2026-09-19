package proxy

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/vtest"
	quic "github.com/quic-go/quic-go"
)

type Config struct {
	UnixSocket, PresentSocket, ListenAddr, PairingToken string
	TLSConfig                                           *tls.Config
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
	listener, err := quic.ListenAddr(b.Config.ListenAddr, b.Config.TLSConfig, nil)
	if err != nil {
		return err
	}
	defer listener.Close()
	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			return err
		}
		if err := b.serveSession(ctx, unix, present, conn); err != nil && ctx.Err() != nil {
			return ctx.Err()
		}
	}
}

// serveSession deliberately isolates one iPhone connection. A lost mobile
// connection must release the associated Mesa client and allow a later paired
// connection to establish a fresh vtest session on the same proxy listener.
func (b Bridge) serveSession(ctx context.Context, unix net.Listener, present *net.UnixConn, conn quic.Connection) error {
	defer conn.CloseWithError(0, "session closed")
	stream, err := conn.AcceptStream(ctx)
	if err != nil {
		return err
	}
	if err := authenticate(stream, b.Config.PairingToken); err != nil {
		return err
	}
	client, err := unix.Accept()
	if err != nil {
		return err
	}
	defer client.Close()
	return bridge(ctx, client, stream, present)
}

func authenticate(stream quic.Stream, token string) error {
	e, err := protocol.Read(stream)
	if err != nil {
		return err
	}
	if e.Type != protocol.TypeHello || string(e.Payload) != token {
		return errors.New("remotegpu: pairing rejected")
	}
	return nil
}

func bridge(ctx context.Context, unix net.Conn, stream quic.Stream, present *net.UnixConn) error {
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
					stateMu.Lock()
					sequence++
					seq := sequence
					stateMu.Unlock()
					writeMu.Lock()
					err2 := protocol.Write(stream, protocol.VTestChunk(seq, message))
					writeMu.Unlock()
					if err2 != nil {
						fail(err2)
						return
					}
					stateMu.Lock()
					forwarded += uint64(len(message))
					notifyStateLocked()
					stateMu.Unlock()
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
		}
	}()

	go func() {
		buf := make([]byte, presentSignalSize)
		for {
			n, _, err := present.ReadFromUnix(buf)
			if err != nil {
				fail(err)
				return
			}
			signal, err := ParsePresentSignal(buf[:n])
			if err != nil {
				fail(err)
				return
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
			after := sequence
			stateMu.Unlock()
			p := protocol.Present{FrameID: signal.FrameID, ResourceID: signal.ResourceID, AfterSequence: after, Level: signal.Level, Layer: signal.Layer, X: signal.X, Y: signal.Y, Width: signal.Width, Height: signal.Height}
			writeMu.Lock()
			err = protocol.Write(stream, protocol.Envelope{Type: protocol.TypePresent, Payload: p.MarshalBinary()})
			writeMu.Unlock()
			if err != nil {
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
