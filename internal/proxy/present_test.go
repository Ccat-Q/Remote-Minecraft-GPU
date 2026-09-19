package proxy

import (
	"encoding/binary"
	"testing"
)

func TestParsePresentSignal(t *testing.T) {
	b := make([]byte, presentSignalSize)
	copy(b, "RGPF")
	binary.LittleEndian.PutUint64(b[4:], 42)
	binary.LittleEndian.PutUint64(b[12:], 7)
	binary.LittleEndian.PutUint64(b[20:], 9)
	binary.LittleEndian.PutUint32(b[44:], 1280)
	binary.LittleEndian.PutUint32(b[48:], 720)
	p, err := ParsePresentSignal(b)
	if err != nil || p.ByteOffset != 42 || p.FrameID != 7 || p.Width != 1280 {
		t.Fatalf("%#v %v", p, err)
	}
}
