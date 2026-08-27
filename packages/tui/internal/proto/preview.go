package proto

import (
	"strings"
	"unicode/utf8"
)

// SanitizePreview renders an escalation preview inert for a terminal.
//
// The preview is a rendering of a tool call's arguments, so every byte
// of it is model-controlled, and it is displayed inside the one prompt
// whose whole purpose is to be answered truthfully. An unfiltered
// preview is therefore not a display bug waiting to happen but a
// forgery primitive: a `bash` command line carrying ESC sequences can
// clear the screen, move the cursor over the client's own words, and
// repaint a different question above the y/n it is about to be
// answered with. Cursor-addressing, scroll regions, and OSC strings all
// reach out of the fence the overlay draws; the fence is only a fence
// if nothing inside it can move.
//
// So every C0 control (including ESC, CR, LF and TAB), DEL, and every
// C1 control is replaced by a visible escape, and never by nothing —
// a stripped byte is a byte the reader cannot know was there, and
// "npm install left-pad" and "npm install\x08\x08\x08\x08 evil" would
// otherwise print identically. Bidirectional formatting characters go
// the same way for the same reason: they reorder a line's display
// without changing it, which is the Trojan Source class of attack and
// exactly as good at forging a command as a cursor move. Invalid UTF-8
// becomes U+FFFD rather than reaching the terminal as raw bytes.
//
// Rendering rules for the preview are normative in protocol.md's
// "escalation" section, because they bind every client and not only
// this one.
func SanitizePreview(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	for _, r := range text {
		switch {
		case r == utf8.RuneError:
			// Either a genuine U+FFFD or a byte that was not valid
			// UTF-8; both are shown as the replacement character.
			b.WriteRune('�')
		case r < 0x20 || r == 0x7F:
			b.WriteString(hexEscape(byte(r)))
		case r >= 0x80 && r <= 0x9F:
			b.WriteString(unicodeEscape(r))
		case isBidiControl(r):
			b.WriteString(unicodeEscape(r))
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// isBidiControl reports whether r reorders display without changing
// content: the explicit embedding, override and isolate marks, plus the
// two direction marks.
func isBidiControl(r rune) bool {
	switch {
	case r == 0x200E || r == 0x200F:
		return true
	case r >= 0x202A && r <= 0x202E:
		return true
	case r >= 0x2066 && r <= 0x2069:
		return true
	default:
		return false
	}
}

const hexDigits = "0123456789abcdef"

func hexEscape(b byte) string {
	return string([]byte{'\\', 'x', hexDigits[b>>4], hexDigits[b&0x0F]})
}

func unicodeEscape(r rune) string {
	out := []byte{'\\', 'u'}
	for shift := 12; shift >= 0; shift -= 4 {
		out = append(out, hexDigits[(r>>uint(shift))&0x0F])
	}
	return string(out)
}
