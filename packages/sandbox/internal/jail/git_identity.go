package jail

// Git identity publication is a fixed data operation, not a command runner.
// It deliberately does not construct a mount namespace: mounting a missing
// SQLite side-file mask beneath a writable bind creates its mountpoint on the
// host. Instead, the platform implementation walks from an original policy
// root with directory descriptors and never follows a tool-home symlink.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

const gitIdentityInputLimit = 64 << 10

// RunGitIdentityPublication decodes the private helper CLI. Errors never
// include the supplied policy, JSON, or identity values.
func RunGitIdentityPublication(args []string) error {
	if len(args) != 3 || len(args[0]) > base64.StdEncoding.EncodedLen(1<<20) ||
		len(args[2]) > gitIdentityInputLimit || !utf8.ValidString(args[2]) {
		return errors.New("invalid Git identity publication arguments")
	}
	encoded, err := base64.StdEncoding.Strict().DecodeString(args[0])
	if err != nil {
		return errors.New("invalid Git identity publication policy")
	}
	pol, err := policy.Decode(encoded)
	if err != nil {
		return errors.New("invalid Git identity publication policy")
	}

	// Slices preserve arity for validation. Decoding into [2]string would
	// silently discard a third JSON element, and null is not an entry list.
	var decoded []any
	if err := json.Unmarshal([]byte(args[2]), &decoded); err != nil || decoded == nil {
		return errors.New("invalid Git identity publication entries")
	}
	entries := make([][2]string, 0, len(decoded))
	for _, entry := range decoded {
		pair, ok := entry.([]any)
		if !ok || len(pair) != 2 {
			return errors.New("invalid Git identity publication entries")
		}
		key, keyOK := pair[0].(string)
		value, valueOK := pair[1].(string)
		if !keyOK || !valueOK {
			return errors.New("invalid Git identity publication entries")
		}
		entries = append(entries, [2]string{key, value})
	}
	return PublishGitIdentity(pol, args[1], entries)
}

// PublishGitIdentity atomically replaces WORKSPACE/.codemode/home/gitconfig.
// Only user.name and user.email are accepted; the last occurrence wins.
// The platform implementation requires existing parents and refuses aliases
// below the original granted root rather than promoting a child into a grant.
func PublishGitIdentity(pol policy.Policy, workspace string, entries [][2]string) error {
	content, err := renderGitIdentity(entries)
	if err != nil {
		return err
	}
	if pol.Limits.FsizeBytes != 0 && uint64(len(content)) > pol.Limits.FsizeBytes {
		return errors.New("Git identity publication exceeds the file size limit")
	}
	if !filepath.IsAbs(workspace) || hasParentComponent(workspace) {
		return errors.New("invalid Git identity publication workspace")
	}
	return publishGitIdentity(pol, filepath.Clean(workspace), content)
}

// Git's quoted-value grammar supports these five escapes. NUL has no Git
// identity representation; other UTF-8 bytes remain literal inside quotes.
func renderGitIdentity(entries [][2]string) ([]byte, error) {
	values := make(map[string]string, 2)
	size := 0
	for _, entry := range entries {
		size += len(entry[0]) + len(entry[1])
		if size > gitIdentityInputLimit || !utf8.ValidString(entry[1]) ||
			strings.ContainsRune(entry[1], 0) ||
			(entry[0] != "user.name" && entry[0] != "user.email") {
			return nil, errors.New("invalid Git identity publication entries")
		}
		values[entry[0]] = entry[1]
	}
	escapes := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n", "\t", "\\t", "\b", "\\b")
	var out strings.Builder
	out.WriteString("[user]\n\tuseConfigOnly = true\n")
	for _, key := range []string{"user.name", "user.email"} {
		if value, ok := values[key]; ok {
			out.WriteString("\t" + strings.TrimPrefix(key, "user.") + " = \"")
			out.WriteString(escapes.Replace(value))
			out.WriteString("\"\n")
		}
	}
	if out.Len() > gitIdentityInputLimit {
		return nil, errors.New("Git identity publication exceeds the data limit")
	}
	return []byte(out.String()), nil
}

func hasParentComponent(path string) bool {
	for _, part := range strings.Split(path, string(filepath.Separator)) {
		if part == ".." {
			return true
		}
	}
	return false
}
