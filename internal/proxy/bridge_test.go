package proxy

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"io"
	"math/big"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
	quic "github.com/quic-go/quic-go"
)

func TestPresentWaitsForVTestOffsetAndAcknowledgesLocally(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	cert, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := quic.ListenAddr("127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{cert}, PrivateKey: key}}, NextProtos: []string{"rgpu-test"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	connection, err := quic.DialAddr(ctx, listener.Addr().String(), &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"rgpu-test"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseWithError(0, "test finished")
	server, err := listener.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer server.CloseWithError(0, "test finished")
	remote, err := connection.OpenStreamSync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = remote.Write([]byte{0}); err != nil {
		t.Fatal(err)
	}
	stream, err := server.AcceptStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = io.ReadFull(stream, make([]byte, 1)); err != nil {
		t.Fatal(err)
	}
	address := &net.UnixAddr{Name: filepath.Join(t.TempDir(), "present.sock"), Net: "unixgram"}
	present, err := net.ListenUnixgram("unixgram", address)
	if err != nil {
		t.Fatal(err)
	}
	defer present.Close()
	mesa, err := net.DialUnix("unixgram", &net.UnixAddr{Name: filepath.Join(t.TempDir(), "mesa.sock"), Net: "unixgram"}, address)
	if err != nil {
		t.Fatal(err)
	}
	defer mesa.Close()
	client, writer := net.Pipe()
	defer writer.Close()
	finished := make(chan error, 1)
	go func() { finished <- bridge(ctx, client, stream, present, nil) }()
	signal := make([]byte, presentSignalSize)
	copy(signal, "RGPF")
	binary.LittleEndian.PutUint64(signal[4:], 12)
	binary.LittleEndian.PutUint64(signal[12:], 1)
	binary.LittleEndian.PutUint64(signal[20:], 42)
	binary.LittleEndian.PutUint32(signal[44:], 64)
	binary.LittleEndian.PutUint32(signal[48:], 64)
	if _, err := mesa.Write(signal); err != nil {
		t.Fatal(err)
	}
	_ = mesa.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	if _, err := mesa.Read(make([]byte, 12)); err == nil {
		t.Fatal("Mesa received an ACK before its vtest bytes were forwarded")
	} else if timeout, ok := err.(net.Error); !ok || !timeout.Timeout() {
		t.Fatal(err)
	}
	_ = mesa.SetReadDeadline(time.Now().Add(time.Second))
	message := make([]byte, 12)
	binary.LittleEndian.PutUint32(message[0:], 1)
	binary.LittleEndian.PutUint32(message[4:], 3) // RESOURCE_UNREF
	binary.LittleEndian.PutUint32(message[8:], 99)
	if _, err := writer.Write(message); err != nil {
		t.Fatal(err)
	}
	first, err := protocol.Read(remote)
	if err != nil || first.Type != protocol.TypeVTest {
		t.Fatalf("first envelope: %#v %v", first, err)
	}
	marker, err := protocol.Read(remote)
	if err != nil || marker.Type != protocol.TypePresent {
		t.Fatalf("marker envelope: %#v %v", marker, err)
	}
	p, err := protocol.ParsePresent(marker.Payload)
	if err != nil || p.AfterSequence != 1 || p.ResourceID != 42 {
		t.Fatalf("unexpected marker: %#v %v", p, err)
	}
	ack := make([]byte, 13)
	n, err := mesa.Read(ack)
	if err != nil || string(ack[:4]) != "RGPA" || n != 12 || binary.LittleEndian.Uint64(ack[4:]) != 1 {
		t.Fatalf("unexpected local ACK: %x %v", ack, err)
	}
	if _, err := writer.Write(message); err != nil {
		t.Fatal(err)
	}
	last, err := protocol.Read(remote)
	if err != nil || last.Type != protocol.TypeVTest {
		t.Fatalf("post-present envelope: %#v %v", last, err)
	}
	cancel()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("bridge workers did not stop after cancellation")
	}
}
