package protocol

import (
	"encoding/binary"
	"fmt"
	"io"
)

const (
	Magic       = "RGP1"
	HeaderSize  = 10
	MaxPayload  = 16 << 20
	TypeHello   = 1
	TypeVTest   = 2
	TypePresent = 3
	TypeError   = 4
)

type Envelope struct {
	Type    byte
	Flags   byte
	Payload []byte
}

// VTestChunk payload is an ordered sequence number followed by untouched
// vtest bytes. The sequence belongs to RemoteGPU, not vtest.
func VTestChunk(sequence uint64, data []byte) Envelope {
	p := make([]byte, 8+len(data))
	binary.BigEndian.PutUint64(p, sequence)
	copy(p[8:], data)
	return Envelope{Type: TypeVTest, Payload: p}
}

func ParseVTestChunk(payload []byte) (uint64, []byte, error) {
	if len(payload) < 8 {
		return 0, nil, fmt.Errorf("remotegpu: VTEST_BYTES missing sequence")
	}
	return binary.BigEndian.Uint64(payload[:8]), payload[8:], nil
}

func Write(w io.Writer, e Envelope) error {
	if len(e.Payload) > MaxPayload {
		return fmt.Errorf("remotegpu: payload too large: %d", len(e.Payload))
	}
	h := make([]byte, HeaderSize)
	copy(h, Magic)
	h[4], h[5] = e.Type, e.Flags
	binary.BigEndian.PutUint32(h[6:], uint32(len(e.Payload)))
	if _, err := w.Write(h); err != nil {
		return err
	}
	_, err := w.Write(e.Payload)
	return err
}

func Read(r io.Reader) (Envelope, error) {
	h := make([]byte, HeaderSize)
	if _, err := io.ReadFull(r, h); err != nil {
		return Envelope{}, err
	}
	if string(h[:4]) != Magic {
		return Envelope{}, fmt.Errorf("remotegpu: invalid envelope magic")
	}
	n := binary.BigEndian.Uint32(h[6:])
	if n > MaxPayload {
		return Envelope{}, fmt.Errorf("remotegpu: payload too large: %d", n)
	}
	p := make([]byte, n)
	if _, err := io.ReadFull(r, p); err != nil {
		return Envelope{}, err
	}
	return Envelope{Type: h[4], Flags: h[5], Payload: p}, nil
}
