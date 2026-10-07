package framing

import (
	"github.com/vmihailenco/msgpack/v5"
	"testing"
)

func TestProtocolExitAddsOnlyCreditedDisposition(t *testing.T) {
	ordinary := ExecExit{Enforcement: []string{"pgroup"}}
	raw, err := MarshalBody(ordinary)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := msgpack.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	if len(fields) != 11 {
		t.Fatalf("ordinary terminal shape changed: %v", fields)
	}
	if _, exists := fields["protocol"]; exists {
		t.Fatal("ordinary exit gained credited field")
	}
	raw, err = MarshalBody(ProtocolExit{ExecExit: ordinary, Protocol: "complete"})
	if err != nil {
		t.Fatal(err)
	}
	fields = nil
	if err := msgpack.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	if len(fields) != 12 || fields["protocol"] != "complete" {
		t.Fatalf("credited exit lost native fields: %v", fields)
	}
}

func TestOrdinaryStartHasNoModeAndProtocolVersionsStaySeparate(t *testing.T) {
	raw, err := MarshalBody(ExecStart{Argv: []string{"true"}, Token: []byte{1}})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := msgpack.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	if len(fields) != 6 {
		t.Fatalf("ordinary start shape changed: %v", fields)
	}
	if _, exists := fields["mode"]; exists {
		t.Fatal("ordinary start gained protocol selector")
	}
	if EnvelopeVersion != 1 || ExecProtocolVersion != 4 {
		t.Fatal("protocol076 moved the wrong version")
	}
}
