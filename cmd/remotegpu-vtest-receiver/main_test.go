package main

import (
	"encoding/binary"
	"io"
	"net"
	"testing"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
)

func TestNativeOracleBoundaryAndAck(t *testing.T) {
	for _, badAck := range []bool{false, true} {
		client, server := net.Pipe()
		p := protocol.Present{FrameID: 7, ResourceID: 42, AfterSequence: 9, Width: 64, Height: 64}
		done := make(chan error, 1)
		go func() {
			defer server.Close()
			var request [56]byte
			_, err := io.ReadFull(server, request[:])
			if err == nil && binary.BigEndian.Uint64(request[:8]) != 1234 {
				t.Error("raw byte boundary lost")
			}
			got, parseErr := protocol.ParsePresent(request[8:])
			if parseErr != nil || got != p {
				t.Error("PRESENT payload changed")
			}
			frame := p.FrameID
			if badAck {
				frame++
			}
			var ack [8]byte
			binary.BigEndian.PutUint64(ack[:], frame)
			// Exercise fragmented ACK reads as well as invalid frame rejection.
			for _, b := range ack {
				if _, writeErr := server.Write([]byte{b}); writeErr != nil {
					err = writeErr
					break
				}
			}
			done <- err
		}()
		err := verifyPresent(client, 1234, p)
		client.Close()
		if (err != nil) != badAck {
			t.Fatalf("badAck=%v, err=%v", badAck, err)
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}
