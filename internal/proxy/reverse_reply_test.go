package proxy

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
)

// Observe calls as well as bytes: invalid replies must not even invoke Write.
// This is passed to the same helper used by bridge's reverse goroutine.
type reverseReplyWriter struct {
	bytes.Buffer
	calls int
}

func (w *reverseReplyWriter) Write(p []byte) (int, error) {
	w.calls++
	return w.Buffer.Write(p)
}

func reverseReplyWire(t *testing.T, envelopes ...protocol.Envelope) []byte {
	t.Helper()
	var wire bytes.Buffer
	for _, envelope := range envelopes {
		if err := protocol.Write(&wire, envelope); err != nil {
			t.Fatal(err)
		}
	}
	return wire.Bytes()
}

func TestForwardRendererReplyContinuous(t *testing.T) {
	reader := bytes.NewReader(reverseReplyWire(t,
		protocol.VTestChunk(1, []byte{0, 1, 0xff}),
		protocol.VTestChunk(2, nil), // An empty chunk still consumes a sequence.
		protocol.VTestChunk(3, []byte("third")),
	))
	var mesa reverseReplyWriter
	var sequence uint64
	for i, wantBytes := range []int{3, 0, 5} {
		n, err := forwardRendererReply(reader, &mesa, &sequence)
		if err != nil || n != wantBytes || sequence != uint64(i+1) {
			t.Fatalf("reply %d: n=%d sequence=%d err=%v", i+1, n, sequence, err)
		}
	}
	if want := string([]byte{0, 1, 0xff}) + "third"; mesa.String() != want || mesa.calls != 3 {
		t.Fatalf("Mesa got %x in %d writes, want %x in 3 writes", mesa.Bytes(), mesa.calls, want)
	}
	if n, err := forwardRendererReply(reader, &mesa, &sequence); !errors.Is(err, io.EOF) || n != 0 {
		t.Fatalf("end of stream: n=%d err=%v", n, err)
	}
	if sequence != 3 || mesa.calls != 3 {
		t.Fatal("EOF changed sequence or wrote to Mesa")
	}
}

func TestForwardRendererReplyRejectsBeforeMesaWrite(t *testing.T) {
	flagged := protocol.VTestChunk(1, []byte("must not reach Mesa"))
	flagged.Flags = 1
	flaggedAfterValid := protocol.VTestChunk(2, []byte("must not reach Mesa"))
	flaggedAfterValid.Flags = 0xff
	for _, tc := range []struct {
		name      string
		prefix    []protocol.Envelope
		bad       protocol.Envelope
		wantError string
	}{
		{"first gap", nil, protocol.VTestChunk(2, []byte("bad")), "sequence gap"},
		{"zero", nil, protocol.VTestChunk(0, []byte("bad")), "sequence gap"},
		{"flags", nil, flagged, "flags"},
		{"duplicate", []protocol.Envelope{protocol.VTestChunk(1, []byte("accepted"))}, protocol.VTestChunk(1, []byte("bad")), "sequence gap"},
		{"later gap", []protocol.Envelope{protocol.VTestChunk(1, []byte("accepted"))}, protocol.VTestChunk(3, []byte("bad")), "sequence gap"},
		{"later zero", []protocol.Envelope{protocol.VTestChunk(1, []byte("accepted"))}, protocol.VTestChunk(0, []byte("bad")), "sequence gap"},
		{"later flags", []protocol.Envelope{protocol.VTestChunk(1, []byte("accepted"))}, flaggedAfterValid, "flags"},
		{"missing sequence", nil, protocol.Envelope{Type: protocol.TypeVTest, Payload: []byte{1, 2, 3}}, "missing sequence"},
		{"present", nil, protocol.Envelope{Type: protocol.TypePresent, Payload: []byte("bad")}, "unexpected renderer envelope"},
		{"hello", nil, protocol.Envelope{Type: protocol.TypeHello, Payload: []byte("secret-token-must-not-appear")}, "unexpected renderer envelope"},
		{"error", nil, protocol.Envelope{Type: protocol.TypeError, Payload: []byte("bad")}, "unexpected renderer envelope"},
		{"unknown type", nil, protocol.Envelope{Type: 255, Payload: []byte("bad")}, "unexpected renderer envelope"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			envelopes := append(append([]protocol.Envelope{}, tc.prefix...), tc.bad)
			// A valid suffix must remain unread when the bridge stops on error.
			wire := reverseReplyWire(t, append(envelopes, protocol.VTestChunk(uint64(len(tc.prefix)+1), []byte("suffix")))...)
			reader := bytes.NewReader(wire)
			var mesa reverseReplyWriter
			var sequence uint64
			for range tc.prefix {
				if _, err := forwardRendererReply(reader, &mesa, &sequence); err != nil {
					t.Fatal(err)
				}
			}
			before, calls, last := mesa.String(), mesa.calls, sequence
			n, err := forwardRendererReply(reader, &mesa, &sequence)
			if err == nil || !strings.Contains(err.Error(), tc.wantError) || n != 0 {
				t.Fatalf("n=%d err=%v, want %q", n, err, tc.wantError)
			}
			if strings.Contains(err.Error(), "secret-token-must-not-appear") {
				t.Fatal("error exposed envelope payload")
			}
			if mesa.String() != before || mesa.calls != calls || sequence != last {
				t.Fatal("rejected reply changed Mesa output or sequence")
			}
			if reader.Len() == 0 {
				t.Fatal("consumed valid suffix after a rejected reply")
			}
		})
	}
}

func TestForwardRendererReplyMalformedWireDoesNotWrite(t *testing.T) {
	valid := reverseReplyWire(t, protocol.VTestChunk(1, []byte("payload")))
	badMagic := append([]byte(nil), valid...)
	badMagic[0] = '!'
	oversized := append([]byte(nil), valid[:protocol.HeaderSize]...)
	binary.BigEndian.PutUint32(oversized[6:], protocol.MaxPayload+1)
	for _, tc := range []struct {
		name string
		wire []byte
	}{
		{"truncated header", valid[:protocol.HeaderSize-1]},
		{"truncated payload", valid[:len(valid)-1]},
		{"bad magic", badMagic},
		{"oversized", oversized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var mesa reverseReplyWriter
			var sequence uint64
			if n, err := forwardRendererReply(bytes.NewReader(tc.wire), &mesa, &sequence); err == nil || n != 0 {
				t.Fatalf("n=%d err=%v, want malformed wire rejection", n, err)
			}
			if mesa.calls != 0 || mesa.Len() != 0 || sequence != 0 {
				t.Fatal("malformed envelope reached Mesa or advanced sequence")
			}
		})
	}
}

func TestForwardRendererReplySequenceExhaustion(t *testing.T) {
	const maximum = ^uint64(0)
	sequence := maximum - 1
	reader := bytes.NewReader(reverseReplyWire(t,
		protocol.VTestChunk(maximum, []byte("last")),
		protocol.VTestChunk(0, []byte("wrapped")),
	))
	var mesa reverseReplyWriter
	if n, err := forwardRendererReply(reader, &mesa, &sequence); err != nil || n != 4 || sequence != maximum {
		t.Fatalf("last valid reply: n=%d sequence=%d err=%v", n, sequence, err)
	}
	if n, err := forwardRendererReply(reader, &mesa, &sequence); err == nil || !strings.Contains(err.Error(), "exhausted") || n != 0 {
		t.Fatalf("wrapped reply: n=%d err=%v", n, err)
	}
	if mesa.String() != "last" || mesa.calls != 1 || sequence != maximum {
		t.Fatal("sequence wrapped or exhausted reply reached Mesa")
	}
}

type failingReverseReplyWriter struct {
	n     int
	err   error
	calls int
}

func (w *failingReverseReplyWriter) Write([]byte) (int, error) {
	w.calls++
	return w.n, w.err
}

func TestForwardRendererReplyWriteFailureDoesNotAdvance(t *testing.T) {
	writeError := errors.New("Mesa disconnected")
	for _, tc := range []struct {
		name       string
		n          int
		writeError error
		wantError  error
	}{
		{"failure", 0, writeError, writeError},
		{"partial failure", 2, writeError, writeError},
		{"short write", 2, nil, io.ErrShortWrite},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mesa := &failingReverseReplyWriter{n: tc.n, err: tc.writeError}
			var sequence uint64
			n, err := forwardRendererReply(bytes.NewReader(reverseReplyWire(t, protocol.VTestChunk(1, []byte("reply")))), mesa, &sequence)
			if n != tc.n || !errors.Is(err, tc.wantError) || sequence != 0 || mesa.calls != 1 {
				t.Fatalf("n=%d sequence=%d writes=%d err=%v", n, sequence, mesa.calls, err)
			}
		})
	}
}
