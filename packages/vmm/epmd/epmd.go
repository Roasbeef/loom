// Package epmd registers a guest's Erlang node in the host's epmd.
//
// An orchestrator finds an executor the way any Erlang node finds a peer: it
// asks the epmd on the peer's host for the port registered under the node's
// name, then connects there. A guest's epmd is unreachable from the host,
// because the host has no route into the guest's network; only the ports the
// launcher forwards are. So the launcher forwards the guest's distribution
// port to a host port and registers the guest node's name in the host's own
// epmd, pointing at that forwarded port. The orchestrator's lookup then
// resolves the guest node like any local one, and the TLS handshake that
// follows is the same handshake, with the same pinned certificates, that a
// node on the host would get.
//
// epmd keeps a registration exactly as long as the TCP connection that made
// it stays open, so a Registration is that connection. Closing it, or this
// process dying, withdraws the name, which is what ties the name's lifetime
// to the VM's.
//
// The wire format is the ALIVE2 request of the Erlang distribution protocol
// (erts/doc, "Distribution Protocol", "Register a Node in EPMD").
package epmd

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// Request and reply tags of the ALIVE2 exchange.
const (
	alive2Req    = 120
	alive2Resp   = 121
	alive2XResp  = 118
	normalNode   = 77
	tcpIPv4      = 0
	distVersion6 = 6
)

// DefaultAddress is where an epmd listens unless ERL_EPMD_PORT moved it.
const DefaultAddress = "127.0.0.1:4369"

// Registration is a live epmd registration. The name stays registered until
// Close is called or the process exits.
type Registration struct {
	conn     net.Conn
	creation uint32
}

// Register registers the node short name name (the part before "@") at port
// in the epmd at address, and returns the open registration.
//
// ## Examples
//
//	reg, err := epmd.Register(epmd.DefaultAddress, "loom_exec_vm1", 47011)
//	defer reg.Close()
func Register(address, name string, port uint16) (*Registration, error) {
	if name == "" || strings.ContainsAny(name, "@ \x00") || len(name) > 255 {
		return nil, fmt.Errorf("epmd: %q is not a node short name", name)
	}

	conn, err := net.DialTimeout("tcp", address, 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("epmd: dial %s: %w", address, err)
	}

	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		conn.Close()
		return nil, err
	}

	if _, err := conn.Write(alive2Request(name, port)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("epmd: register %s: %w", name, err)
	}

	creation, err := readReply(conn)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("epmd: register %s: %w", name, err)
	}

	// The registration lives as long as the connection, so the deadline that
	// bounded the exchange must not also bound the registration.
	if err := conn.SetDeadline(time.Time{}); err != nil {
		conn.Close()
		return nil, err
	}

	return &Registration{conn: conn, creation: creation}, nil
}

// Creation is the creation number epmd assigned the registration.
func (r *Registration) Creation() uint32 { return r.creation }

// Close withdraws the registration.
func (r *Registration) Close() error { return r.conn.Close() }

// alive2Request encodes an ALIVE2_REQ for a normal node speaking
// distribution version 6 over TCP/IPv4, with no extra field.
func alive2Request(name string, port uint16) []byte {
	body := make([]byte, 0, 13+len(name))
	body = append(body, alive2Req)
	body = binary.BigEndian.AppendUint16(body, port)
	body = append(body, normalNode, tcpIPv4)
	body = binary.BigEndian.AppendUint16(body, distVersion6)
	body = binary.BigEndian.AppendUint16(body, distVersion6)
	body = binary.BigEndian.AppendUint16(body, uint16(len(name)))
	body = append(body, name...)
	body = binary.BigEndian.AppendUint16(body, 0)

	frame := binary.BigEndian.AppendUint16(nil, uint16(len(body)))
	return append(frame, body...)
}

// readReply reads ALIVE2_RESP or ALIVE2_X_RESP and returns the creation. A
// nonzero result means epmd refused, most often because the name is taken.
func readReply(r io.Reader) (uint32, error) {
	var head [2]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return 0, err
	}

	if head[1] != 0 {
		return 0, fmt.Errorf("refused with result %d (name already registered?)", head[1])
	}

	switch head[0] {
	case alive2XResp:
		var c [4]byte
		if _, err := io.ReadFull(r, c[:]); err != nil {
			return 0, err
		}
		return binary.BigEndian.Uint32(c[:]), nil

	case alive2Resp:
		var c [2]byte
		if _, err := io.ReadFull(r, c[:]); err != nil {
			return 0, err
		}
		return uint32(binary.BigEndian.Uint16(c[:])), nil

	default:
		return 0, errors.New("unexpected reply tag " + fmt.Sprint(head[0]))
	}
}
