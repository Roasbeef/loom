package epmd

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestAlive2RequestLayout checks the request byte for byte against the
// layout the distribution protocol documents.
func TestAlive2RequestLayout(t *testing.T) {
	got := alive2Request("vm1", 0x1234)
	want := []byte{
		0, 16, // length of what follows
		120,        // ALIVE2_REQ
		0x12, 0x34, // port
		77, 0, // normal node, TCP/IPv4
		0, 6, 0, 6, // highest and lowest version
		0, 3, 'v', 'm', '1', // name
		0, 0, // no extra
	}

	if !bytes.Equal(got, want) {
		t.Fatalf("alive2Request = %v, want %v", got, want)
	}
}

// TestRegisterAgainstFakeEpmd checks the reply handling and that the
// registration holds its connection open.
func TestRegisterAgainstFakeEpmd(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	closed := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		buf := make([]byte, 64)
		_, _ = conn.Read(buf)
		reply := []byte{alive2XResp, 0}
		reply = binary.BigEndian.AppendUint32(reply, 7)
		_, _ = conn.Write(reply)

		// The registration ends when the client closes its end.
		_, _ = conn.Read(buf)
		close(closed)
	}()

	reg, err := Register(ln.Addr().String(), "vm1", 4000)
	if err != nil {
		t.Fatal(err)
	}
	if reg.Creation() != 7 {
		t.Fatalf("creation = %d", reg.Creation())
	}

	reg.Close()
	<-closed
}

// TestRegisterRefusal checks that a nonzero result is an error.
func TestRegisterRefusal(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		buf := make([]byte, 64)
		_, _ = conn.Read(buf)
		_, _ = conn.Write([]byte{alive2Resp, 1, 0, 0})
	}()

	if _, err := Register(ln.Addr().String(), "vm1", 4000); err == nil {
		t.Fatal("refusal accepted")
	}
}

// TestRegisterWithRealEpmd registers against the host's epmd when one is
// running and checks `epmd -names` lists the name with the forwarded port.
func TestRegisterWithRealEpmd(t *testing.T) {
	names, err := exec.Command("epmd", "-names").Output()
	if err != nil {
		t.Skipf("SKIP no epmd answering here: %v", err)
	}
	_ = names

	// The name carries this process's pid, so two runs on one host, which
	// share the host's epmd, never collide on a registration.
	name := fmt.Sprintf("loom_vmm_epmd_test_%d", os.Getpid())
	reg, err := Register(DefaultAddress, name, 47999)
	if err != nil {
		t.Fatal(err)
	}
	defer reg.Close()

	out, err := exec.Command("epmd", "-names").Output()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), "name "+name+" at port 47999") {
		t.Fatalf("epmd -names:\n%s", out)
	}
}
