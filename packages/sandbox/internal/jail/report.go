package jail

import (
	"bytes"
	"fmt"
	"io"

	"github.com/vmihailenco/msgpack/v5"
)

// Report is the enforcement summary stage 2 sends back to the
// supervising helper over the report pipe (fd 4) just before exec'ing
// the target. It exists so the exec_exit frame can state exactly which
// layers were applied around this execution — the broker's basis for
// accepting or refusing the result. Applied entries are terse layer
// tags ("landlock:abi=5", "seccomp-net", "rlimit-cpu"); Skipped entries
// carry the reason ("landlock: unavailable: ...").
type Report struct {
	Applied []string `msgpack:"applied"`
	Skipped []string `msgpack:"skipped"`
}

// WriteReport serializes the report to w.
func WriteReport(w io.Writer, r Report) error {
	b, err := msgpack.Marshal(&r)
	if err != nil {
		return fmt.Errorf("jail: encode report: %w", err)
	}
	if _, err := w.Write(b); err != nil {
		return fmt.Errorf("jail: write report: %w", err)
	}
	return nil
}

// ReadReport reads a report until EOF. An empty read yields an empty
// report (stage 2 died before reporting); malformed bytes are an error,
// never a panic.
func ReadReport(r io.Reader) (Report, error) {
	raw, err := io.ReadAll(io.LimitReader(r, 1<<16))
	if err != nil {
		return Report{}, fmt.Errorf("jail: read report: %w", err)
	}
	if len(raw) == 0 {
		return Report{}, nil
	}
	var rep Report
	dec := msgpack.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields(true)
	if err := dec.Decode(&rep); err != nil {
		return Report{}, fmt.Errorf("jail: decode report: %w", err)
	}
	return rep, nil
}
