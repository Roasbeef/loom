#!/usr/bin/env python3
"""Scratch generator for the terminal-revamp concept A frames.

Writes one .txt grid per frame (source of truth, exact cell widths) and a
runs JSON used by the HTML renderer.  Every row is built to an exact width
and asserted, so a frame cannot silently drift from its claimed size.
"""
import json, os, re, sys

"""Usage: python3 A-sonnet-gen.py   (run from anywhere; writes beside itself)."""
OUT = os.path.dirname(os.path.abspath(__file__))
P = "A-sonnet-"

# ---------------------------------------------------------------- cells
def cells(text, cls, width=None):
    out = [(ch, cls) for ch in text]
    if width is not None:
        if len(out) > width:
            out = out[: width - 1] + [("…", cls)]
        out += [(" ", cls)] * (width - len(out))
    return out

def row(width, segs, bg=""):
    """segs: list of (text, cls). Pads with bg. A seg text of None is ignored."""
    out = []
    for t, c in segs:
        out += [(ch, (c + " " + bg).strip()) for ch in t]
    if len(out) > width:
        out = out[: width - 1] + [("…", out[width - 1][1] if out else bg)]
    out += [(" ", bg)] * (width - len(out))
    return out

def lr(width, left, right, bg=""):
    """Left segs and right segs on one row; the left is cut to leave the right."""
    rl = sum(len(t) for t, _ in right)
    l = row(width - rl, left, bg)
    r = row(rl, right, bg)
    return l + r

def blank(width, bg=""):
    return [(" ", bg)] * width

def hr(width, cls="div", ch="─"):
    return [(ch, cls)] * width

# ---------------------------------------------------------------- content
HUE = {"main": "cur", "advisor": "adv", "sub:tests": "add", "sub:docs": "qb"}

def tab_bar(width, active, attention=1, keys=True):
    names = ["Strands", "Changes", "Trace", "Session"]
    fk = ["F2", "F3", "F4", "F5"]
    out = []
    used = 0
    segs = []
    for i, n in enumerate(names):
        sel = i == active
        bg = "rs" if sel else ""
        label = " " + n + " "
        segs.append((label, "p b" if sel else "q", bg))
        used += len(label)
        if i == 0 and attention:
            segs.append(("●" + str(attention) + " ", "dan b", bg))
            used += 3
    r = []
    for t, c, bg in segs:
        r += [(ch, (c + " " + bg).strip()) for ch in t]
    r += [(" ", "")] * (width - len(r))
    return r[:width]

def strand_cards(width, sel, hint_numbers=False, compact=False):
    """Two rows per strand plus a blank; returns list of rows."""
    items = [
        ("main", "●", "Working · code_mode", "cache 3m", "p"),
        ("advisor", "◇", "1 nudge pending", "", "q"),
        ("sub:tests", "●", "Needs approval", "cache 2m", "dan b"),
        ("sub:docs", "✓", "Finished 1m 12s", "", "q"),
    ]
    rows = []
    for i, (name, glyph, status, cache, scls) in enumerate(items):
        bg = "rs" if i == sel else ""
        hue = HUE[name]
        bar = "▌" if i == sel else " "
        num = ("[" + str(i) + "]") if hint_numbers else ""
        rows.append(lr(width,
            [(bar, hue), (glyph + " ", hue + " b"), (name, "p b"), (" " + num if num else "", "sig b")],
            [(cache + " ", "q")], bg))
        rows.append(row(width, [(bar, hue), ("  " + status, scls)], bg))
        if width > 60:
            pass
        elif not compact:
            rows.append(blank(width))
        if width > 60:
            rows.append(blank(width))
    return rows

def panel_strands(width, height, sel=0, hint_numbers=False):
    rows = [tab_bar(width, 0), hr(width)]
    rows.append(lr(width, [(" STRANDS · 4", "q b")], [("CACHE LEFT ", "q")]))
    rows.append(blank(width))
    rows += strand_cards(width, sel, hint_numbers, compact=width >= 80 and height < 20)
    return finish(rows, width, height, [
        (" ↑↓ select · Enter focus · x stop", "q"),
        (" 1-4 tab · Esc to composer", "q"),
    ])

MULTI = [
    ("main", "●", "Waiting · 2 reviewers", "p", "1m 34s", "259k"),
    ("code-review", "●", "Tracing publish_herdr path", "p", "2m 45s", "65k"),
    ("docs-review", "●", "Needs approval · fs_write", "dan b", "2m 38s", "74k"),
    ("grep-refs", "●", "Searching herdr references", "p", "1m 03s", "144k"),
    ("bootstrap", "●", "Reading bootstrap.gleam", "p", "51s", "119k"),
    ("lint-pass", "✓", "Finished 1m 12s", "q", "", ""),
]

def panel_multi(width, height, sel=2, hint_numbers=False):
    rows = [tab_bar(width, 0, attention=1), hr(width)]
    rows.append(row(width, [(" All 6", "p b"), (" · ", "q"), ("Needs you 1", "dan b"), (" · Working 4 · Done 1", "q")]))
    rows.append(blank(width))
    for i, (name, glyph, status, scls, el, ctx) in enumerate(MULTI):
        bg = "rs" if i == sel else ""
        bar = "▌" if i == sel else " "
        hue = "add" if glyph == "✓" else ("dan" if i == 2 else "cur")
        rows.append(lr(width, [(bar, hue), (glyph + " ", hue + " b"), (name, "p b")], [(el + " ", "q")], bg))
        rows.append(lr(width, [(bar, hue), ("  " + status, scls)], [((ctx + " ctx " if ctx else ""), "q")], bg))
    return finish(rows, width, height, [
        (" ↑↓ select · Enter focus · x stop", "q"),
        (" Tab filter · n next needs-you", "q"),
    ])

def panel_detail(width, height):
    rows = [tab_bar(width, 0), hr(width)]
    rows.append(row(width, [(" ← Strands", "cur"), ("   Esc", "q")]))
    rows.append(blank(width))
    rows.append(row(width, [(" ● ", "add b"), ("sub:tests", "p b")]))
    rows.append(row(width, [("   Working 34s · ", "q"), ("needs approval", "dan b")]))
    rows.append(blank(width))
    for k, v in [("Model", "kimi-k3 · low"), ("Context", "9k"),
                 ("Cache expires", "3m"), ("Running", "34s")]:
        rows.append(lr(width, [(" " + k, "q")], [(v + " ", "p")]))
    rows.append(blank(width))
    rows.append(row(width, [(" RECENT", "q b")]))
    rows.append(row(width, [(" Waiting on network approval", "p")]))
    rows.append(row(width, [(" Started bash · gleam test", "p")]))
    return finish(rows, width, height, [
        (" Enter: to composer · Esc: list", "q"),
    ])

def diff_rows(width):
    def d(text, cls):
        return row(width, [(text, cls)], {"add": "ab", "del": "rb"}.get(cls, ""))
    rows = []
    rows.append(row(width, [(" ▾ ", "q"), ("calc.gleam", "p b")]) [:width - 8] + row(8, [("+6 −0 ", "add")]))
    rows.append(row(width, [("  @@ -12,3 +12,9 @@", "q")]))
    rows.append(row(width, [("   pub fn add(a: Int, b: Int) -> Int {", "p")]))
    rows.append(row(width, [(" +pub fn subtract(a: Int, b: Int) -> Int {", "add")], "ab"))
    rows.append(row(width, [(" +  a - b", "add")], "ab"))
    rows.append(row(width, [(" +}", "add")], "ab"))
    rows.append(row(width, [("   a + b", "p")]))
    rows.append(row(width, [(" -  // TODO", "dan")], "rb"))
    rows.append(blank(width))
    rows.append(row(width, [(" ▸ ", "q"), ("README.md", "p b")])[:width - 8] + row(8, [("+8 −2 ", "add")]))
    rows.append(row(width, [(" ▸ ", "q"), ("calc_test.gleam", "p b")])[:width - 8] + row(8, [("+0 −0 ", "q")]))
    return rows

def panel_changes(width, height):
    rows = [tab_bar(width, 1), hr(width)]
    rows.append(lr(width, [(" CHANGES · 3 files", "q b")], [("+14 −2 ", "p b")]))
    rows.append(row(width, [(" from this session's edits", "q")]))
    rows.append(blank(width))
    rows += diff_rows(width)
    return finish(rows, width, height, [
        (" ↑↓ file · Enter open · r refresh", "q"),
        (" /diff shows the git worktree", "q"),
    ])

def panel_trace(width, height):
    rows = [tab_bar(width, 2), hr(width)]
    rows.append(row(width, [(" code_mode", "p b"), (" · check_subtract.gleam", "p")]))
    rows.append(row(width, [(" ● running 1.2s · main", "cur")]))
    rows.append(blank(width))
    rows.append(row(width, [(" CALLS", "q b")]))
    for n, (glyph, gc, name, arg) in enumerate([
        ("✓", "add", "cap/fs.read", "calc.gleam"),
        ("✓", "add", "cap/fs.read", "calc_test.gleam"),
        ("●", "cur", "cap/proc.run", "gleam test"),
    ], 1):
        tree = "└" if n == 3 else "├"
        rows.append(row(width, [(" " + tree + " ", "q"), (glyph + " ", gc), (name, "p"), ("  " + arg, "q")]))
    rows.append(blank(width))
    rows.append(row(width, [(" ▸ Budget", "q"), (" · cpu 30s · net off · vetted", "q")]))
    rows.append(row(width, [(" ▸ Program", "q"), (" · 14 lines · Enter to read", "q")]))
    return finish(rows, width, height, [
        (" Enter open · ↑↓ call", "q"),
        (" no per-call timing yet", "q"),
    ])

def panel_session(width, height, workspace="~/code/pi-gui"):
    rows = [tab_bar(width, 3), hr(width)]
    rows.append(row(width, [(" SESSION", "q b")]))
    rows.append(blank(width))
    for k, v in [("Goal", "subtract + README · 2 of 4"), ("Jobs", "1 running"),
                 ("Queue", "1 held input"), ("Schedules", "deps bump · 02:00"),
                 ("Viewers", "you, alex (2)"), ("Model", "kimi-k3 · low"),
                 ("Context", "~41%"), ("Cost", "est $1.86")]:
        rows.append(lr(width, [(" " + k, "q")], [(v + " ", "p")]))
    rows.append(blank(width))
    rows.append(row(width, [(" Layout is remembered for", "q")]))
    rows.append(row(width, [(" " + workspace, "q")]))
    return finish(rows, width, height, [
        (" Enter on a row opens its overlay", "q"),
    ])

def finish(rows, width, height, footer_lines):
    foot = [row(width, [t]) for t in footer_lines]
    body = height - len(foot)
    rows = rows[:body]
    rows += [blank(width)] * (body - len(rows))
    return rows + foot

def panel_rows(tab, width, height, **kw):
    return {"multi": panel_multi, "strands": panel_strands, "detail": panel_detail, "changes": panel_changes,
            "trace": panel_trace, "session": panel_session}[tab](width, height, **kw)

def left_column(width, height, focus=False):
    rows = []
    rows.append(row(width, [(" SESSIONS", "p b" if focus else "q b")]))
    rows.append(hr(width))
    rows.append(lr(width, [(" ~/code/pi-gui", "q")], [("3 ", "q")]))
    rows.append(lr(width, [("▌● ws · main", "p b")], [("▮", "cur"), ("▮", "adv"), ("▮", "add"), (" ", "")], "rs"))
    rows.append(row(width, [("  ● fix readme badge", "p")]))
    rows.append(row(width, [("  ○ extension api probe", "q")]))
    rows.append(blank(width))
    rows.append(hr(width))
    rows.append(lr(width, [(" ~/code/lnd-review", "q")], [("2 ", "q")]))
    rows.append(row(width, [("  ● review htlc interceptor", "p")]))
    rows.append(row(width, [("  ○ nightly: deps bump", "q")]))
    return finish(rows, width, height, [
        (" F1 focus · Enter open", "q"),
        (" F1 hide · /sessions", "q"),
    ])

# ---- transcript
def tag(name, num=None):
    hue = HUE[name]
    segs = [("[" + name + "]", hue + " b")]
    if num is not None:
        segs.append((" [" + str(num) + "]", "sig b"))
    return segs

def transcript_main(width, hints=False):
    """Rows of the main strand's transcript, gutter included (1 cell)."""
    def g(segs, hue=None, bg=""):
        gut = ("▎", hue) if hue else (" ", "")
        return row(width, [gut] + segs, bg)
    n = (lambda k: k) if hints else (lambda k: None)
    R = []
    R.append(g([("› ", "sig b"), ("What does calc.gleam export today?", "p")], None, "ub"))
    R.append(blank(width))
    R.append(g([("∴ Reasoning ", "q"), ("3s", "q")]))
    R.append(g([("└ ", "q"), ("read · src/calc.gleam", "q")]))
    R.append(blank(width))
    R.append(g([("◆ ", "cur b"), ("main", "p b")]))
    R.append(g([("  It exports ", "p"), ("add", "cur"), (" and ", "p"), ("multiply", "cur"), (", both over ", "p"), ("Int", "cur"), (".", "p")]))
    R.append(g([("  The tests in ", "p"), ("test/calc_test.gleam", "cur"), (" cover add only.", "p")]))
    R.append(blank(width))
    R.append(g([("✓ ", "add b"), ("gleam test", "p"), (" · 1 passed", "q")]))
    R.append(blank(width))
    R.append(g([("› ", "sig b"), ("Add a subtract function to calc.gleam, check it, and update the README.", "p")], None, "ub"))
    R.append(blank(width))
    R.append(g([("◇ ", "q"), ("Memory · 3 notes", "q")]))
    R.append(g([("└ ", "q"), ("read 3 files · edited calc.gleam +6 −0", "q")]))
    R.append(g([("◇ ", "q"), ("tools · 4 calls · ", "q"), ("1 failed", "dan b"), (" · Ctrl+g expands", "q")]))
    R.append(blank(width))
    R.append(g([("● ", "cur b"), ("main", "p b"), (" spawned 2 strands", "q")] + ([("  [0]", "sig b")] if hints else [])))
    R.append(g([("├ ", "q"), ("● ", "add"), ("sub:tests ", "add b"), (" run gleam test", "p"), (" · ", "q"), ("needs approval", "dan b"), (" · 9k ctx · 34s", "q")] + ([(" [2]", "sig b")] if hints else []), "add"))
    R.append(g([("└ ", "q"), ("✓ ", "add"), ("sub:docs  ", "qb b"), (" draft README example", "p"), (" · finished · 1m 12s", "q")] + ([(" [3]", "sig b")] if hints else []), "qb"))
    R.append(blank(width))
    R.append(g([("◇ ", "adv b"), ("advisor", "adv b"), (" · nudge for main · 12s ago", "q")] + ([(" [1]", "sig b")] if hints else []), "adv"))
    R.append(g([("  Consider running the unit tests before committing.", "p")], "adv"))
    R.append(blank(width))
    R.append(g([("∴ Reasoning ", "q"), ("9s", "q")]))
    R.append(g([("● ", "cur b"), ("code_mode", "p"), (" check_subtract.gleam · running 1.2s", "q")]))
    R.append(blank(width))
    R.append(g([("◆ ", "cur b"), ("main", "p b")] + ([(" [0]", "sig b")] if hints else [])))
    R.append(g([("  I added ", "p"), ("subtract", "cur"), (" next to ", "p"), ("add", "cur"),
                (". Both tests should pass once", "p")]))
    R.append(g([("  ", "p"), ("sub:tests", "p b"), (" reports back, then I will update the README example.", "p")]))
    return R

def transcript_multi(width):
    def g(segs, hue=None, bg=""):
        gut = ("▎", hue) if hue else (" ", "")
        return row(width, [gut] + segs, bg)
    R = []
    R.append(g([("◆ ", "cur b"), ("main", "p b")]))
    R.append(g([("  Both reviewers are still working. Next: fold in their findings, then", "p")]))
    R.append(g([("  restructure the commits.", "p")]))
    R.append(blank(width))
    R.append(g([("◇ ", "q"), ("harness · background job 01a0eff2 was lost when its sandbox helper exited", "sig")]))
    R.append(g([("  (a notice from Loom, not a message from you)", "q")]))
    R.append(blank(width))
    R.append(g([("✓ ", "add b"), ("agent_wait", "p"), (" · 2 subagents", "q"), (" ×15", "sig b"), (" · last 51s ago · still waiting", "q")]))
    R.append(g([("! ", "dan b"), ("provider 429 rate limited", "dan"), (" ×7", "sig b"), (" · retry in 8s · Ctrl+g details", "q")]))
    R.append(blank(width))
    R.append(g([("● ", "cur b"), ("agent_spawn", "p"), (" docs accuracy review · started", "q")]))
    R.append(g([("├ ", "q"), ("● ", "cur"), ("code-review ", "cur b"), (" Tracing publish_herdr · 65k ctx · 2m 45s", "p")], "cur"))
    R.append(g([("└ ", "q"), ("● ", "dan"), ("docs-review ", "dan b"), (" fs_write needs approval · 74k ctx · 2m 38s", "p")], "dan"))
    R.append(blank(width))
    R.append(g([("› ", "sig b"), ("once the reviews are in, implement them and restructure the commits", "p")], None, "ub"))
    R.append(g([("◇ ", "q"), ("queued · runs after this turn", "q")]))
    return R

def transcript_strand(width):
    def g(segs, hue=None, bg=""):
        gut = ("▎", hue) if hue else (" ", "")
        return row(width, [gut] + segs, bg)
    R = []
    R.append(g(tag("main") + [(" forked this strand · 34s ago", "q")], "cur"))
    R.append(g([("› ", "sig b"), ("Run gleam test and report failures.", "p")], None, "ub"))
    R.append(blank(width))
    R.append(g([("∴ Reasoning ", "q"), ("4s", "q")]))
    R.append(g([("● ", "cur b"), ("bash", "p"), (" gleam test · ", "q"), ("waiting for approval", "dan b")]))
    R.append(blank(width))
    R.append(g([("◇ ", "q"), ("network access to proxy.golang.org needs a decision. The approval dialog", "q")]))
    R.append(g([("  is open on this strand; the panel shows status only.", "q")]))
    return R

# ---------------------------------------------------------------- frame
def frame(W, H, *, left=0, right=0, tab="strands", strip=False, focused=False,
          hints=False, breadcrumb=None, sheet=False, footer_note="", panel_kw=None, scene="main", scroll=False, more=0):
    panel_kw = panel_kw or {}
    rows = []
    # top bar, unchanged from today
    title = " ws · pi-gui (main) "
    rtxt = "kimi-k3 · Ctrl+g details"
    rows.append(lr(W, [(" ◆ loom ", "sig b"), ("  " + title, "p")], [(rtxt + " ", "q")], "gr"))

    comp_h = 4 if H <= 24 else 6   # rule, input rows, status, blank
    foot_h = 1 if W >= 100 else 2
    strip_h = (3 if scene != "multi" else more) if strip else 0
    body_h = H - 1 - comp_h - foot_h - strip_h   # rows of the region above the composer
    col_h = H - 1 - foot_h - strip_h             # side columns run down to the footer

    cw = W - (left + 1 if left else 0) - (right + 1 if right else 0)
    # centre column
    heading = breadcrumb or " transcript / main "
    if focused:
        hl = [(" ws · main ", "q"), ("▸ ", "q"), ("sub:tests ", "add b")]
        hr_ = [("Ctrl+t 0 all strands ", "q")]
    else:
        hl = [(" ↓ Scrollback · End for latest " if scroll else heading, "sig b" if scroll else "q")]
        hr_ = [("queue · 1 pending · Alt+q ", "q")] if scene == "multi" else []
    centre = [lr(cw, hl, hr_)]
    tl = transcript_strand(cw) if focused else (transcript_multi(cw) if scene == "multi" else transcript_main(cw, hints))
    avail = body_h - 1 - 1   # heading and todo line
    tl = tl[-avail:]
    centre += tl + [blank(cw)] * (avail - len(tl))
    centre.append(blank(cw) if focused else row(cw, [(" ▸ Todo ", "p b"), ("· 3 of 5 done · ", "q"), ("Ctrl+g", "cur")]))
    tgt = "sub:tests" if focused else "main"
    centre.append(row(cw, [("─", "sig"), (" To " + tgt + " · enter queues · tab steers ", "sig")]) [:cw - 1] + [("─", "sig")] if False else
                  [(ch, c) for ch, c in row(cw, [("─ To " + tgt + " · enter queues · tab steers ", "sig")])][:cw])
    centre[-1] = [(ch, "sig") if ch in "─" or True else (ch, c) for ch, c in centre[-1]]
    # fill the rule with line chars
    rule = "─ To " + tgt + " · enter queues · tab steers "
    centre[-1] = cells(rule + "─" * (cw - len(rule)), "sig", cw)
    centre.append(row(cw, [(" ›", "sig b"), (" ", "")]))
    centre += [blank(cw)] * (comp_h - 4)
    centre.append(row(cw, [(" ◒ streaming (3s) · esc to interrupt", "q")]))
    centre.append(blank(cw))
    # the centre region above holds body_h + comp_h rows
    assert len(centre) == body_h + comp_h, (len(centre), body_h + comp_h)

    body = []
    for y in range(body_h + comp_h):
        parts = []
        if left:
            parts.append(None)
        body.append(parts)

    lcol = left_column(left, col_h, focus=False) if left else None
    if right and not sheet:
        rcol = panel_rows(tab, right, col_h, **panel_kw)
    else:
        rcol = None

    out = [rows[0]]
    for y in range(col_h):
        line = []
        if lcol:
            line += lcol[y] + [("│", "div")]
        if y < len(centre):
            line += centre[y]
        else:
            line += blank(cw)
        if rcol:
            line += [("│", "div")] + rcol[y]
        out.append(line)
    # anything below the centre column when the side columns end (none: col_h rows)
    # widen rows: centre only has body_h + comp_h == col_h rows
    assert body_h + comp_h == col_h

    if strip:
        out += strip_rows(W) if scene != "multi" else strip_multi(W, more - 1)
    out += footer_rows(W, foot_h, left, right, sheet, hints, scene)
    assert len(out) == H, (len(out), H)
    for r in out:
        assert len(r) == W, (len(r), W)
    return out

def strip_rows(W):
    r = [hr(W)]
    r.append(row(W, [("› ", "sig b"), ("● ", "cur"), ("main              ", "p"), ("streaming", "q")]))
    r.append(row(W, [("  ● ", "add"), ("sub:tests         ", "p"), ("needs approval", "dan b")]))
    return r

def strip_multi(W, n):
    r = [hr(W)]
    for name, glyph, status, scls, el, ctx in MULTI[:n - 1]:
        hue = "dan" if scls.startswith("dan") else "cur"
        r.append(lr(W, [("  " + glyph + " ", hue), (name.ljust(12), "p b" if hue == "dan" else "p"), (status, scls)], [(el.rjust(7) + " · " + ctx.rjust(5) + " ctx ", "q")]))
    r.append(row(W, [("  +" + str(len(MULTI) - n + 1) + " more · F2 opens the list", "q")]))
    return r

def footer_rows(W, n, left, right, sheet, hints=False, scene="main"):
    hint = "← strands · F1 sessions · ⇧Tab panel" if W >= 100 else "← F1 ⇧Tab"
    note = "3 agents · 2 working · 1 needs you" if scene != "multi" else "6 agents · 4 working · 1 needs you"
    if hints:
        msg = " Focus a strand: press its number (0 is main) · Esc cancels"
        return [lr(W, [(msg, "sig b")], [(note + " ", "q")])]
    if n == 1:
        return [lr(W, [(" baseten-kimi-k3 · ctx ~41% · est $1.86 · ", "q"), (hint, "q")], [(note + " ", "q")])]
    return [row(W, [(" kimi-k3 · ctx ~41% · est $1.86", "q")]),
            lr(W, [(" F2 strands · F3 changes", "q")], [(note + " ", "q")])]

def sheet_frame(W, H, tab):
    """Narrow: the panel is a sheet over the transcript; composer and footer stay."""
    comp_h = 4
    foot_h = 2
    out = [lr(W, [(" ◆ loom ", "sig b"), ("  ws · pi-gui (main)", "p")], [("kimi-k3 · Ctrl+g ", "q")], "gr")]
    sh = H - 1 - comp_h - foot_h
    sheet = panel_rows(tab, W, sh)
    out += sheet
    rule = "─ To main · enter queues · tab steers "
    out.append(cells(rule + "─" * (W - len(rule)), "sig", W))
    out.append(row(W, [(" ›", "sig b")]))
    out.append(row(W, [(" ◒ streaming (3s) · esc to interrupt", "q")]))
    out.append(blank(W))
    out += footer_rows(W, foot_h, 0, 0, True)
    assert len(out) == H and all(len(r) == W for r in out), (len(out), H)
    return out

# ---------------------------------------------------------------- write
FRAMES = {}
def add(name, W, H, grid, title):
    FRAMES[name] = (W, H, grid, title)

add("wide", 200, 50, frame(200, 50, left=30, right=56, tab="strands"),
    "Wide, 200x50: sessions column, transcript, tabbed panel (Strands)")
add("wide-strand", 200, 50,
    frame(200, 50, left=30, right=56, tab="detail", focused=True),
    "Wide, 200x50: strand sub:tests focused, detail view in the panel")
add("wide-focus", 200, 50, frame(200, 50, strip=True),
    "Wide, 200x50: both side columns collapsed (focus mode)")
add("standard", 120, 40, frame(120, 40, strip=True),
    "Standard, 120x40: default, panel closed, strip as today")
add("standard-strands", 120, 40, frame(120, 40, right=44, tab="strands"),
    "Standard, 120x40: panel open on Strands")
add("standard-changes", 120, 40, frame(120, 40, right=44, tab="changes"),
    "Standard, 120x40: panel open on Changes")
add("standard-trace", 120, 40, frame(120, 40, right=44, tab="trace"),
    "Standard, 120x40: panel open on Trace")
add("standard-session", 120, 40, frame(120, 40, right=44, tab="session"),
    "Standard, 120x40: panel open on Session")
add("standard-hints", 120, 40, frame(120, 40, right=44, tab="strands", hints=True,
    panel_kw={"hint_numbers": True}),
    "Standard, 120x40: Ctrl+t hint mode numbers every strand tag")
add("standard-multi", 120, 40, frame(120, 40, right=44, tab="multi", scene="multi", panel_kw={"sel": 2}),
    "Standard, 120x40: six agents, one needs you; repeats and notices collapsed")
add("narrow-multi", 80, 24, frame(80, 24, strip=True, scene="multi", scroll=True, more=6),
    "Narrow, 80x24: six agents, one needs you; strip shows the top five")
add("narrow", 80, 24, frame(80, 24, strip=True),
    "Narrow, 80x24: default, as today")
add("narrow-strands", 80, 24, sheet_frame(80, 24, "strands"),
    "Narrow, 80x24: F2 opens the panel as a sheet (Strands)")
add("narrow-changes", 80, 24, sheet_frame(80, 24, "changes"),
    "Narrow, 80x24: F3 sheet (Changes)")

meta = {}
for name, (W, H, grid, title) in FRAMES.items():
    with open(os.path.join(OUT, P + name + ".txt"), "w") as f:
        for r in grid:
            f.write("".join(ch for ch, _ in r).rstrip() + "\n")
    runs = []
    for r in grid:
        rr = []
        cur, buf = None, ""
        for ch, c in r:
            if c == cur:
                buf += ch
            else:
                if buf:
                    rr.append([cur, buf])
                cur, buf = c, ch
        rr.append([cur, buf])
        runs.append(rr)
    meta[name] = {"w": W, "h": H, "title": title, "runs": runs}
frames = meta
print("frames:", len(meta))

# ---------------------------------------------------------------- html
def ansi_runs(path, w, h):
    text = open(path).read().split("\n")
    rows = []
    fg = bg = None
    bold = dim = rev = False
    for line in text[:h]:
        runs, buf, cur = [], "", None
        i = 0
        cells = 0
        def flush():
            nonlocal buf
            if buf:
                runs.append([cur, buf])
                buf = ""
        while i < len(line):
            if line[i] == "\x1b":
                m = re.match(r"\x1b\[([0-9;]*)m", line[i:])
                if m:
                    flush()
                    codes = [int(c) if c else 0 for c in m.group(1).split(";")]
                    j = 0
                    while j < len(codes):
                        c = codes[j]
                        if c == 0: fg = bg = None; bold = dim = rev = False
                        elif c == 1: bold = True
                        elif c == 2: dim = True
                        elif c == 22: bold = dim = False
                        elif c == 7: rev = True
                        elif c == 27: rev = False
                        elif c == 39: fg = None
                        elif c == 49: bg = None
                        elif c in (38, 48) and j + 4 < len(codes) + 0 and codes[j+1] == 2:
                            col = "#%02x%02x%02x" % tuple(codes[j+2:j+5])
                            if c == 38: fg = col
                            else: bg = col
                            j += 4
                        elif c in (38, 48) and codes[j+1] == 5:
                            j += 2
                        j += 1
                    i += m.end()
                    continue
                m = re.match(r"\x1b[\(\)][A-Z0-9]|\x1b\[[0-9;?]*[A-Za-ln-z]", line[i:])
                if m:
                    i += m.end(); continue
                i += 1
                continue
            style = {"fg": fg, "bg": bg, "b": bold, "dim": dim, "rev": rev}
            if style != cur:
                flush(); cur = style
            buf += line[i]
            i += 1
            cells += 1
        flush()
        if cells < w:
            runs.append([{"fg": None, "bg": None}, " " * (w - cells)])
        rows.append(runs)
    while len(rows) < h:
        rows.append([[{"fg": None, "bg": None}, " " * w]])
    return rows

for name, w, h in [("before-wide-diff", 200, 50), ("before-120", 120, 40),
                   ("before-120-rail", 120, 40), ("before-120-agents", 120, 40),
                   ("before-80", 80, 24)]:
    p = os.path.join(OUT, name + ".ansi")
    if os.path.exists(p):
        frames[name] = {"w": w, "h": h, "title": "Before: " + name, "runs": ansi_runs(p, w, h), "raw": True}

html = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Terminal revamp, concept A</title>
<style>
:root{--pg:#fbfbfc;--gr:#f3f5f8;--p:#202b3c;--q:#4e5d6f;--sig:#894d00;--cur:#00687d;--adv:#6a40a1;--dan:#b2233b;--add:#236f3a;--div:#a2b1c2;--qb:#4e5d6f;--rs:#dce7f3;--ub:#fbf1dd;--ab:#e0f2e4;--rb:#f9e4e8;--chrome:#e8eaee}
:root[data-theme=dark]{--pg:#121417;--gr:#181b1f;--p:#e7edf5;--q:#a0abb8;--sig:#ffbd69;--cur:#6edbe8;--adv:#c0a6f5;--dan:#ff8e9b;--add:#8ed6a1;--div:#3c4a5b;--qb:#aab0b6;--rs:#25303f;--ub:#26221d;--ab:#183423;--rb:#391b1f;--chrome:#0a0b0d}
body{margin:0;background:var(--chrome);color:var(--p);font:14px system-ui,sans-serif}
header{padding:12px 16px;display:flex;gap:16px;align-items:center;flex-wrap:wrap}
header button{font:inherit;padding:4px 10px}
h2{font:600 13px system-ui;margin:20px 16px 6px}
.term{background:var(--pg);margin:0 16px 8px;padding:0;width:max-content;max-width:calc(100vw - 32px);overflow-x:auto}
pre{margin:0;font:13px/17px Menlo,"DejaVu Sans Mono",Consolas,monospace;font-variant-ligatures:none;color:var(--p);background:var(--pg);padding:4px 3px}
pre div{white-space:pre;height:17px;overflow:hidden}
.p{color:var(--p)}.q{color:var(--q)}.sig{color:var(--sig)}.cur{color:var(--cur)}.adv{color:var(--adv)}.dan{color:var(--dan)}.add{color:var(--add)}.div{color:var(--div)}.qb{color:var(--qb)}
.b{font-weight:700}.rs{background:var(--rs)}.ub{background:var(--ub)}.ab{background:var(--ab)}.rb{background:var(--rb)}.gr{background:var(--gr)}
body.solo{background:var(--pg)}body.solo header,body.solo h2{display:none}body.solo .term{margin:0;max-width:none}
</style></head><body>
<header><strong>Terminal revamp, concept A</strong>
<button id="t">Theme</button><span id="n"></span></header>
<main id="m"></main>
<script>
const FRAMES = __FRAMES__;
const q = new URLSearchParams(location.search);
const root = document.documentElement;
const saved = q.get("theme") || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
root.dataset.theme = saved;
document.getElementById("t").onclick = () => { root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark"; };
function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;");}
function build(name){
  const f = FRAMES[name];
  const pre = document.createElement("pre");
  for (const row of f.runs){
    const d = document.createElement("div");
    let h = "";
    for (const [c, t] of row){
      if (typeof c === "string") h += '<span class="'+c+'">'+esc(t)+'</span>';
      else {
        let st = "";
        let fg = c.fg, bg = c.bg;
        if (c.rev){ const x = fg; fg = bg || "var(--pg)"; bg = x || "var(--p)"; }
        if (fg) st += "color:"+fg+";";
        if (bg) st += "background:"+bg+";";
        if (c.b) st += "font-weight:700;";
        if (c.dim) st += "opacity:.7;";
        h += '<span style="'+st+'">'+esc(t)+'</span>';
      }
    }
    d.innerHTML = h; pre.appendChild(d);
  }
  const w = document.createElement("div"); w.className = "term"; w.appendChild(pre); return w;
}
const one = q.get("f");
const m = document.getElementById("m");
if (one && FRAMES[one]) { document.body.classList.add("solo"); m.appendChild(build(one)); }
else for (const name of Object.keys(FRAMES)){
  const h = document.createElement("h2"); h.id = name;
  h.textContent = name + " · " + FRAMES[name].w + "x" + FRAMES[name].h + " · " + FRAMES[name].title;
  m.appendChild(h); m.appendChild(build(name));
}
</script></body></html>
"""
html = html.replace("__FRAMES__", json.dumps(frames, separators=(",", ":")))
open(os.path.join(OUT, P[:-1] + ".html"), "w").write(html)
print("html bytes", len(html))
