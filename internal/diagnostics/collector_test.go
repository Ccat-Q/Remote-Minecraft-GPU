package diagnostics

import (
	"encoding/binary"
	"testing"
)

func TestCollectorTakesIndependentIntervals(t *testing.T) {
	c := NewCollector()
	message := make([]byte, 8)
	binary.LittleEndian.PutUint32(message[4:], 6)
	c.ObserveUpload(message)
	c.ObserveDownload(9)
	c.ObservePresent()
	got := c.Take()
	if got.UploadBytes != 8 || got.DownloadBytes != 9 || got.PresentEvents != 1 || got.VTestCommands[6] != 1 {
		t.Fatalf("unexpected snapshot: %#v", got)
	}
	if next := c.Take(); next.UploadBytes != 0 || len(next.VTestCommands) != 0 {
		t.Fatalf("collector was not reset: %#v", next)
	}
}
