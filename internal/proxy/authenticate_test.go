package proxy

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/Ccat-Q/Remote-Minecraft-GPU/internal/protocol"
)

func TestAuthenticateDiagnosticsDoNotDiscloseTokens(t *testing.T) {
	const expected = "private-expected-pairing-value"
	const rejected = "private-rejected-pairing-value"
	for _, tc := range []struct {
		name    string
		typeID  byte
		payload string
		want    string
	}{
		{"valid", protocol.TypeHello, expected, ""},
		{"wrong token", protocol.TypeHello, rejected, "pairing rejected"},
		{"trailing newline", protocol.TypeHello, expected + "\n", fmt.Sprintf("received %d bytes, expected %d bytes", len(expected)+1, len(expected))},
		{"wrong envelope", protocol.TypeVTest, rejected, "expected HELLO"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stream bytes.Buffer
			if err := protocol.Write(&stream, protocol.Envelope{Type: tc.typeID, Payload: []byte(tc.payload)}); err != nil {
				t.Fatal(err)
			}
			err := authenticate(&stream, expected)
			if tc.want == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected diagnostic %q, got %v", tc.want, err)
			}
			if strings.Contains(err.Error(), expected) || strings.Contains(err.Error(), rejected) {
				t.Fatal("authentication diagnostic disclosed a token")
			}
		})
	}
}

func TestAuthenticateReportsInvalidAndTruncatedEnvelope(t *testing.T) {
	for _, input := range [][]byte{nil, []byte("RGP"), []byte("BAD!\x01\x00\x00\x00\x00\x00")} {
		if err := authenticate(bytes.NewReader(input), "private-pairing-value"); err == nil {
			t.Fatal("accepted malformed HELLO")
		}
	}
}
