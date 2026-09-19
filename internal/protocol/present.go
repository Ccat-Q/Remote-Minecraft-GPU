package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// Present is a renderer-side marker, not a vtest command.
type Present struct {
	FrameID, ResourceID, AfterSequence uint64
	Level, Layer                       uint32
	X, Y, Width, Height                uint32
}

func (p Present) MarshalBinary() []byte {
	b := make([]byte, 48)
	binary.BigEndian.PutUint64(b[0:], p.FrameID)
	binary.BigEndian.PutUint64(b[8:], p.ResourceID)
	binary.BigEndian.PutUint64(b[16:], p.AfterSequence)
	binary.BigEndian.PutUint32(b[24:], p.Level)
	binary.BigEndian.PutUint32(b[28:], p.Layer)
	binary.BigEndian.PutUint32(b[32:], p.X)
	binary.BigEndian.PutUint32(b[36:], p.Y)
	binary.BigEndian.PutUint32(b[40:], p.Width)
	binary.BigEndian.PutUint32(b[44:], p.Height)
	return b
}

func ParsePresent(b []byte) (Present, error) {
	if len(b) != 48 {
		return Present{}, fmt.Errorf("remotegpu: PRESENT has %d bytes", len(b))
	}
	r := bytes.NewReader(b)
	var p Present
	for _, field := range []any{&p.FrameID, &p.ResourceID, &p.AfterSequence, &p.Level, &p.Layer, &p.X, &p.Y, &p.Width, &p.Height} {
		if err := binary.Read(r, binary.BigEndian, field); err != nil {
			return Present{}, err
		}
	}
	return p, nil
}
