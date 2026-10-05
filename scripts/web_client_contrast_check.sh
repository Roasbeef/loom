#!/usr/bin/env bash
# web_client_contrast_check.sh — hold the page's text colours to a 4.5:1
# contrast ratio on the surfaces they are drawn on, in both themes.
#
#   scripts/web_client_contrast_check.sh [css]   fail on a violation (default
#                                                packages/web_client/src/
#                                                web_client.css)
#   scripts/web_client_contrast_check.sh --self-test
#                                                prove the gate catches each one
#
# `make lint` runs both, together with the JavaScript check, whenever the
# browser package's sources are in the run.
#
# ## What it holds
#
# docs/design-notes/web-design.md, section 5, keeps the redesign's colours
# for marks (a dot, a ring, a bar, a border) and requires a darker value
# wherever a hue is text on the light theme, because several of the design's
# light hues are under 4.5:1 on the light surfaces. The stylesheet spells that
# as two tokens per hue: `--color-X`, for marks, and `--color-X-text`, for
# words. Three rules make it a gate and not a note:
#
#   1. Every text token, in each theme, has a contrast ratio of at least 4.5
#      against every surface it can be drawn on (`bg`, `bg-raised`,
#      `bg-sunk`, `bg-user` and `code`), and `added-text` and `danger-text`
#      also against `added-bg` and `removed-bg`, which the diff draws them on.
#      `fg` and `fg-quiet` are text tokens too.
#   2. No rule sets `color:` from a mark token. A rule that writes
#      `color:var(--color-signal)` is text in a colour that was not held to
#      the ratio, so it must name `--color-signal-text`.
#   3. `--color-fg-faint` is never text.
#   4. A strand's avatar letter (`--hue-text`) on its disc, a tint of the
#      hue's mark colour over the surface (`avatar_tint` percent, the
#      stylesheet's `.avatar` rule), has a ratio of at least 4.5 for every hue
#      and every surface the card is drawn on, in each theme. The disc is not a
#      token, so the script blends it the way `color-mix(in srgb, ...)` does.
#   5. The theme toggle's two light palettes agree (colour tokens: the
#      `--shadow-float` value is not compared, only that it inherits), and every token reaches
#      each shadow root. The stylesheet writes the light palette twice, once
#      for a system that prefers light and once for `data-theme="light"`,
#      because CSS cannot share the two; they must declare the same tokens with
#      the same values. And a `:host` rule sets each token to `inherit`, so a
#      shadow root takes the value from the document's root and not the dark
#      palette Tailwind writes on `:host`; a token with no line there stays dark
#      inside every element when the reader picks light (docs/design-notes/
#      web-design.md, section 6.5).
#
# The ratio is WCAG's: the relative luminance of each colour, computed in
# awk from the tokens' hex values, and (lighter + 0.05) / (darker + 0.05).
# The check needs nothing but awk and grep, so it runs wherever `make lint`
# does, in the shape scripts/web_client_js_check.sh uses.
set -euo pipefail
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
root=$(cd "$(dirname "$0")/.." && pwd)

default_css="$root/packages/web_client/src/web_client.css"

# The tokens held to the ratio, and the surfaces they are drawn on.
text_tokens="fg fg-quiet current signal-text advisor-text peer-text danger-text added-text strand-2-text strand-3-text strand-4-text strand-5-text strand-6-text"
surfaces="bg bg-raised bg-sunk bg-user code"

# The pairs the diff draws on a coloured surface, as `token:surface`.
extra_pairs="added-text:added-bg danger-text:removed-bg fg:added-bg fg:removed-bg fg-quiet:bg-sunk on-danger:danger bg:fg"

# The avatar's discs: each hue's mark token and the text token the letter is
# drawn in, as `mark:text`, tinted at `avatar_tint` percent over a surface.
# The percentage is the stylesheet's `.avatar` rule's, which `check` holds
# the stylesheet to. It is 8 and not the 14 the critique drew: at 14 the
# light theme's strand text tokens, which clear 4.5 on the page by a hair,
# fall to 4.2 on their own disc. The hue-less `fg-quiet` is left out: a
# card's hue comes from its position and is never `hue-none`.
avatar_hues="current:current advisor:advisor-text strand-2:strand-2-text strand-3:strand-3-text strand-4:strand-4-text strand-5:strand-5-text strand-6:strand-6-text"
avatar_tint=8
# The card is drawn on `bg-raised` and a strand's own view on the panel, `bg`.
avatar_surfaces="bg bg-raised"

# The mark tokens a `color:` may not read.
marks='signal|advisor|peer|danger|added|strand-[2-6]|fg-faint'

# ratios <css>: print `theme token surface ratio` for every pair, one per
# line, from the tokens the stylesheet declares. The dark theme is the
# `@theme` block; the light theme is the block under the light media query,
# which the file spells after it.
ratios() {
	awk -v text="$text_tokens" -v surfaces="$surfaces" -v extra="$extra_pairs" \
		-v hues="$avatar_hues" -v tint="$avatar_tint" \
		-v asurf="$avatar_surfaces" '
		function hex(ch) { return index("0123456789abcdef", tolower(ch)) - 1 }
		function channel(value, at,   n, c) {
			n = hex(substr(value, at, 1)) * 16 + hex(substr(value, at + 1, 1))
			c = n / 255
			return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4
		}
		function luminance(value) {
			return 0.2126 * channel(value, 2) + 0.7152 * channel(value, 4) + 0.0722 * channel(value, 6)
		}
		# blend: `tint` percent of the mark colour over the surface, per sRGB
		# channel, as hex. This is what `color-mix(in srgb, mark N%,
		# transparent)` composites to on an opaque surface.
		function blend(mark, surface,   at, out, m, s) {
			out = "#"
			for (at = 2; at <= 6; at += 2) {
				m = hex(substr(mark, at, 1)) * 16 + hex(substr(mark, at + 1, 1))
				s = hex(substr(surface, at, 1)) * 16 + hex(substr(surface, at + 1, 1))
				out = out sprintf("%02x", int((m * tint + s * (100 - tint)) / 100 + 0.5))
			}
			return out
		}
		function ratio(a, b,   x, y, t) {
			x = luminance(a); y = luminance(b)
			if (x < y) { t = x; x = y; y = t }
			return (x + 0.05) / (y + 0.05)
		}
		function report(theme, token, surface) {
			if (!((theme, token) in value) || !((theme, surface) in value)) {
				printf "%s %s %s missing\n", theme, token, surface
				return
			}
			printf "%s %s %s %.2f\n", theme, token, surface, \
				ratio(value[theme, token], value[theme, surface])
		}
		# The switch is one-way: every token after the light block is read as
		# a light value, so the stylesheet must keep that block last.
		/prefers-color-scheme: light/ { theme = "light"; next }
		/^[ \t]*:root\[data-theme="light"\][ \t]*\{[ \t]*$/ { theme = "manual"; next }
		/^[ \t]*:host[ \t]*\{[ \t]*$/ { theme = "host"; next }
		BEGIN { theme = "dark" }
		/^[ \t]*--color-[a-z0-9-]+: #[0-9a-fA-F]{6};/ {
			name = $1; sub(/^--color-/, "", name); sub(/:$/, "", name)
			hexvalue = $2; sub(/;$/, "", hexvalue)
			value[theme, name] = hexvalue
		}
		END {
			nt = split(text, tokens, " "); ns = split(surfaces, surf, " ")
			ne = split(extra, pairs, " ")
			for (mode = 1; mode <= 2; mode++) {
				th = mode == 1 ? "dark" : "light"
				for (i = 1; i <= nt; i++)
					for (j = 1; j <= ns; j++)
						report(th, tokens[i], surf[j])
				for (k = 1; k <= ne; k++) {
					split(pairs[k], pair, ":")
					report(th, pair[1], pair[2])
				}
				nh = split(hues, hue, " ")
				na = split(asurf, avs, " ")
				for (i = 1; i <= nh; i++) {
					split(hue[i], pair, ":")
					for (j = 1; j <= na; j++) {
						label = "avatar-" pair[2]
						if (!((th, pair[1]) in value) || !((th, pair[2]) in value) || !((th, avs[j]) in value)) {
							printf "%s %s %s missing\n", th, label, avs[j]
							continue
						}
						printf "%s %s %s %.2f\n", th, label, avs[j], \
							ratio(value[th, pair[2]], blend(value[th, pair[1]], value[th, avs[j]]))
					}
				}
			}
		}
	' "$1"
}

# agreement <css>: print `token problem` for each token the toggle's two light
# palettes disagree on, and for each token with no `inherit` line in the
# `:host` rule. The dark palette is the `@theme` block, before the light media
# query; the palette for a forced light is the block headed
# `:root[data-theme="light"]`, and the `:host` rule is headed `:host {`.
agreement() {
	awk '
		BEGIN { theme = "dark" }
		/prefers-color-scheme: light/ { theme = "light"; next }
		/^[ \t]*:root\[data-theme="light"\][ \t]*\{[ \t]*$/ { theme = "manual"; next }
		/^[ \t]*:host[ \t]*\{[ \t]*$/ { theme = "host"; next }
		/^[ \t]*--color-[a-z0-9-]+: #[0-9a-fA-F]{6};/ {
			name = $1; sub(/:$/, "", name)
			hexvalue = $2; sub(/;$/, "", hexvalue)
			value[theme, name] = tolower(hexvalue)
			seen[name] = 1
		}
		/^[ \t]*--(color|shadow)-[a-z0-9-]+: inherit;/ {
			name = $1; sub(/:$/, "", name)
			inherits[name] = 1
			seen[name] = 1
		}
		END {
			seen["--shadow-float"] = 1
			for (name in seen) {
				if (!(("light", name) in value) && !(("manual", name) in value) \
					&& !(("dark", name) in value)) {
					if (!(name in inherits)) print name, "is not declared"
					continue
				}
				if ((("light", name) in value) != (("manual", name) in value))
					print name, "is in one light palette and not the other"
				else if (("light", name) in value \
					&& value["light", name] != value["manual", name])
					print name, "differs between the two light palettes"
				if (!(name in inherits))
					print name, "has no inherit line in the :host rule"
			}
		}
	' "$1" | LC_ALL=C sort
}

# check <css>: print each violation, and return non-zero if there was one.
check() {
	local css="$1"
	local failed=0
	local line

	if [ ! -f "$css" ]; then
		echo "web_client_contrast_check: $css is not a file" >&2
		return 2
	fi

	while IFS= read -r line; do
		# shellcheck disable=SC2086
		set -- $line
		if [ "$4" = "missing" ]; then
			echo "web_client_contrast_check: $1 theme has no $2 or $3 token" >&2
			failed=1
		elif awk -v r="$4" 'BEGIN { exit !(r < 4.5) }'; then
			echo "web_client_contrast_check: $1 theme: $2 on $3 is $4:1, under 4.5:1" >&2
			failed=1
		fi
	done < <(ratios "$css")

	while IFS= read -r line; do
		echo "web_client_contrast_check: $line" >&2
		failed=1
	done < <(agreement "$css")

	if grep -nE "(^|[;{ ])color:var\\(--color-($marks)\\)" "$css" >&2; then
		echo "web_client_contrast_check: a rule sets text from a mark token; use its -text token" >&2
		failed=1
	fi
	if ! grep -qE "\.avatar\{[^}]*color-mix\(in srgb,var\(--hue\) ${avatar_tint}%,transparent\)" "$css"; then
		echo "web_client_contrast_check: the .avatar rule does not tint --hue at ${avatar_tint}%, the figure this check blends" >&2
		failed=1
	fi
	if grep -nE '(^|[;{ ])color:var\(--hue,' "$css" >&2; then
		echo "web_client_contrast_check: a rule sets text from --hue; use --hue-text" >&2
		failed=1
	fi

	return $failed
}

# ------------------------------------------------------------- the self-test
#
# The real stylesheet passes; each violation, planted alone in a copy, fails.

self_test() {
	local tmp
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN

	if ! check "$default_css" >/dev/null 2>&1; then
		echo "web_client_contrast_check: self-test: the stylesheet does not pass" >&2
		return 1
	fi

	# A text token whose light value is the design's mark value.
	sed 's/--color-signal-text: #975a1e;/--color-signal-text: #d9822b;/' \
		"$default_css" >"$tmp/light-mark-as-text.css"

	# A dark text token below the ratio.
	awk '/--color-fg-quiet: #9a978f;/ { sub(/#9a978f/, "#3a3a3a") } { print }' \
		"$default_css" >"$tmp/dark-quiet.css"

	# A mark token dark enough that its tint drags the avatar's letter under the
	# ratio on the disc, while the letter's own token still passes alone.
	sed 's/--color-strand-5: #b0429f;/--color-strand-5: #000000;/' \
		"$default_css" >"$tmp/pale-avatar.css"

	# The avatar's tint drifting from the percentage this check blends.
	sed 's/var(--hue) 8%,transparent/var(--hue) 14%,transparent/' \
		"$default_css" >"$tmp/avatar-drift.css"

	# A text token that is missing.
	grep -v -- '--color-peer-text:' "$default_css" >"$tmp/missing.css"

	# A rule that reads a mark token as text, and one that reads --hue.
	{ cat "$default_css"; printf '.x{color:var(--color-danger);}\n'; } >"$tmp/raw-mark.css"
	{ cat "$default_css"; printf '.x{color:var(--hue,red);}\n'; } >"$tmp/raw-hue.css"
	{ cat "$default_css"; printf '.x{color:var(--color-fg-faint);}\n'; } >"$tmp/faint.css"

	# The forced-light palette drifting from the media query's, in one token.
	awk '/--color-bg: #f6f5f2;/ { n++; if (n == 2) sub(/#f6f5f2/, "#f6f5f3") } { print }' \
		"$default_css" >"$tmp/light-drift.css"

	# A token with no inherit line in the :host rule.
	grep -v -- '--color-peer: inherit;' "$default_css" >"$tmp/no-inherit.css"

	# A token in the media query's light palette and not in the forced one.
	awk '/--color-code: #f1efe9;/ { n++; if (n == 2) next } { print }' \
		"$default_css" >"$tmp/light-lacks.css"

	local name
	for name in light-mark-as-text dark-quiet pale-avatar avatar-drift missing raw-mark raw-hue faint \
		light-drift no-inherit light-lacks; do
		if check "$tmp/$name.css" >/dev/null 2>&1; then
			echo "web_client_contrast_check: self-test: $name passed the check" >&2
			return 1
		fi
	done

	# A border in a mark token is not text and is allowed.
	{ cat "$default_css"; printf '.x{border-color:var(--color-danger);}\n'; } >"$tmp/border.css"
	if ! check "$tmp/border.css" >/dev/null 2>&1; then
		echo "web_client_contrast_check: self-test: a border in a mark token failed" >&2
		return 1
	fi

	return 0
}

case "${1:-}" in
--self-test)
	self_test
	echo "web_client_contrast_check: self-test ok"
	;;
"")
	check "$default_css"
	echo "web_client_contrast_check: ok"
	;;
*)
	check "$1"
	echo "web_client_contrast_check: ok"
	;;
esac
