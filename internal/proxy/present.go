package proxy

import (
	"encoding/binary"
	"fmt"
)

// PresentSignal is sent by Mesa's vtest winsys to the local proxy through a
// Unix datagram socket. ByteOffset is the number of client-to-renderer vtest
// bytes successfully written before flush_frontbuffer emitted the signal.
// This lets the proxy derive a safe RemoteGPU after_sequence.
type PresentSignal struct {
	ByteOffset    uint64
	FrameID       uint64
	ResourceID    uint64
	Level         uint32
	Layer         uint32
	X, Y          uint32
	Width, Height uint32
}

const presentSignalSize = 52

func ParsePresentSignal(b []byte) (PresentSignal, error) {
	if len(b) != presentSignalSize || string(b[:4]) != "RGPF" {
		return PresentSignal{}, fmt.Errorf("remotegpu: malformed Mesa present signal")
	}
	return PresentSignal{
		ByteOffset: binary.LittleEndian.Uint64(b[4:]), FrameID: binary.LittleEndian.Uint64(b[12:]),
		ResourceID: binary.LittleEndian.Uint64(b[20:]), Level: binary.LittleEndian.Uint32(b[28:]),
		Layer: binary.LittleEndian.Uint32(b[32:]), X: binary.LittleEndian.Uint32(b[36:]),
		Y: binary.LittleEndian.Uint32(b[40:]), Width: binary.LittleEndian.Uint32(b[44:]),
		Height: binary.LittleEndian.Uint32(b[48:]),
	}, nil
}
