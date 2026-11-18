#!/usr/bin/env bash
# web_client_contrast_check.sh — hold the page's colours to measured
# contrast, lightness and colour-vision targets on the surfaces they are drawn
# on, in both themes.
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
# Five more hold the palette's design, which the stylesheet writes in OKLCH
# (`web_client.css`, the colour tokens):
#
#   6. Every token is inside sRGB. A value outside it is clipped by the
#      browser, so the colour drawn is not the colour measured here.
#   7. Every text token has an APCA lightness contrast of at least
#      `apca_text` (`apca_fg` for `fg`) on every surface it is drawn on.
#      WCAG's ratio overstates contrast on a dark surface: the old dark
#      palette passed 4.5:1 with quiet text at Lc 44, which APCA puts below
#      what body text needs.
#   8. The surfaces step in OKLCH lightness: `bg` from `bg-sunk` and from
#      `bg-raised`, and `bg-raised` from `code`, by at least `step_dark` in
#      the dark theme and `step_light` in the light one, and `divider` from
#      `bg` and `bg-raised` by `divider_step`. Without a step a raised card
#      reads only by its border.
#   9. The status marks stay apart for a reader with deuteranopia or
#      protanopia. Each pair in `cvd_pairs` is at least `cvd_min` apart in
#      OKLab under normal vision and under each of Machado, Oliveira and
#      Fernandes's (2009) full-severity simulations, and the diff's two
#      backgrounds at least `cvd_bg_min`. Hue alone separates red from green
#      only for a reader who sees both.
#  10. Every mark token has a WCAG ratio of at least `mark_min` against `bg`
#      and `bg-raised`, the 3:1 WCAG asks of a graphical object.
#
# The ratio is WCAG's: the relative luminance of each colour, and (lighter +
# 0.05) / (darker + 0.05). APCA is the W3 0.0.98G formula. A token may be
# written as `#rrggbb` or `oklch(L C H)` with L from 0 to 1; the awk library
# below converts either to sRGB once, so every rule reads the same value.
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

# The design's targets (rules 7 to 10). The APCA figures are Lc, the steps
# OKLCH lightness from 0 to 1, the separations OKLab distance.
apca_text=60
apca_fg=90
step_dark=0.03
step_light=0.02
divider_step=0.06
cvd_min=0.10
cvd_bg_min=0.03
mark_min=3

# The surfaces that step (rule 8), as `upper:lower` pairs read in either order.
steps="bg:bg-sunk bg:bg-raised bg-raised:code"

# The status marks kept apart (rule 9): what was added and what was removed,
# the strand in focus and a peer, and the attention colour against both
# outcomes.
cvd_pairs="added:danger current:peer signal:danger signal:added"

# The marks held to `mark_min` (rule 10).
mark_tokens="current signal advisor peer danger added strand-2 strand-3 strand-4 strand-5 strand-6"

# The awk library every pass shares. `rgb(v)` reads a token value, `#rrggbb`
# or `oklch(L C H)`, into the encoded sRGB channels `R`, `G` and `B` (0 to 1)
# and sets `IN_GAMUT`; everything else is computed from those, so a token is
# converted exactly once per question and the rules cannot disagree about its
# colour. OKLCH to sRGB and back is Björn Ottosson's OKLab matrix pair.
# shellcheck disable=SC2016
colour_lib='
	function hexd(ch) { return index("0123456789abcdef", tolower(ch)) - 1 }
	function cbrt(x) { return x == 0 ? 0 : (x > 0 ? exp(log(x) / 3) : -exp(log(-x) / 3)) }
	function encode(c) { return c <= 0.0031308 ? 12.92 * c : 1.055 * c ^ (1 / 2.4) - 0.055 }
	function decode(c) { return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
	function clip(c) { return c < 0 ? 0 : (c > 1 ? 1 : c) }
	function rgb(v,   parts, l, c, h, a, b, l_, m_, s_, lr, lg, lb) {
		IN_GAMUT = 1
		if (substr(v, 1, 1) == "#") {
			R = (hexd(substr(v, 2, 1)) * 16 + hexd(substr(v, 3, 1))) / 255
			G = (hexd(substr(v, 4, 1)) * 16 + hexd(substr(v, 5, 1))) / 255
			B = (hexd(substr(v, 6, 1)) * 16 + hexd(substr(v, 7, 1))) / 255
			return
		}
		sub(/^oklch\(/, "", v); sub(/\)$/, "", v)
		split(v, parts, " ")
		l = parts[1] + 0; c = parts[2] + 0; h = parts[3] * 3.141592653589793 / 180
		a = c * cos(h); b = c * sin(h)
		l_ = l + 0.3963377774 * a + 0.2158037573 * b
		m_ = l - 0.1055613458 * a - 0.0638541728 * b
		s_ = l - 0.0894841775 * a - 1.2914855480 * b
		l_ = l_ ^ 3; m_ = m_ ^ 3; s_ = s_ ^ 3
		lr = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
		lg = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
		lb = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
		if (lr < -0.0005 || lr > 1.0005 || lg < -0.0005 || lg > 1.0005 || lb < -0.0005 || lb > 1.0005)
			IN_GAMUT = 0
		R = encode(clip(lr)); G = encode(clip(lg)); B = encode(clip(lb))
	}
	function hexof(v) {
		rgb(v)
		return sprintf("#%02x%02x%02x", int(R * 255 + 0.5), int(G * 255 + 0.5), int(B * 255 + 0.5))
	}
	function luminance(v) {
		rgb(v)
		return 0.2126 * decode(R) + 0.7152 * decode(G) + 0.0722 * decode(B)
	}
	function ratio(a, b,   x, y, t) {
		x = luminance(a); y = luminance(b)
		if (x < y) { t = x; x = y; y = t }
		return (x + 0.05) / (y + 0.05)
	}
	# apca: the W3 0.0.98G lightness contrast of text `t` on background `g`, as
	# an absolute Lc.
	function apy(v,   y) {
		rgb(v)
		y = 0.2126729 * R ^ 2.4 + 0.7151522 * G ^ 2.4 + 0.0721750 * B ^ 2.4
		return y > 0.022 ? y : y + (0.022 - y) ^ 1.414
	}
	function apca(t, g,   yt, yb, s) {
		yt = apy(t); yb = apy(g)
		if (yb > yt) {
			s = (yb ^ 0.56 - yt ^ 0.57) * 1.14
			return s < 0.1 ? 0 : (s - 0.027) * 100
		}
		s = (yb ^ 0.65 - yt ^ 0.62) * 1.14
		return s > -0.1 ? 0 : -(s + 0.027) * 100
	}
	# oklab: the OKLab coordinates of linear sRGB channels into `OL`, `OA`,
	# `OB`.
	function oklab(lr, lg, lb,   l, m, s) {
		l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
		m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
		s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
		OL = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
		OA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
		OB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	}
	function lightness(v) { rgb(v); oklab(decode(R), decode(G), decode(B)); return OL }
	# seen: OKLab of `v` as a reader with `vision` sees it: normal, or a
	# full-severity Machado 2009 deuteranopia or protanopia, applied to the
	# linear channels.
	function seen(v, vision,   r, g, b, x, y, z) {
		rgb(v); r = decode(R); g = decode(G); b = decode(B)
		if (vision == "deutan") {
			x = 0.367322 * r + 0.860646 * g - 0.227968 * b
			y = 0.280085 * r + 0.672501 * g + 0.047413 * b
			z = -0.011820 * r + 0.042940 * g + 0.968881 * b
			r = clip(x); g = clip(y); b = clip(z)
		} else if (vision == "protan") {
			x = 0.152286 * r + 1.052583 * g - 0.204868 * b
			y = 0.114503 * r + 0.786281 * g + 0.099216 * b
			z = -0.003882 * r - 0.048116 * g + 1.051998 * b
			r = clip(x); g = clip(y); b = clip(z)
		}
		oklab(r, g, b)
	}
	function apart(u, v, vision,   l, a, b) {
		seen(u, vision); l = OL; a = OA; b = OB
		seen(v, vision)
		return sqrt((l - OL) ^ 2 + (a - OA) ^ 2 + (b - OB) ^ 2)
	}
	# token: the value of a `--color-X: <value>;` line, as written.
	function tokenvalue(line,   v) {
		v = line
		sub(/^[ \t]*--color-[a-z0-9-]+:[ \t]*/, "", v)
		sub(/[ \t]*;.*$/, "", v)
		return v
	}
	function tokenname(line,   n) {
		n = line
		sub(/^[ \t]*--color-/, "", n); sub(/:.*$/, "", n)
		return n
	}
'

# A token line, in either notation.
token_line='^[ \t]*--color-[a-z0-9-]+: (#[0-9a-fA-F]{6}|oklch[(][0-9. ]+[)]);'

# ratios <css>: print `theme token surface ratio` for every pair, one per
# line, from the tokens the stylesheet declares. The dark theme is the
# `@theme` block; the light theme is the block under the light media query,
# which the file spells after it.
ratios() {
	awk -v text="$text_tokens" -v surfaces="$surfaces" -v extra="$extra_pairs" \
		-v hues="$avatar_hues" -v tint="$avatar_tint" \
		-v asurf="$avatar_surfaces" -v tokenre="$token_line" "$colour_lib"'
		# blend: `tint` percent of the mark colour over the surface, per sRGB
		# channel, as hex. This is what `color-mix(in srgb, mark N%,
		# transparent)` composites to on an opaque surface.
		function blend(mark, surface,   at, out, m, s) {
			mark = hexof(mark); surface = hexof(surface)
			out = "#"
			for (at = 2; at <= 6; at += 2) {
				m = hexd(substr(mark, at, 1)) * 16 + hexd(substr(mark, at + 1, 1))
				s = hexd(substr(surface, at, 1)) * 16 + hexd(substr(surface, at + 1, 1))
				out = out sprintf("%02x", int((m * tint + s * (100 - tint)) / 100 + 0.5))
			}
			return out
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
		$0 ~ tokenre { value[theme, tokenname($0)] = tokenvalue($0) }
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
	awk -v tokenre="$token_line" "$colour_lib"'
		BEGIN { theme = "dark" }
		/prefers-color-scheme: light/ { theme = "light"; next }
		/^[ \t]*:root\[data-theme="light"\][ \t]*\{[ \t]*$/ { theme = "manual"; next }
		/^[ \t]*:host[ \t]*\{[ \t]*$/ { theme = "host"; next }
		$0 ~ tokenre {
			name = "--color-" tokenname($0)
			value[theme, name] = tolower(tokenvalue($0))
			declared[name] = 1
		}
		/^[ \t]*--(color|shadow)-[a-z0-9-]+: inherit;/ {
			name = $1; sub(/:$/, "", name)
			inherits[name] = 1
			declared[name] = 1
		}
		END {
			declared["--shadow-float"] = 1
			for (name in declared) {
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

# measures <css>: print each breach of rules 6 to 10, one per line, already
# worded. The thresholds come from the variables above.
measures() {
	awk -v text="$text_tokens" -v surfaces="$surfaces" -v tokenre="$token_line" \
		-v apca_text="$apca_text" -v apca_fg="$apca_fg" -v steps="$steps" \
		-v step_dark="$step_dark" -v step_light="$step_light" \
		-v divider_step="$divider_step" -v pairs="$cvd_pairs" -v cvd_min="$cvd_min" \
		-v cvd_bg_min="$cvd_bg_min" -v marks="$mark_tokens" -v mark_min="$mark_min" \
		"$colour_lib"'
		BEGIN { theme = "dark" }
		/prefers-color-scheme: light/ { theme = "light"; next }
		/^[ \t]*:root\[data-theme="light"\][ \t]*\{[ \t]*$/ { theme = "manual"; next }
		/^[ \t]*:host[ \t]*\{[ \t]*$/ { theme = "host"; next }
		$0 ~ tokenre { value[theme, tokenname($0)] = tokenvalue($0) }
		function has(th, t) { return (th, t) in value }
		END {
			nt = split(text, tokens, " "); ns = split(surfaces, surf, " ")
			np = split(pairs, pair, " "); nm = split(marks, mark, " ")
			nst = split(steps, step, " ")
			for (key in value) {
				split(key, kt, SUBSEP)
				if (kt[1] != "dark" && kt[1] != "light") continue
				rgb(value[key])
				if (!IN_GAMUT) printf "%s theme: %s is outside sRGB (%s)\n", kt[1], kt[2], value[key]
			}
			for (mode = 1; mode <= 2; mode++) {
				th = mode == 1 ? "dark" : "light"
				least = mode == 1 ? step_dark : step_light
				for (i = 1; i <= nt; i++) {
					need = tokens[i] == "fg" ? apca_fg : apca_text
					for (j = 1; j <= ns; j++) {
						if (!has(th, tokens[i]) || !has(th, surf[j])) continue
						lc = apca(value[th, tokens[i]], value[th, surf[j]])
						if (lc < need)
							printf "%s theme: %s on %s is APCA Lc %.1f, under %s\n", th, tokens[i], surf[j], lc, need
					}
				}
				for (i = 1; i <= nst; i++) {
					split(step[i], two, ":")
					if (!has(th, two[1]) || !has(th, two[2])) continue
					d = lightness(value[th, two[1]]) - lightness(value[th, two[2]])
					if (d < 0) d = -d
					if (d < least)
						printf "%s theme: %s and %s are %.3f apart in lightness, under %s\n", th, two[1], two[2], d, least
				}
				split("bg bg-raised", lined, " ")
				for (i = 1; i <= 2; i++) {
					if (!has(th, "divider") || !has(th, lined[i])) continue
					d = lightness(value[th, "divider"]) - lightness(value[th, lined[i]])
					if (d < 0) d = -d
					if (d < divider_step)
						printf "%s theme: divider and %s are %.3f apart in lightness, under %s\n", th, lined[i], d, divider_step
				}
				split("normal deutan protan", vision, " ")
				for (i = 1; i <= np; i++) {
					split(pair[i], two, ":")
					if (!has(th, two[1]) || !has(th, two[2])) continue
					for (v = 1; v <= 3; v++) {
						d = apart(value[th, two[1]], value[th, two[2]], vision[v])
						if (d < cvd_min)
							printf "%s theme: %s and %s are %.3f apart for %s vision, under %s\n", th, two[1], two[2], d, vision[v], cvd_min
					}
				}
				if (has(th, "added-bg") && has(th, "removed-bg"))
					for (v = 1; v <= 3; v++) {
						d = apart(value[th, "added-bg"], value[th, "removed-bg"], vision[v])
						if (d < cvd_bg_min)
							printf "%s theme: added-bg and removed-bg are %.3f apart for %s vision, under %s\n", th, d, vision[v], cvd_bg_min
					}
				for (i = 1; i <= nm; i++)
					for (j = 1; j <= 2; j++) {
						g = j == 1 ? "bg" : "bg-raised"
						if (!has(th, mark[i]) || !has(th, g)) continue
						r = ratio(value[th, mark[i]], value[th, g])
						if (r < mark_min)
							printf "%s theme: mark %s on %s is %.2f:1, under %s:1\n", th, mark[i], g, r, mark_min
					}
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

	while IFS= read -r line; do
		echo "web_client_contrast_check: $line" >&2
		failed=1
	done < <(measures "$css")

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
	sed 's/--color-signal-text: oklch(0.510 0.115 58);/--color-signal-text: oklch(0.660 0.145 64);/' \
		"$default_css" >"$tmp/light-mark-as-text.css"

	# A dark text token below the ratio.
	awk '/--color-fg-quiet: oklch\(0.785 0.010 262\);/ { sub(/oklch\(0.785 0.010 262\)/, "#3a3a3a") } { print }' \
		"$default_css" >"$tmp/dark-quiet.css"

	# A mark token dark enough that its tint drags the avatar's letter under the
	# ratio on the disc, while the letter's own token still passes alone. The
	# palette's letters clear the ratio by more than an 8% tint can take, so
	# the letter is planted near the floor first: `avatar-floor` holds that
	# letter alone and must pass, and `pale-avatar` adds the black mark.
	sed 's/--color-strand-5-text: oklch(0.505 0.160 340);/--color-strand-5-text: #a73e97;/' \
		"$default_css" >"$tmp/avatar-floor.css"
	sed 's/--color-strand-5: oklch(0.580 0.170 340);/--color-strand-5: #000000;/' \
		"$tmp/avatar-floor.css" >"$tmp/pale-avatar.css"

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
	awk '/--color-bg: oklch\(0.975 0.004 85\);/ { n++; if (n == 2) sub(/0.975 0.004 85/, "0.976 0.004 85") } { print }' \
		"$default_css" >"$tmp/light-drift.css"

	# A token with no inherit line in the :host rule.
	grep -v -- '--color-peer: inherit;' "$default_css" >"$tmp/no-inherit.css"

	# A token in the media query's light palette and not in the forced one.
	awk '/--color-code: oklch\(0.952 0.006 85\);/ { n++; if (n == 2) next } { print }' \
		"$default_css" >"$tmp/light-lacks.css"

	# Rule 6: a dark token outside sRGB.
	sed 's/--color-strand-3: oklch(0.820 0.140 118);/--color-strand-3: oklch(0.820 0.400 118);/' \
		"$default_css" >"$tmp/gamut.css"

	# Rule 7: dark quiet text that clears WCAG's 4.5:1 and not APCA's Lc 60,
	# the old palette's own failure.
	sed 's/--color-fg-quiet: oklch(0.785 0.010 262);/--color-fg-quiet: oklch(0.700 0.010 262);/' \
		"$default_css" >"$tmp/apca.css"

	# Rule 8: a sunk surface one perceptual step from the page.
	sed 's/--color-bg-sunk: oklch(0.172 0.006 262);/--color-bg-sunk: oklch(0.195 0.006 262);/' \
		"$default_css" >"$tmp/flat.css"

	# Rule 9: a peer mark in the current strand's hue and lightness.
	sed 's/--color-peer: oklch(0.640 0.180 305);/--color-peer: oklch(0.780 0.110 270);/' \
		"$default_css" >"$tmp/cvd.css"

	# Rule 10: a light attention mark too pale to see on white.
	awk '/--color-signal: oklch\(0.660 0.145 64\);/ { sub(/0.660 0.145 64/, "0.860 0.090 80") } { print }' \
		"$default_css" >"$tmp/pale-mark.css"

	local name
	for name in light-mark-as-text dark-quiet pale-avatar avatar-drift missing raw-mark raw-hue faint \
		light-drift no-inherit light-lacks gamut apca flat cvd pale-mark; do
		if check "$tmp/$name.css" >/dev/null 2>&1; then
			echo "web_client_contrast_check: self-test: $name passed the check" >&2
			return 1
		fi
	done

	# The letter planted near the floor passes on its own, so `pale-avatar`
	# fails on the disc and not on the letter.
	if ! check "$tmp/avatar-floor.css" >/dev/null 2>&1; then
		echo "web_client_contrast_check: self-test: the avatar letter planted at the floor failed alone" >&2
		return 1
	fi

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
