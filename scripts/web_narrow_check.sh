#!/usr/bin/env bash
# web_narrow_check.sh — measure the web view's narrow layouts in a real
# browser and fail when one is wrong.
#
#   scripts/web_narrow_check.sh <page-url | file holding the url>
#
# The page is a session page minted with `loom ui --session <id> --operate`.
# A link works once, so a file argument lets a caller mint the link into a
# file and hand over the file's name. The script drives one `agent-browser` session of its own
# (`AGENT_BROWSER_SESSION`, default `narrow`; the default browser session is
# shared by every agent on a machine, so pass your own) and needs a daemon
# whose session is showing an approval card for the last check, which skips
# itself with a note when no card is on the page. It is a drive aid and not
# part of `make check`: it needs a live daemon and a browser.
#
# ## What it holds (docs/design-notes/web-design.md, section 10)
#
#   1. At 800x900 the strand panel is tall enough for its strip of cards:
#      the panel's bottom edge is at or below the strip's, so no card is
#      clipped by the panel's `overflow`. The round-3 critique measured
#      `.region-panel` at 41px over a 61px strip (F56).
#   2. At 800x900 the panel's own toggle (Control+Alt+B) takes the panel to
#      no height (its one-pixel border stays), and pressing it again brings
#      the cards back.
#   3. At 1100x900 there is no sidebar column. Control+B opens the sidebar
#      as a 232px drawer over a scrim, and Escape closes it (F69). A press
#      of a button inside the drawer closing it is a drive step, because a
#      session row leaves the page.
#   4. At 800x900 with an approval card showing, the transcript
#      (`loom-follow`) is at least 55% of the window's height once the strip
#      is folded away with the panel's toggle (F71). With the strip showing
#      it cannot be: the top bar, the tabs, the strip, the composer and one
#      card are 430px of 900, so the script reports that share and does not
#      gate it.
#
#   5. At 800x900 the Changes, Trace and Session tabs take up to 45vh and
#      scroll inside it, and the Strands tab keeps its 132px row of cards
#      (F95). The round-4 critique saw the Trace tab clipped at 132px.
#
# The measurements are bounding boxes read through every shadow root, since
# the panel and the drawer are in `<loom-shell>`'s tree and the strip and the
# transcript are in the server component's.
set -euo pipefail

url=${1:?usage: web_narrow_check.sh <page-url | file holding the url>}
if [ -f "$url" ]; then
	url=$(head -n 1 "$url")
fi
export AGENT_BROWSER_SESSION=${AGENT_BROWSER_SESSION:-narrow}

# The measurement: a JSON object of boxes and the transcript's share of the
# window, read from the page as it is now.
read -r -d '' probe <<'JS' || true
(() => {
  const find = (root, sel) => {
    const hit = root.querySelector(sel);
    if (hit) return hit;
    for (const el of root.querySelectorAll("*")) {
      if (el.shadowRoot) {
        const inner = find(el.shadowRoot, sel);
        if (inner) return inner;
      }
    }
    return null;
  };
  const box = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { top: Math.round(r.top), bottom: Math.round(r.bottom), width: Math.round(r.width), height: Math.round(r.height) };
  };
  const panel = find(document, ".region-panel");
  const strip = find(document, "nav.agent-strip");
  const follow = find(document, "loom-follow");
  const drawer = find(document, ".region-sidebar");
  const scrim = find(document, ".drawer-scrim");
  const approvals = find(document, "section.approvals");
  const body = find(document, "aside.panel");
  return JSON.stringify({
    panel: box(panel),
    strip: box(strip),
    follow: box(follow),
    approvals: approvals ? box(approvals) : null,
    body: body ? { ...box(body), scroll: body.scrollHeight, max: getComputedStyle(body).maxHeight } : null,
    drawer: drawer ? { ...box(drawer), display: getComputedStyle(drawer).display } : null,
    scrim: scrim ? box(scrim) : null,
    share: follow ? Math.round((follow.getBoundingClientRect().height / window.innerHeight) * 1000) / 10 : 0,
  });
})()
JS

failed=0

measure() {
  agent-browser eval "$probe"
}

# `check <label> <python expression over m>`: m is the last measurement.
check() {
  local label=$1 expression=$2 state=$3
  if python3 -c "
import json, sys
m = json.loads(json.loads(sys.argv[1]))
sys.exit(0 if ($expression) else 1)" "$state"; then
	echo "ok    $label"
else
	echo "FAIL  $label"
	echo "      $state"
	failed=1
fi
}

# The page's real wiring needs a moment after a resize or a key.
settle() {
  agent-browser wait 400 >/dev/null
}

agent-browser open "$url" >/dev/null
agent-browser wait 1500 >/dev/null

echo "== 800x900"
agent-browser set viewport 800 900 >/dev/null
settle
m=$(measure)
check "the panel holds its strip of cards (F56)" \
	"m['strip'] and m['panel']['bottom'] >= m['strip']['bottom'] and m['strip']['height'] > 0" "$m"

# The panel's bottom border stays when the panel has no height, so "hidden"
# is at most one pixel.
agent-browser press Control+Alt+b >/dev/null
settle
hidden=$(measure)
check "the panel toggle hides the cards" "m['panel']['height'] <= 1" "$hidden"
agent-browser press Control+Alt+b >/dev/null
settle
m=$(measure)
check "the panel toggle shows them again" "m['panel']['height'] > 1 and m['strip']['height'] > 0" "$m"

# F95. Below 980px the Strands tab is a row of cards 132px tall at most; any
# other tab takes up to 45vh (405px at 900) and scrolls inside it. The tab is
# chosen through the page, since its buttons are in a shadow root.
pick_tab() {
  agent-browser eval "(() => {
    const walk = (root) => {
      for (const b of root.querySelectorAll('button')) {
        if (b.textContent.trim() === '$1') { b.click(); return true; }
      }
      for (const el of root.querySelectorAll('*')) {
        if (el.shadowRoot && walk(el.shadowRoot)) return true;
      }
      return false;
    };
    return walk(document);
  })()" >/dev/null
  settle
}
pick_tab Trace
m=$(measure)
check "the Trace tab takes up to 45vh and scrolls inside it (F95)" \
	"m['body'] and float(m['body']['max'].replace('px','')) == 405 and m['body']['height'] <= 406" "$m"
pick_tab Session
m=$(measure)
check "the Session tab takes up to 45vh too (F95)" \
	"m['body'] and float(m['body']['max'].replace('px','')) == 405 and m['body']['height'] <= 406" "$m"
pick_tab Strands
m=$(measure)
check "the Strands tab keeps the 132px row of cards (F95)" \
	"m['body'] and float(m['body']['max'].replace('px','')) == 132 and m['body']['height'] <= 133" "$m"

# F71. The strip, the tab bar, the top bar, the composer and one approval card
# take 430px of 900 between them, so the transcript cannot be 55% of the
# window while the strip is showing; it is 55% once the reader folds the strip
# away with its toggle, and that is what is held. The share with the strip
# showing is reported so a regression in the card's size is seen.
if [ "$(python3 -c "import json,sys; print(json.loads(json.loads(sys.argv[1]))['approvals'] is not None)" "$m")" = True ]; then
	echo "note  transcript share with the strip showing: $(python3 -c "import json,sys; print(json.loads(json.loads(sys.argv[1]))['share'])" "$m")%"
	check "an approval card leaves the transcript 55% of the window once the strip is folded away (F71)" "m['share'] >= 55" "$hidden"
else
	echo "skip  no approval card on the page; the transcript share is $(python3 -c "import json,sys; print(json.loads(json.loads(sys.argv[1]))['share'])" "$m")%"
fi

echo "== 1100x900"
agent-browser set viewport 1100 900 >/dev/null
settle
m=$(measure)
check "no sidebar column below 1212px" "m['drawer'] is None or m['drawer']['display'] == 'none'" "$m"
agent-browser press Control+b >/dev/null
settle
m=$(measure)
check "Control+B opens a 232px drawer over a scrim (F69)" \
	"m['drawer'] and m['drawer']['display'] != 'none' and m['drawer']['width'] == 232 and m['scrim'] is not None" "$m"
agent-browser press Escape >/dev/null
settle
m=$(measure)
check "Escape closes the drawer" "m['scrim'] is None and (m['drawer'] is None or m['drawer']['display'] == 'none')" "$m"

echo "== 1440x900"
agent-browser set viewport 1440 900 >/dev/null
settle
m=$(measure)
check "a wide page has its sidebar column and no scrim" \
	"m['drawer'] and m['drawer']['width'] == 232 and m['scrim'] is None" "$m"
check "an approval card leaves the transcript 55% at 1440 (F71)" \
	"m['approvals'] is None or m['share'] >= 55" "$m"

exit "$failed"
