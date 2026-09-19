package vtest

import (
	"encoding/binary"
	"fmt"
)

// Command IDs in the legacy profile. The IDs are inspected only for a
// fail-closed diagnostic; vtest bytes are otherwise passed through unchanged.
const (
	CmdGetCaps            = 1
	CmdResourceCreate     = 2
	CmdResourceUnref      = 3
	CmdTransferGet        = 4
	CmdTransferPut        = 5
	CmdSubmit             = 6
	CmdBusyWait           = 7
	CmdCreateRenderer     = 8
	CmdGetCaps2           = 9
	CmdPingProtocol       = 10
	CmdProtocolVersion    = 11
	CmdResourceCreate2    = 12
	CmdTransferGet2       = 13
	CmdTransferPut2       = 14
	CmdGetParam           = 15
	CmdGetCapset          = 16
	CmdContextInit        = 17
	CmdResourceCreateBlob = 18
	CmdSyncCreate         = 19
	CmdSyncUnref          = 20
	CmdSyncRead           = 21
	CmdSyncWrite          = 22
	CmdSyncWait           = 23
	CmdSubmit2            = 24
	CmdDRMSyncCreate      = 25
	CmdResourceExportFD   = 40
)

func Supported(id uint32) bool {
	switch id {
	case CmdGetCaps, CmdResourceCreate, CmdResourceUnref, CmdTransferGet,
		CmdTransferPut, CmdSubmit, CmdBusyWait, CmdCreateRenderer,
		CmdGetCaps2, CmdPingProtocol, CmdProtocolVersion:
		return true
	default:
		return false
	}
}

func ValidateHeader(id uint32) error {
	if !Supported(id) {
		return fmt.Errorf("REMOTEGPU_ERR_UNSUPPORTED_VTEST_COMMAND: %d", id)
	}
	return nil
}

// LegacyDecoder turns arbitrary Unix stream reads into complete protocol-0
// client requests. It does not alter a byte. In particular, TRANSFER_PUT has
// an inline payload whose exact length is stored in argument 10 rather than
// being inferred from the dword-rounded header length.
type LegacyDecoder struct{ pending []byte }

const maxMessage = 16 << 20

func (d *LegacyDecoder) Feed(input []byte) ([][]byte, error) {
	d.pending = append(d.pending, input...)
	var messages [][]byte
	for {
		if len(d.pending) < 8 {
			return messages, nil
		}
		words := binary.LittleEndian.Uint32(d.pending[:4])
		id := binary.LittleEndian.Uint32(d.pending[4:8])
		if err := ValidateHeader(id); err != nil {
			return nil, err
		}
		var size uint64
		if id == CmdTransferPut {
			// The header advertises a dword-rounded length, but Mesa sends the
			// payload as an unpadded second write.  Do not wait for that padding:
			// an exact-size payload is a valid complete request.
			if words < 11 {
				return nil, fmt.Errorf("REMOTEGPU_ERR_INVALID_TRANSFER_PUT")
			}
			const transferPutArguments = 8 + 11*4
			if len(d.pending) < transferPutArguments {
				return messages, nil
			}
			dataSize := binary.LittleEndian.Uint32(d.pending[8+10*4:])
			size = transferPutArguments + uint64(dataSize)
		} else if id == CmdCreateRenderer {
			size = 8 + uint64(words) // process name is a byte string
		} else {
			size = 8 + uint64(words)*4
		}
		if size > maxMessage {
			return nil, fmt.Errorf("REMOTEGPU_ERR_VTEST_MESSAGE_TOO_LARGE: %d", size)
		}
		if len(d.pending) < int(size) {
			return messages, nil
		}
		message := append([]byte(nil), d.pending[:size]...)
		d.pending = d.pending[size:]
		if id == CmdProtocolVersion {
			if words != 1 || binary.LittleEndian.Uint32(message[8:]) != 0 {
				return nil, fmt.Errorf("REMOTEGPU_ERR_PROTOCOL_VERSION: only vtest protocol 0 is supported")
			}
		}
		messages = append(messages, message)
	}
}
