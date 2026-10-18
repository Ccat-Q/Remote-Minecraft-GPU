// remotegpu-vtest-receiver is a Linux-only diagnostic endpoint. It proves
// that RemoteGPU's ordered QUIC stream can carry unmodified vtest traffic to
// a normal virgl_test_server. It deliberately does not implement PRESENT:
// production presentation belongs to the iOS renderer adapter.
package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
	quic "github.com/quic-go/quic-go"
)

func main() {
	var connectAddr, unixSocket, token, serverName, verifySocket string
	var insecure, inspectPresent bool
	flag.StringVar(&connectAddr, "connect", "127.0.0.1:4433", "RemoteGPU proxy QUIC address")
	flag.StringVar(&unixSocket, "socket", "/tmp/.virgl_test", "virgl_test_server Unix socket")
	flag.StringVar(&token, "pairing-token", "", "required proxy pairing token")
	flag.StringVar(&serverName, "server-name", "", "TLS server name")
	flag.BoolVar(&insecure, "insecure-skip-verify", false, "disable TLS verification (CI-only)")
	flag.BoolVar(&inspectPresent, "inspect-present", false, "validate and log PRESENT without displaying it (CI-only)")
	flag.StringVar(&verifySocket, "verify-present-socket", "", "CI-only native pixel oracle socket; requires -inspect-present; never a display path")
	flag.Parse()
	if token == "" || (verifySocket != "" && !inspectPresent) {
		fmt.Fprintln(os.Stderr, "remotegpu-vtest-receiver: -pairing-token is required")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, connectAddr, unixSocket, token, serverName, insecure, inspectPresent, verifySocket); err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "remotegpu-vtest-receiver:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, connectAddr, unixSocket, token, serverName string, insecure, inspectPresent bool, verifySocket string) error {
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
	var oracle net.Conn
	if verifySocket != "" {
		oracle, err = net.Dial("unix", verifySocket)
		if err != nil {
			return err
		}
		defer oracle.Close()
	}

	bridgeCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	errCh := make(chan error, 2)
	var writeMu sync.Mutex

	go func() {
		var lastSequence, lastFrame, rawBytes uint64
		for {
			envelope, err := protocol.Read(stream)
			if err != nil {
				errCh <- err
				return
			}
			if envelope.Type == protocol.TypePresent {
				if !inspectPresent {
					errCh <- errors.New("PRESENT reached Linux diagnostic receiver")
					return
				}
				p, err := protocol.ParsePresent(envelope.Payload)
				if err != nil || p.FrameID <= lastFrame || p.AfterSequence > lastSequence || p.ResourceID == 0 || p.Width == 0 || p.Height == 0 {
					errCh <- errors.New("invalid or out-of-order PRESENT")
					return
				}
				lastFrame = p.FrameID
				if oracle != nil {
					// Wait for the native decoder to execute this prefix and check
					// actual pixels BEFORE forwarding commands that overwrite it.
					if err := verifyPresent(oracle, rawBytes, p); err != nil {
						errCh <- err
						return
					}
				}
				fmt.Printf("INSPECT_PRESENT frame=%d resource=%d after=%d processed=%d size=%dx%d\n", p.FrameID, p.ResourceID, p.AfterSequence, lastSequence, p.Width, p.Height)
				continue
			}
			if envelope.Type != protocol.TypeVTest {
				errCh <- fmt.Errorf("unexpected RemoteGPU envelope %d", envelope.Type)
				return
			}
			sequence, data, err := protocol.ParseVTestChunk(envelope.Payload)
			if err != nil {
				errCh <- err
				return
			}
			if sequence != lastSequence+1 {
				errCh <- errors.New("vtest sequence gap")
				return
			}
			if err := writeAll(unix, data); err != nil {
				errCh <- err
				return
			}
			lastSequence = sequence
			rawBytes += uint64(len(data))
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

// Private, receiver-local CI control protocol, NOT a RemoteGPU wire opcode.
// No pixel data or vtest TRANSFER_GET travels on QUIC through this helper.
func verifyPresent(oracle net.Conn, rawBytes uint64, p protocol.Present) error {
	if err := oracle.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return err
	}
	defer oracle.SetDeadline(time.Time{})
	request := make([]byte, 56)
	binary.BigEndian.PutUint64(request, rawBytes)
	copy(request[8:], p.MarshalBinary())
	if err := writeAll(oracle, request); err != nil {
		return err
	}
	var ack [8]byte
	if _, err := io.ReadFull(oracle, ack[:]); err != nil {
		return err
	}
	if binary.BigEndian.Uint64(ack[:]) != p.FrameID {
		return errors.New("native pixel oracle ACK frame mismatch")
	}
	return nil
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
