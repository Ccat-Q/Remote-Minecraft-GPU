// Package diagnostics records transport facts without parsing VirGL command
// payloads. It is deliberately safe to leave enabled in a performance run.
package diagnostics

import (
	"encoding/binary"
	"sync"
)

type Snapshot struct {
	VTestCommands map[uint32]uint64
	UploadBytes   uint64
	DownloadBytes uint64
	PresentEvents uint64
}

type Collector struct {
	mu sync.Mutex
	s  Snapshot
}

func NewCollector() *Collector {
	return &Collector{s: Snapshot{VTestCommands: make(map[uint32]uint64)}}
}

// ObserveUpload receives one complete client-to-renderer vtest request.
func (c *Collector) ObserveUpload(message []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.s.UploadBytes += uint64(len(message))
	if len(message) >= 8 {
		id := binary.LittleEndian.Uint32(message[4:8])
		c.s.VTestCommands[id]++
	}
}

// ObserveDownload receives renderer-to-client vtest reply bytes. vtest server
// replies are not self-framed, so this intentionally counts bytes only.
func (c *Collector) ObserveDownload(n int) {
	if n <= 0 {
		return
	}
	c.mu.Lock()
	c.s.DownloadBytes += uint64(n)
	c.mu.Unlock()
}

func (c *Collector) ObservePresent() {
	c.mu.Lock()
	c.s.PresentEvents++
	c.mu.Unlock()
}

// Take returns and clears one reporting interval.
func (c *Collector) Take() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	result := Snapshot{
		VTestCommands: make(map[uint32]uint64, len(c.s.VTestCommands)),
		UploadBytes:   c.s.UploadBytes,
		DownloadBytes: c.s.DownloadBytes,
		PresentEvents: c.s.PresentEvents,
	}
	for id, count := range c.s.VTestCommands {
		result.VTestCommands[id] = count
	}
	c.s = Snapshot{VTestCommands: make(map[uint32]uint64)}
	return result
}
