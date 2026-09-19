package protocol

import (
	"bytes"
	"testing"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	var b bytes.Buffer
	want := VTestChunk(12, []byte{1, 2, 3})
	if err := Write(&b, want); err != nil {
		t.Fatal(err)
	}
	got, err := Read(&b)
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != want.Type || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("got %#v", got)
	}
	seq, payload, err := ParseVTestChunk(got.Payload)
	if err != nil || seq != 12 || !bytes.Equal(payload, []byte{1, 2, 3}) {
		t.Fatalf("chunk: %d %v %v", seq, payload, err)
	}
}

func TestPresentRoundTrip(t *testing.T) {
	want := Present{FrameID: 7, ResourceID: 9, AfterSequence: 12, Width: 1280, Height: 720}
	got, err := ParsePresent(want.MarshalBinary())
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %#v want %#v", got, want)
	}
}
