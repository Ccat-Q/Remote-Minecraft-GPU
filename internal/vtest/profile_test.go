package vtest

import (
	"encoding/binary"
	"testing"
)

func TestLegacyProfileIsFailClosed(t *testing.T) {
	if err := ValidateHeader(CmdSubmit); err != nil {
		t.Fatal(err)
	}
	for _, command := range []uint32{CmdResourceCreate2, CmdResourceCreateBlob, CmdSyncCreate, CmdResourceExportFD} {
		if err := ValidateHeader(command); err == nil {
			t.Fatalf("command %d must be rejected", command)
		}
	}
}

func frame(id uint32, words uint32, body []byte) []byte {
	b := make([]byte, 8+len(body))
	binary.LittleEndian.PutUint32(b, words)
	binary.LittleEndian.PutUint32(b[4:], id)
	copy(b[8:], body)
	return b
}

func TestLegacyDecoderHandlesFragmentedInlineTransfer(t *testing.T) {
	args := make([]byte, 11*4)
	binary.LittleEndian.PutUint32(args[10*4:], 3)
	message := append(frame(CmdTransferPut, 12, args), []byte{1, 2, 3}...)
	var d LegacyDecoder
	got, err := d.Feed(message[:17])
	if err != nil || len(got) != 0 {
		t.Fatalf("early decode: %d %v", len(got), err)
	}
	got, err = d.Feed(message[17:])
	if err != nil || len(got) != 1 || string(got[0]) != string(message) {
		t.Fatalf("decode: %v %v", got, err)
	}
}

func TestLegacyDecoderRejectsNewProtocol(t *testing.T) {
	var d LegacyDecoder
	_, err := d.Feed(frame(CmdResourceCreate2, 0, nil))
	if err == nil {
		t.Fatal("expected unsupported command rejection")
	}
}
