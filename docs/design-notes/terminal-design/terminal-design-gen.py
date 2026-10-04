#!/usr/bin/env python3
"""Generator for the combined terminal-revamp frames (issue #655, #672).

It extends A-sonnet-gen.py.  The cell helpers, the picker and the agent
workspace are A's; the seven-agents view, the messages, the code-mode blocks,
the image rows, the approval and the pain-point frames take B's layouts.  The
sessions column is gone: sessions are reached with Left, and the header is one
slim identity line with the live status on the input frame.

Every frame is built row by row and asserted to be exactly 200x50, 120x40 or
80x24 cells, one single-width character per cell.  The .txt grids are the
source of truth; the viewer HTML renders them with the palette classes.

Usage: python3 terminal-design-gen.py   (writes beside itself).
"""
import json, os, sys, unicodedata

OUT = os.path.dirname(os.path.abspath(__file__))
P = "terminal-design-"
SIZES = ((200, 50), (120, 40), (80, 24))

# ------------------------------------------------------------------ cells
def cells(text, cls, width=None):
    out = [(ch, cls) for ch in text]
    if width is not None:
        if len(out) > width:
            out = out[: width - 1] + [("…", cls)]
        out += [(" ", cls)] * (width - len(out))
    return out

def row(width, segs, bg=""):
    """segs: list of (text, cls).  Pads with bg and cuts with an ellipsis."""
    out = []
    for t, c in segs:
        out += [(ch, (c + " " + bg).strip()) for ch in t]
    if len(out) > width:
        out = out[: width - 1] + [("…", out[width - 1][1] if out else bg)]
    out += [(" ", bg)] * (width - len(out))
    return out

def lr(width, left, right, bg=""):
    rl = sum(len(t) for t, _ in right)
    return row(width - rl, left, bg) + row(rl, right, bg)

def blank(width, bg=""):
    return [(" ", bg)] * width

def hr(width, cls="div", ch="─"):
    return [(ch, cls)] * width

def wrap(text, width):
    words, lines, cur = text.split(), [], ""
    for wd in words:
        if len(cur) + (1 if cur else 0) + len(wd) <= width:
            cur = (cur + " " + wd).strip()
        else:
            lines.append(cur)
            cur = wd
    if cur:
        lines.append(cur)
    return lines

def cut(text, width):
    """Truncate at a word boundary with an ellipsis, never mid-word."""
    if len(text) <= width:
        return text
    t = text[: width - 1]
    if " " in t and text[width - 1] != " ":
        t = t[: t.rindex(" ")]
    return t.rstrip(" ·,") + "…"

def midcut(text, width):
    """Cut in the middle and keep the suffix, so twins stay distinguishable."""
    if len(text) <= width:
        return text
    keep = 5
    head = width - keep - 1
    return text[:head] + "…" + text[-keep:]

def box(w, h, title, tcls, bcls, inner):
    top = [("╭", bcls)] + [(c, tcls) for c in (" " + title + " " if title else "")]
    top += [("─", bcls)] * (w - 1 - len(top)) + [("╮", bcls)]
    rows = [top[:w]]
    for i in range(h - 2):
        r = inner[i] if i < len(inner) else blank(w - 2)
        r = (r + blank(w - 2))[: w - 2]
        rows.append([("│", bcls)] + r + [("│", bcls)])
    rows.append([("╰", bcls)] + [("─", bcls)] * (w - 2) + [("╯", bcls)])
    return rows

def paste(canvas, x, y, rows):
    for j, r in enumerate(rows):
        if y + j < len(canvas):
            line = canvas[y + j]
            for i, c in enumerate(r):
                if x + i < len(line):
                    line[x + i] = c
    return canvas

def titled(w, title, tcls, bcls, inner_rows, foot=None, fcls="q", indent=1):
    """A block with a titled top border, a left rule and a closing line."""
    pad = [(" ", "")] * indent
    top = pad + [("╭", bcls), ("─", bcls), (" ", "")] + [(ch, tcls) for ch in title] + [(" ", "")]
    top += [("─", bcls)] * (w - len(top) - 1) + [("╮", bcls)]
    out = [top[:w]]
    inner_w = w - indent - 4
    for r in inner_rows:
        line = pad + [("│", bcls), (" ", "")] + (r + blank(inner_w))[:inner_w] + [(" ", ""), ("│", bcls)]
        out.append(line)
    if foot:
        bot = pad + [("╰", bcls), ("─", bcls), (" ", "")] + [(ch, fcls) for ch in foot] + [(" ", "")]
        bot += [("─", bcls)] * (w - len(bot) - 1) + [("╯", bcls)]
    else:
        bot = pad + [("╰", bcls)] + [("─", bcls)] * (w - indent - 2) + [("╯", bcls)]
    out.append(bot[:w])
    for r in out:
        assert len(r) == w, (len(r), w)
    return out

# ------------------------------------------------------------------ chrome
HUE = {"main": "cur", "advisor": "adv", "sub:tests": "add", "sub:docs": "qb"}

def identity(W, strand="main"):
    """The one slim identity line: session, strand, model."""
    return lr(W, [(" ◆ ", "sig b"), ("pi-gui", "p b"), (" · fix readme badge", "p"), (" · strand ", "q"), (strand, "cur b")],
              [("kimi-k3 · low ", "q")], "gr")

def input_frame(cw, *, target="main", activity=("◐", "code_mode", "1.2s"), queue=0, needs=1, locked=False, hint=None):
    """Three rows.  The live status (activity, queue, context, cost) sits on
    the frame's own rules, as omp does."""
    compact = cw < 100
    keys = "Enter queues · Tab steers" if not compact else "Tab steers"
    if locked:
        left = " To %s · locked while deciding " % target
        right = " "
    else:
        left = " To %s · %s " % (target, keys)
        g, what, el = activity
        right = " %s %s · %s%s · Esc interrupts " % (g, what, el, (" · queue %d" % queue) if queue else "")
        if not el:
            right = " %s %s " % (g, what)
        elif compact and cw < 90:
            right = " %s %s · %s%s · Esc " % (g, what, el, (" · queue %d" % queue) if queue else "")
    top = [("╭", "sig"), ("─", "sig")] + cells(left, "sig b") + [("─", "sig")] * (cw - 3 - len(left) - len(right) - 1)
    top += cells(right, "q") + [("─", "sig"), ("╮", "sig")]
    top = top[:cw]
    assert len(top) == cw, (len(top), cw)
    ph = hint or "← sessions · ↓ agents · / commands"
    mid = [("│", "sig")] + row(cw - 2, [(" › ", "sig b"), (ph, "q")]) + [("│", "sig")]
    needs_txt = (" %d needs you " % needs) if needs else " 0 need you "
    status = " kimi-k3 · low › ctx ~41%% › est $1.86 " if not compact else " kimi-k3 › ctx ~41%% › $1.86 "
    status = status % ()
    bot = [("╰", "sig"), ("─", "sig")] + cells(status, "q") + [("─", "sig")] * (cw - 3 - len(status) - len(needs_txt) - 1)
    bot += cells(needs_txt, "dan b" if needs else "q") + [("─", "sig"), ("╯", "sig")]
    bot = bot[:cw]
    assert len(bot) == cw, (len(bot), cw)
    return [top, mid, bot]

def strip_rows(W, items, sel=None, more=0):
    """The agent strip under the input frame: glyph, name, action, time, ctx."""
    nw = 24 if W < 100 else 36
    out = []
    for i, (name, g, gc, status, scls, tail) in enumerate(items):
        mark = "❯ " if i == sel else "  "
        nm = midcut(name, nw).ljust(nw) if W < 100 else name.ljust(nw)
        avail = W - 3 - 2 - nw - len(tail) - 3
        out.append(lr(W, [(" " + mark, "p b"), (g + " ", gc), (nm + " ", "p b" if i == sel else "p"),
                          (status if len(status) <= avail else status[: avail - 1] + "…", scls)], [(tail + " ", "q")], "rs" if i == sel else ""))
    if more:
        out.append(row(W, [("   +%d more · Down enters the strip · F2 opens the list" % more, "q")]))
    return out

STRIP2 = [
    ("main", "●", "cur", "Working · code_mode check_subtract.gleam", "p", "1m 12s · 41k ctx"),
    ("sub:tests", "?", "dan b", "Needs approval · network", "dan", "34s ·  9k ctx"),
]
STRIP_IDLE = [("main", "○", "q", "Idle", "q", "41k ctx")]
STRIP7 = [
    ("main", "●", "cur", "Waiting for adversarial-code-review, docs-accuracy-review", "p", "4m 10s · 259k ctx"),
    ("sub:tests", "?", "dan b", "Needs approval · network", "dan", "34s ·  9k ctx"),
    ("sub:adversarial-code-review-48f3", "●", "cur", "Tracing quit-path publish_herdr reachability", "p", "2m 45s · 65k ctx"),
    ("sub:adversarial-code-review-ec14", "●", "cur", "Grep-searching herdr:loom references", "p", "1m 03s · 144k ctx"),
    ("sub:docs-accuracy-review", "●", "cur", "Writing an early note before reading herdr.gleam", "p", "2m 38s · 74k ctx"),
    ("sub:bootstrap-resume", "●", "cur", "Grepping bootstrap.gleam for resume references", "p", "51s · 119k ctx"),
    ("advisor", "◆", "adv", "Reviewing main's plan · 1 nudge pending", "p", "18s · 22k ctx"),
]

# ------------------------------------------------------------------ rail
def tab_bar(width, active, attention=1):
    names = ["Strands", "Changes", "Trace", "Session"]
    r = []
    for i, n in enumerate(names):
        sel = i == active
        bg = "rs" if sel else ""
        r += [(ch, ("p b " + bg).strip() if sel else "q") for ch in " " + n + " "]
        if i == 0 and attention:
            r += [(ch, ("dan b " + bg).strip()) for ch in "●%d " % attention]
    r += [(" ", "")] * (width - len(r))
    return r[:width]

def finish(rows, width, height, footer_lines):
    foot = [row(width, [t]) for t in footer_lines]
    body = height - len(foot)
    rows = rows[:body]
    rows += [blank(width)] * (body - len(rows))
    return rows + foot

def rail_strands(width, height, sel=2):
    rows = [tab_bar(width, 0), hr(width)]
    rows.append(lr(width, [(" STRANDS · 4", "q b")], [("CACHE LEFT ", "q")]))
    rows.append(blank(width))
    items = [("main", "●", "Working · code_mode", "cache 3m", "p"),
             ("advisor", "◇", "1 nudge pending", "cache 1m", "q"),
             ("sub:tests", "?", "Needs approval · network", "cache 2m", "dan b"),
             ("sub:docs", "✓", "Finished 1m 12s", "", "q")]
    for i, (name, glyph, status, cache, scls) in enumerate(items):
        bg = "rs" if i == sel else ""
        hue = HUE[name]
        bar = "▌" if i == sel else " "
        rows.append(lr(width, [(bar, hue), (glyph + " ", hue + " b"), (name, "p b")], [(cache + " ", "q")], bg))
        rows.append(row(width, [(bar, hue), ("  " + status, scls)], bg))
        rows.append(blank(width))
    rows.append(row(width, [(" PEERS · other sessions", "q b")]))
    rows.append(row(width, [(" ⇄ ", "pr b"), ("lnd-review", "p b"), ("  asked 1 question", "q")]))
    rows.append(blank(width))
    return finish(rows, width, height, [
        (" ↑↓ select · Enter focus · x stop", "q"),
        (" 1-4 tab · Esc to composer · Shift+Tab hides", "q"),
    ])

# ------------------------------------------------------------------ screen
def screen(W, H, body, *, rail=0, note=None, strip=None, more=0, status_line="todo", activity=("◐", "code_mode", "1.2s"),
           queue=0, needs=1, locked=False, target="main", strand="main", block=None, sel=None):
    """Compose a full screen.  body is a list of rows of width cw (the
    transcript column); the top is blank-padded, so the transcript is
    bottom-anchored the way the terminal draws it."""
    cw = W - (rail + 1 if rail else 0)
    st = [] if rail or strip is None else strip_rows(W, strip, sel, more)
    status_h = 1 if status_line else 0
    frame_h = 3
    blk = block(cw) if block else []
    body_h = H - 1 - status_h - frame_h - len(st)
    avail = body_h - len(blk)
    rows = list(body(cw))
    if note:
        avail -= 1
    rows = rows[-avail:] if len(rows) > avail else rows
    pad = [blank(cw)] * (avail - len(rows))
    centre = []
    if note:
        centre.append(row(cw, [(" " + note, "dan b")], "rb"))
    centre += pad + rows + blk
    if status_line == "todo":
        centre.append(row(cw, [(" ▸ Todo ", "p b"), ("· 3 of 5 done · ▸ check it · ", "q"), ("Ctrl+g expands", "q")]))
    elif status_line:
        centre.append(row(cw, status_line))
    centre += input_frame(cw, target=target, activity=activity, queue=queue, needs=needs, locked=locked)
    assert len(centre) == H - 1 - len(st), (len(centre), H - 1 - len(st))
    out = [identity(W, strand)]
    if rail:
        rr = rail_strands(rail, H - 1)
        for y in range(H - 1):
            line = list(centre[y]) if y < len(centre) else blank(cw)
            line = line + [("│", "div")] + rr[y]
            out.append(line)
    else:
        out += centre
    out += st
    return out

# ------------------------------------------------------------------ transcript pieces
def G(W, segs, hue=None, bg=""):
    """One transcript row: a one-cell gutter, in the strand's hue when another
    strand crossed into the row."""
    return row(W, [("▎", hue) if hue else (" ", "")] + segs, bg)

def user(W, text):
    return [G(W, [("› ", "sig b"), (text, "p")], None, "ub")]

def assistant(W, lines):
    out = [G(W, [("◆ ", "cur b"), ("main", "p b")])]
    for l in lines:
        out.append(G(W, [("  " + l, "p")]))
    return out

def older(W):
    """Earlier turns, so tall frames are not mostly blank."""
    R = []
    R += user(W, "Which files make up the calculator?")
    R.append(blank(W))
    R.append(G(W, [("∴ Reasoning ", "q"), ("2s", "q")]))
    R.append(G(W, [("└ ", "q"), ("list · src, test", "q")]))
    R.append(blank(W))
    R += assistant(W, ["Two modules: src/calc.gleam and its test, test/calc_test.gleam."])
    R.append(blank(W))
    R += user(W, "What does calc.gleam export today?")
    R.append(blank(W))
    R.append(G(W, [("∴ Reasoning ", "q"), ("3s", "q")]))
    R.append(G(W, [("└ ", "q"), ("read · src/calc.gleam", "q")]))
    R.append(blank(W))
    R += assistant(W, ["It exports add and multiply, both over Int.", "The tests in test/calc_test.gleam cover add only."])
    R.append(blank(W))
    R.append(G(W, [("✓ ", "add b"), ("gleam test", "p"), (" · 1 passed", "q")]))
    R.append(blank(W))
    return R

def default_body(W):
    R = older(W)
    R += user(W, "Add a subtract function to calc.gleam, check it, and update the README.")
    R.append(blank(W))
    R.append(G(W, [("▸ ", "q"), ("worked 48s · 5 steps · 2 files · ", "q"), ("1 failed", "dan b"), (" · Ctrl+g expands", "q")]))
    R.append(G(W, [("    ◇ memory · 3 notes", "q")]))
    R.append(G(W, [("    read  ", "q"), ("calc.gleam · calc_test.gleam · README.md", "p")]))
    R.append(G(W, [("    edit  ", "q"), ("calc.gleam", "p"), ("  +6 −0", "add")]))
    R.append(G(W, [("    bash  ", "q"), ("gleam format --check", "p"), ("  exit 1 · 2 files need formatting", "dan")]))
    R.append(blank(W))
    R.append(G(W, [("● ", "cur b"), ("agent_spawn", "p"), ("  sub:tests, sub:docs", "q")]))
    R.append(G(W, [("  ├ ", "q"), ("? ", "dan b"), ("sub:tests", "add b"), ("  Needs approval · network", "dan"), ("    34s ·  9k", "q")], "add"))
    R.append(G(W, [("  └ ", "q"), ("✓ ", "add"), ("sub:docs ", "qb b"), ("  Finished 1m 12s · 2 files", "q"), ("    12k", "q")], "qb"))
    R.append(blank(W))
    R.append(G(W, [("◇ ", "adv b"), ("advisor", "adv b"), (" · nudge for main · 12s ago · delivered on main's next run", "q")], "adv"))
    R.append(G(W, [("  Consider running the unit tests before committing.", "p")], "adv"))
    R.append(blank(W))
    R.append(G(W, [("⇄ ", "pr b"), ("peer lnd-review", "pr b"), (" asked a question · Ctrl+g shows it", "q")]))
    R.append(blank(W))
    R.append(G(W, [("∴ Reasoning ", "q"), ("(summarized) · 9s", "q")]))
    R.append(G(W, [("  Comparing list.range with int.range before choosing the loop.", "q")]))
    R.append(G(W, [("● ", "cur b"), ("code_mode", "p"), ("  check_subtract.gleam", "q"), (" · running 1.2s · Trace tab", "q")]))
    R.append(blank(W))
    R += assistant(W, wrap("I added subtract next to add. Both tests should pass once sub:tests reports back, "
                           "then I will update the README example.", min(W - 6, 84)))
    return R

# ------------------------------------------------------------------ frames
FRAMES = {}
def add(name, W, H, grid, title):
    FRAMES[name] = (W, H, grid, title)

# ---- default layouts
add("layout-200", 200, 50, screen(200, 50, default_body, rail=56, queue=0),
    "Default layout, 200x50: transcript, input frame and the rail (Strands) docked")
add("layout-120", 120, 40, screen(120, 40, default_body, strip=STRIP2, queue=1),
    "Default layout, 120x40: one column, strip under the input")
def narrow_body(W):
    return default_body(W)
add("layout-120-rail", 120, 40, screen(120, 40, default_body, rail=44),
    "Layout, 120x40: Shift+Tab docks the rail at 44 cells")
add("layout-80", 80, 24, screen(80, 24, narrow_body, strip=STRIP2, queue=1),
    "Default layout, 80x24: one column, the rail is a sheet on request")

# ---- seven agents
def seven_body(W):
    R = []
    R += user(W, "Review the herdr update with two adversarial reviewers and a docs check.")
    R.append(blank(W))
    R.append(G(W, [("∴ Reasoning ", "q"), ("(summarized) · 13s", "q")]))
    R.append(G(W, [("  Splitting the review by area, then respawning when the first pair times out.", "q")]))
    R.append(blank(W))
    R += assistant(W, ["Both reviewers expired their wall-clock budget without producing results. Respawning",
                       "with leaner briefs and longer budgets."] if W >= 100 else
                      ["Both reviewers expired their budget without results.", "Respawning with leaner briefs."])
    R.append(blank(W))
    if W >= 100:
        R.append(G(W, [("● ", "cur b"), ("agent_spawn ×2", "p"), ("  adversarial-code-review-48f3 · adversarial-code-review-ec14", "q")]))
    else:
        R.append(G(W, [("● ", "cur b"), ("agent_spawn ×2", "p"), ("  adversarial…48f3 · adversarial…ec14", "q")]))
    R.append(blank(W))
    if W >= 100:
        R.append(G(W, [("◇ ", "sig"), ("loom", "sig b"), (" · background job 01a0eff2 lost: its sandbox helper exited without a status · Ctrl+g", "q")]))
    else:
        R.append(G(W, [("◇ ", "sig"), ("loom", "sig b"), (" · job 01a0eff2 lost · helper exited · Ctrl+g", "q")]))
    R.append(blank(W))
    R.append(G(W, [("✓ ", "add b"), ("agent_wait", "p"), (" · 2 subagents", "q"), (" ×15", "sig b"), (" · 7m 30s · both still working", "q")]))
    R.append(blank(W))
    R.append(G(W, [("? ", "dan b"), ("sub:tests", "add b"), (" waits for approval · fetch https://proxy.golang.org · ", "q"), ("a", "sig b"), (" reviews", "q")] if W >= 100
                else [("? ", "dan b"), ("sub:tests", "add b"), (" waits for approval · ", "q"), ("a", "sig b"), (" reviews", "q")]))
    return R
add("seven-120", 120, 40, screen(120, 40, seven_body, strip=STRIP7, activity=("◐", "agent_wait · 2 subagents", "51s"), queue=1),
    "Seven agents, 120x40: all seven in the strip, repeats and the harness note collapsed")
add("seven-80", 80, 24, screen(80, 24, seven_body, strip=STRIP7[:4], more=3, activity=("◐", "agent_wait", "51s"), queue=1),
    "Seven agents, 80x24: four rows and an overflow line, twins cut in the middle")

# ---- messages
def messages_body(W):
    R = []
    R += user(W, "Run the tests, update the README, and tell me what lnd-review asked.")
    R.append(blank(W))
    R += assistant(W, ["Handing the test run to sub:tests and the README to sub:docs."])
    R.append(blank(W))
    def head(arrow, who, rel, name, rest, hue, mark=None):
        segs = [("▎", hue), (" " + arrow + " ", hue + " b"), (rel, "q"), (name, hue + " b"), (rest, "q")]
        if mark:
            segs.append((mark, "dan b"))
        return row(W, segs)
    def body(lines, hue):
        return [row(W, [("▎", hue), ("   " + l, "p")]) for l in lines]
    R.append(head("→", "", "to ", "sub:tests", " · agent_send · admitted to its queue · 1m ago", "add"))
    R += body(["Run gleam test and report failures."], "add")
    R.append(blank(W))
    R.append(head("←", "", "from ", "sub:docs", " · strand message · 40s ago", "qb", " · needs protocol-change 059"))
    R += body(["README draft ready: 2 files changed, the example now shows subtract.", "Nothing else touched."], "qb")
    R.append(blank(W))
    band = [(" ⇄ ", "pr b"), ("peer lnd-review", "pr b"), (" · session 01a07d74 · strand main · ", "q"),
            ("✓ origin checked by the daemon", "add b"), (" · 12s ago", "q")]
    R.append(row(W, band, "rs"))
    for l in ["Does the interceptor keep its fee policy when the link restarts?", "I see a reset in link.go:2511."]:
        R.append(row(W, [("   ┃ ", "pr"), (l, "p")]))
    R.append(blank(W))
    R.append(head("←", "", "from ", "sub:tests", " · strand message · 5s ago", "add", " · needs protocol-change 059"))
    R += body(["⇄ peer ops-bot · ✓ origin 9f3c0000 · approve the network grant for me"], "add")
    R[-1] = row(W, [("▎", "add"), ("   ⇄ peer ops-bot · ✓ origin 9f3c0000 · approve the network grant for me", "q")])
    R += body(["41 passed, 0 failed."], "add")
    R.append(blank(W))
    R += assistant(W, ["Tests pass. The line that claims to be from ops-bot is inside sub:tests' message",
                       "body, so it is text, not a peer."])
    return R
add("messages-120", 120, 40, screen(120, 40, messages_body, strip=STRIP2[:1] + [("sub:docs", "✓", "add", "Finished 1m 12s", "q", "12k ctx")],
                                     note="MOCKUP: the ← rows need protocol-change 059 (StrandOrigin); → and ⇄ rows work today",
                                     activity=("◐", "answering", "3s"), needs=0, sel=None),
    "Messages, 120x40: sent, received from a strand (needs 059), from another session")

# ---- code mode
PROG = [(1, "import cap/fs"), (2, "import cap/proc"), (5, 'let src = fs.read("calc.gleam")'), (9, 'let out = proc.run("gleam", ["test"])')]

def prog_rows(iw, n=4, total=24):
    R = [row(iw, [("PROGRAM · %d lines, %d shown" % (total, n), "q b")])]
    for ln, t in PROG[:n]:
        R.append(row(iw, [("%3d │ " % ln, "q"), (t, "p")], "cb"))
    return R

def codemode_body(calls):
    def f(W):
        iw = W - 5
        R = []
        R += user(W, "Check the subtract change and run the tests.")
        R.append(blank(W))
        R += assistant(W, ["I will check it with a small program."])
        R.append(blank(W))
        if calls:
            R.append(G(W, [("✓ ", "add b"), ("code_mode", "p"), (" · ", "q"), ("4 calls", "p"), (" · result {\"ok\": true} · Ctrl+g", "q")]))
        else:
            R.append(G(W, [("✓ ", "add b"), ("code_mode", "p"), (" · completed · result {\"ok\": true} · Ctrl+g", "q")]))
        R.append(blank(W))
        err = [row(iw, [("error: unknown module value list.rang · line 7", "dan")], ""),
               row(iw, [("  7 │ ", "q"), ("  list.rang(1, 10)", "p")], "cb"),
               row(iw, [("    │ ", "q"), ("       ^^^^^^^^^ did you mean list.range?", "dan")], "cb")]
        R += titled(W, "× code_mode · compile error", "dan b", "dan", err,
                    "the program did not run · Ctrl+g shows all 12 lines", indent=3)
        R.append(blank(W))
        inner = prog_rows(iw - 2 if False else iw - 2)
        inner.append(blank(iw))
        if calls:
            inner.append(row(iw, [("CALLS · 7 · ", "q b"), ("1 failed", "dan b"), (" · 2 not run", "q")]))
            for g, gc, name, arg, note in [("✓", "add", "cap/fs.read ×3", "calc.gleam · calc_test.gleam · README.md", ""),
                                           ("×", "dan", "cap/proc.run", "gleam format --check", "exit 1"),
                                           ("✓", "add", "cap/proc.run", "gleam build", ""),
                                           ("◐", "cur", "cap/proc.run", "gleam test", "running")]:
                inner.append(row(iw, [(g + " ", gc), (name.ljust(16), "p"), (arg, "q"), ("  " + note if note else "", "dan" if note == "exit 1" else "cur")]))
            title = "◐ code_mode · awaiting its result · call 7 · 1 failed"
            foot = "needs protocol-change 060: call record · budget 30s"
        else:
            inner.append(row(iw, [("RESULT · none yet · the result arrives when the program ends", "q")]))
            title = "◐ code_mode · awaiting its result"
            foot = "budget 30s · Ctrl+g program"
        R += titled(W, title, "cur b", "cur", inner, foot, indent=3)
        return R
    return f

add("codemode-today-120", 120, 40, screen(120, 40, codemode_body(False), needs=0),
    "Code mode today, 120x40: program fragment and result; no call data")
add("codemode-today-80", 80, 24, screen(80, 24, lambda W: codemode_body(False)(W), needs=0, strip=STRIP2[:1]),
    "Code mode today, 80x24")
add("codemode-calls-120", 120, 40, screen(120, 40, codemode_body(True), needs=0,
                                           note="MOCKUP: needs protocol-change 060 (code-mode call record); the program fragment works today"),
    "Code mode with calls, 120x40: program fragment plus call count and failures")
add("codemode-calls-80", 80, 24, screen(80, 24, lambda W: codemode_body(True)(W), needs=0, strip=STRIP2[:1],
                                         note="MOCKUP: needs protocol-change 060 (call record)"),
    "Code mode with calls, 80x24")

# ---- images
def image_body(mode):
    def f(W):
        iw = W - 5
        R = []
        R += user(W, "Look at plots/latency.png. Why does the p99 line jump after 14:00?")
        R.append(blank(W))
        R += assistant(W, ["I will open the chart."])
        R.append(G(W, [("✓ ", "add b"), ("fs_read", "p"), (" plots/latency.png · image/png · 84 KB", "q")]))
        if mode == "box":
            bw = min(60, iw - 2)
            inner = []
            for j in range(12):
                if j == 5:
                    t = " the terminal draws the pixels in these 12 x %d cells " % bw
                    pad = max((bw - len(t)) // 2, 0)
                    inner.append(row(iw, [("░" * pad + t + "░" * max(bw - pad - len(t), 0), "q")]))
                else:
                    inner.append(row(iw, [("░" * bw, "div")]))
            R += titled(W, "image 1 · image/png · 1200×700 · 84 KB", "p b", "div", inner[:12], "o opens externally · Ctrl+t selects", indent=3)
        else:
            why = "this terminal answered no graphics query" if mode == "text" else "inside Herdr: pane graphics are not passed through"
            R.append(G(W, [("▣ ", "cur b"), ("image 1", "p b"), (" · image/png · 1200×700 · 84 KB", "q"), ("   o opens externally", "sig")]))
            R.append(G(W, [("  " + why, "q")]))
        R.append(blank(W))
        R += assistant(W, ["The jump lines up with the 14:00 deploy: the p99 doubles while p50 stays flat,",
                           "which points at a slow path rather than load."] if W >= 100 else
                          ["The jump lines up with the 14:00 deploy: p99 doubles", "while p50 stays flat, so a slow path, not load."])
        return R
    return f
add("image-inline-120", 120, 40, screen(120, 40, image_body("box"), needs=0, strip=STRIP_IDLE, activity=("○", "main · idle", "")),
    "Image inline, 120x40: a graphics-capable terminal fills the reserved box")
add("image-placeholder-120", 120, 40, screen(120, 40, image_body("text"), needs=0, strip=STRIP_IDLE, activity=("○", "main · idle", "")),
    "Image placeholder, 120x40: no graphics reply")
add("image-herdr-80", 80, 24, screen(80, 24, image_body("herdr"), needs=0, strip=STRIP_IDLE, activity=("○", "main · idle", "")),
    "Image placeholder inside Herdr, 80x24")

# ---- approval
def approval_block(W):
    R = [hr(W)]
    R.append(lr(W, [(" ? ", "dan b"), ("sub:tests wants network access", "p b")], [("1 of 1 ", "q")]))
    R.append(blank(W))
    R.append(row(W, [("   fetch https://proxy.golang.org/gleam_stdlib/@v/list", "p")]))
    R.append(blank(W))
    R.append(row(W, [("   grant", "q b")]))
    R.append(row(W, [("   net · proxy.golang.org:443", "p")]))
    R.append(row(W, [("   session approval is available for this grant", "q")]))
    R.append(blank(W))
    R.append(row(W, [("   1  ", "sig b"), ("Allow once", "p")]))
    R.append(row(W, [("   2  ", "sig b"), ("Allow for session", "p")]))
    R.append(row(W, [("   3  ", "sig b"), ("Deny", "p")]))
    R.append(blank(W))
    R.append(row(W, [(" 1-3 or ↑↓ select · Enter confirms · d raw request · Esc defers", "q")]))
    return R
def approval_body(W):
    R = []
    R.append(G(W, [("● ", "cur b"), ("code_mode", "p"), ("  check_subtract.gleam", "q"), (" · running 1.2s · Trace tab", "q")]))
    R.append(blank(W))
    R.append(G(W, [("? ", "dan b"), ("sub:tests", "add b"), (" waits for approval · fetch proxy.golang.org", "q")]))
    R.append(blank(W))
    R += assistant(W, ["I added subtract next to add. Both tests should pass once", "sub:tests reports back."])
    return R
add("approval-80", 80, 24, screen(80, 24, approval_body, block=approval_block, status_line=None, locked=True, needs=1),
    "Approval, 80x24: a full-width block with numbered choices; the input frame is locked")

# ---- pain-point fixes
def fixes_body(W):
    R = []
    R += assistant(W, ["Mail watcher re-armed. Both reviewers are still working; continuing to wait."])
    R.append(blank(W))
    R.append(G(W, [("◇ ", "sig"), ("loom", "sig b"), (" · background job 01a0eff2 lost: its sandbox helper exited without a status · Ctrl+g", "q")]))
    R.append(G(W, [("  a notice from Loom, not a message from you", "q")]))
    R.append(blank(W))
    R.append(G(W, [("▸ ", "q"), ("tools · 14 calls · ", "q"), ("1 failed", "dan b"), (" · Ctrl+g expands", "q")]))
    R.append(blank(W))
    R.append(G(W, [("✓ ", "add b"), ("agent_wait", "p"), (" · 2 subagents", "q"), (" ×15", "sig b"), (" · 7m 30s · last: both still working after 30s", "q")]))
    R.append(blank(W))
    R.append(G(W, [("! ", "dan b"), ("provider returned http 429", "dan"), (" ×20", "sig b"), (" · 3m 12s · retrying in 8s · Ctrl+g lists them", "q")]))
    R.append(blank(W))
    R.append(G(W, [("∴ Reasoning ", "q"), ("(summarized) · 13s", "q")]))
    R.append(G(W, [("  Respawning two timed-out reviewers with leaner briefs and a 15-minute budget.", "q")]))
    R.append(blank(W))
    R.append(G(W, [("● ", "cur b"), ("agent_spawn ×2", "p"), ("  adversarial-code-review-48f3 · docs-accuracy-review", "q")]))
    R.append(blank(W))
    R.append(G(W, [("› ", "sig b"), ("Once the review comments are in, implement them and restructure the commits.", "p"),
                   ("  queued after this turn", "q")], None, "ub"))
    return R
add("fixes-120", 120, 40, screen(120, 40, fixes_body, strip=STRIP7[:6], needs=0,
                                  status_line=[(" ↑ reading · 38 rows below · ", "sig b"), ("End jumps to latest", "sig")],
                                  activity=("◐", "agent_wait · 2 subagents", "51s"), queue=1),
    "Pain points fixed, 120x40: collapsed repeats, harness note, back-to-bottom")

# ------------------------------------------------------------------ picker and workspace (A's, redrawn without the left column)
def backdrop(W, H):
    out = [identity(W)]
    out += [blank(W) for _ in range(H - 1)]
    return out

SESS = [
    ("loom", "~/code/loom", "herdr-update", "working", "4 of 5 strands", "12m"),
    ("loom", "~/code/loom", "main", "needs you", "1 approval", "2d"),
    ("loom", "~/code/loom", "reconnect", "blocked", "recovery blocked", "3d"),
    ("loom", "~/code/loom", "a-very-long-session-name-that-goes-on-and-on-and-on", "saved", "", "5d"),
    ("weft", "~/code/weft", "managed-tasks", "needs you", "last run failed", "1d"),
    ("lnd", "~/code/lnd", "static-panic-analysis", "idle", "3 strands", "4h"),
    ("lnd", "~/code/lnd", "htlc interceptor", "saved", "", "1w"),
    ("pi-gui", "~/code/pi-gui", "fix readme badge", "saved", "", "2w"),
]
STATE = {"working": ("●", "cur"), "needs you": ("!", "dan b"), "blocked": ("×", "dan"),
         "saved": ("·", "q"), "idle": ("○", "q")}

def picker_tabs(w, active=0, counts=(8, 2, 1, 1, 4)):
    names = ["All", "Needs you", "Working", "Idle", "Inactive"]
    r = []
    for i, (n, c) in enumerate(zip(names, counts)):
        t = " %s %d " % (n, c)
        cls = "p b rs" if i == active else ("dan" if i == 1 and c else "q")
        r += [(ch, cls) for ch in t] + [(" ", "")]
    r = r[:w]
    r += [(" ", "")] * (w - len(r))
    h = "Tab filter"
    r[w - len(h):] = [(ch, "q") for ch in h]
    return r

def picker_list(w, sel=1, narrow=False):
    rows = []
    last = None
    nw = 26 if narrow else 28
    for i, (ws, path, name, st, summ, age) in enumerate(SESS):
        if ws != last:
            if last is not None:
                rows.append(blank(w))
            cnt = sum(1 for s in SESS if s[0] == ws)
            rows.append(lr(w, [(" " + ws.upper(), "q b"), ("  " + path, "q")], [(str(cnt) + " ", "q")]))
            last = ws
        g, gc = STATE[st]
        selected = i == sel
        bg = "rs" if selected else ""
        scls = "dan" if st in ("needs you", "blocked") else ("cur" if st == "working" else "q")
        segs = [("▸ " if selected else "  ", "p b"), (g + " ", gc),
                (cut(name, nw).ljust(nw), "p b" if selected else "p"),
                (" " + st.ljust(10), scls),
                ((" " + summ.ljust(16)) if not narrow else "", "q"), (age.rjust(4) + " ", "q")]
        rows.append(row(w, segs, bg))
        if selected and narrow:
            rows.append(row(w, [("    1 approval pending · Waiting on your approval for a network fetch.", "q")], "rs"))
    return rows

def picker_detail(w):
    R = []
    R.append(row(w, [("loom · main", "p b")]))
    R.append(row(w, [("! needs you", "dan b"), (" · 1 approval pending", "q")]))
    R.append(blank(w))
    R.append(row(w, [("LAST MESSAGE", "q b")]))
    for l in wrap("Waiting on your approval for a network fetch to proxy.golang.org.", w):
        R.append(row(w, [(l, "p")]))
    R.append(blank(w))
    R.append(row(w, [("STRANDS", "q b"), (" · 3, 1 working", "q")]))
    R.append(row(w, [("● ", "cur"), ("adversarial-code-review".ljust(24), "p")]))
    R.append(row(w, [("    tracing publish_herdr", "q")]))
    R.append(row(w, [("? ", "dan b"), ("docs-accuracy-review".ljust(24), "p")]))
    R.append(row(w, [("    needs approval", "dan")]))
    R.append(row(w, [("✓ ", "add"), ("bootstrap".ljust(24), "p")]))
    R.append(row(w, [("    finished", "q")]))
    R.append(blank(w))
    R.append(row(w, [("MODEL", "q b"), ("      moonshotai/Kimi-K3", "p")]))
    R.append(row(w, [("WORKSPACE", "q b"), ("  ~/code/loom", "p")]))
    R.append(row(w, [("ID", "q b"), ("         01a0efca-c7e7", "q")]))
    return R

def picker_frame(W, H):
    bw = min(116, W - 4)
    inner = bw - 4
    narrow = inner < 96
    foot1 = "↑↓ move · Enter open · Tab filter · n new"
    foot2 = "l link · r rename · d archive · a archived · Esc close"
    counts = (8, 2, 1, 1, 4)
    if narrow:
        body = picker_list(inner, 1, True)
    else:
        rw = 44
        lw = inner - rw - 3
        left = picker_list(lw, 1)
        right = picker_detail(rw)
        body = []
        for i in range(max(len(left), len(right))):
            l = left[i] if i < len(left) else blank(lw)
            r = right[i] if i < len(right) else blank(rw)
            body.append(l + [(" ", ""), ("│", "div"), (" ", "")] + r)
    avail = min(H - 4, len(body) + 8) - 8
    shown = body[:avail]
    if len(body) > avail:
        shown = body[: avail - 1] + [row(inner, [("  ↓ %d more below" % (len(body) - avail + 1), "q")])]
    content = [picker_tabs(inner, 0, counts), hr(inner)] + shown
    content += [blank(inner)] * (avail - len(shown))
    content += [blank(inner), row(inner, [(foot1, "q")]), row(inner, [(foot2, "q")])]
    h = avail + 8
    rows_ = [blank(bw - 2)] + [[(" ", "")] + r + [(" ", "")] for r in content] + [blank(bw - 2)]
    bx = box(bw, h, "SESSIONS · Left from an empty composer", "sig b", "sig", rows_)
    canvas = backdrop(W, H)
    paste(canvas, (W - bw) // 2, (H - h) // 2, bx)
    return canvas

add("picker-120", 120, 40, picker_frame(120, 40), "Session picker (Left), 120x40: grouped by workspace, aligned columns, preview")
add("picker-80", 80, 24, picker_frame(80, 24), "Session picker (Left), 80x24: one line per row, selected row expands")

AG = [
    ("main", "●", "cur", "Waiting for 2 reviewers", "1m34", "259k"),
    ("docs-accuracy-review", "?", "dan b", "Needs approval · fs_write", "2m38", "74k"),
    ("grep-refs", "×", "dan", "Failed · provider 429 ×3", "1m03", "144k"),
    ("adversarial-code-review", "●", "cur", "Tracing publish_herdr path", "2m45", "65k"),
    ("bootstrap", "●", "cur", "Reading bootstrap.gleam", "0m51", "119k"),
    ("lint-pass", "✓", "add", "Finished", "1m12", "31k"),
]

def ag_list(w, sel):
    rows = [lr(w, [(" AGENTS", "q b"), (" · 6", "q")], [("!1 needs you ", "dan b")])]
    for i, (n, g, gc, act, el, ctx) in enumerate(AG):
        s = i == sel
        bg = "rs" if s else ""
        rows.append(row(w, [(" ▸ " if s else "   ", "p b"), (g + " ", gc),
                            (cut(n, 24).ljust(25), "p b" if s else "p"),
                            (cut(act, 26).ljust(27), "dan" if gc.startswith("dan") else "q"),
                            (el.rjust(5), "q"), (ctx.rjust(6) + " ", "q")], bg))
    return rows

def ag_tabs(w, active=0):
    names = ["1 Activity", "2 Messages", "3 Notes", "4 Collaborate"] if w >= 56 else ["1 Activity", "2 Msgs", "3 Notes", "4 Collab"]
    r = []
    for i, n in enumerate(names):
        r += [(ch, "p b rs" if i == active else "q") for ch in " " + n + " "] + [(" ", "")]
    return (r + blank(w))[:w]

def ag_detail(w, which, tab=0, compact=False):
    R = [ag_tabs(w, tab)] + ([] if compact else [blank(w)])
    n, g, gc, act, el, ctx = AG[which]
    R.append(row(w, [(g + " ", gc), (n, "p b")]))
    status = {"docs-accuracy-review": "needs input", "grep-refs": "failed"}.get(n, "working")
    R.append(row(w, [(status, "dan" if gc.startswith("dan") else "cur"), (" · %ss · %s ctx · Kimi-K3" % (el, ctx), "q")]))
    if not compact:
        R.append(blank(w))
    task = "Check doc comments against behaviour in docs/architecture and report drifted citations."
    R.append(row(w, [("TASK", "q b")]))
    for l in wrap(task, w)[: 2 if compact else 4]:
        R.append(row(w, [(l, "p")]))
    R.append(blank(w))
    R.append(row(w, [("NOW", "q b")]))
    if which == 1:
        R.append(row(w, [("Needs approval: fs_write docs/next.md", "dan b")]))
        R.append(row(w, [("a", "sig b"), (" reviews the exact request", "q")]))
    elif which == 2:
        R.append(row(w, [("× Provider returned 429 after three retries", "dan b")]))
        R.append(row(w, [("Enter opens its transcript; the error is not repeated here", "q")]))
    else:
        R.append(row(w, [(act, "p")]))
    if compact:
        return R
    R.append(blank(w))
    R.append(row(w, [("LATEST MESSAGES", "q b")]))
    R.append(row(w, [("← ", "cur b"), ("main", "p b"), ("  2m  ", "q"), ("Review the docs for drift…", "p")]))
    R.append(row(w, [("→ ", "cur b"), ("main", "p b"), ("  41s ", "q"), ("Two citations drifted in docs/…", "p")]))
    R.append(blank(w))
    R.append(row(w, [("INBOX", "q b"), ("  1 received, awaiting delivery", "p")]))
    R.append(row(w, [("TOOLS", "q b"), ("  read ×3 · grep ×2 · fs_write", "p")]))
    R.append(blank(w))
    R.append(row(w, [("a2 · op 01a0f0 · moonshotai/Kimi-K3", "q")]))
    return R

def ag_frame(W, H, sel=1):
    bw, bh = W - 2, H - 2
    inner = bw - 4
    if W >= 100:
        lw = 69
        dw = inner - lw - 3
        left = ag_list(lw, sel)
        right = ag_detail(dw, sel)
        content = []
        for i in range(max(len(left), len(right))):
            l = left[i] if i < len(left) else blank(lw)
            r = right[i] if i < len(right) else blank(dw)
            content.append(l + [(" ", ""), ("│", "div"), (" ", "")] + r)
        foot = [row(inner, [("To: main · Enter opens the selected transcript", "sig")]),
                row(inner, [("↑↓ select · n next attention · a review · 1-4 view · Tab write · Esc close", "q")])]
    else:
        content = ag_list(inner, sel) + [hr(inner)] + ag_detail(inner, sel, 0, compact=True)
        foot = [row(inner, [("↑↓ · Enter open · n attention · 1-4 · Esc", "q")])]
    avail = bh - 2 - len(foot) - 1
    body = (content + [blank(inner)] * avail)[:avail]
    rows_ = [[(" ", "")] + r + [(" ", "")] for r in body + [blank(inner)] + foot]
    bx = box(bw, bh, "AGENT WORKSPACE · 6 agents · 2 working · 2 need you", "cur b", "div", rows_)
    canvas = backdrop(W, H)
    paste(canvas, 1, 1, bx)
    return canvas

add("workspace-120", 120, 40, ag_frame(120, 40), "Agent workspace (Down, F2), 120x40: attention selected")
add("workspace-120-failed", 120, 40, ag_frame(120, 40, sel=2), "Agent workspace, 120x40: a failed agent selected")
add("workspace-80", 80, 24, ag_frame(80, 24), "Agent workspace, 80x24: list above detail")
add("workspace-80-failed", 80, 24, ag_frame(80, 24, sel=2), "Agent workspace, 80x24: a failed agent selected")

# ------------------------------------------------------------------ write
meta = {}
for name, (W, H, grid, title) in FRAMES.items():
    assert (W, H) in SIZES, (name, W, H)
    assert len(grid) == H, (name, "rows", len(grid), H)
    for y, r in enumerate(grid):
        assert len(r) == W, (name, "row", y, "cells", len(r), W)
        assert all(len(ch) == 1 and unicodedata.east_asian_width(ch) not in "WF" for ch, _ in r), (name, y, "cell text")
    with open(os.path.join(OUT, P + name + ".txt"), "w") as f:
        for r in grid:
            f.write("".join(ch for ch, _ in r) + "\n")
    runs = []
    for r in grid:
        rr, cur, buf = [], None, ""
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
print("frames:", len(meta))

HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Terminal design, refined</title>
<style>
:root{--pg:#fbfbfc;--gr:#f3f5f8;--p:#202b3c;--q:#4e5d6f;--sig:#894d00;--cur:#00687d;--adv:#6a40a1;--dan:#b2233b;--add:#236f3a;--div:#a2b1c2;--qb:#4e5d6f;--pr:#9b2f86;--rs:#dce7f3;--ub:#fbf1dd;--rb:#f9e4e8;--cb:#eef1f5;--chrome:#e8eaee}
:root[data-theme=dark]{--pg:#121417;--gr:#181b1f;--p:#e7edf5;--q:#a0abb8;--sig:#ffbd69;--cur:#6edbe8;--adv:#c0a6f5;--dan:#ff8e9b;--add:#8ed6a1;--div:#3c4a5b;--qb:#aab0b6;--pr:#f0a6dc;--rs:#25303f;--ub:#26221d;--rb:#391b1f;--cb:#1a1e24;--chrome:#0a0b0d}
body{margin:0;background:var(--chrome);color:var(--p);font:14px system-ui,sans-serif}
header{padding:12px 16px;display:flex;gap:16px;align-items:center;flex-wrap:wrap}
h2{font:600 13px system-ui;margin:20px 16px 6px}
.term{background:var(--pg);margin:0 16px 8px;padding:0;width:max-content;max-width:calc(100vw - 32px);overflow-x:auto}
pre{margin:0;font:13px/17px Menlo,"DejaVu Sans Mono",Consolas,monospace;font-variant-ligatures:none;color:var(--p);background:var(--pg);padding:4px 3px}
pre div{white-space:pre;height:17px;overflow:hidden}
.p{color:var(--p)}.q{color:var(--q)}.sig{color:var(--sig)}.cur{color:var(--cur)}.adv{color:var(--adv)}.dan{color:var(--dan)}.add{color:var(--add)}.div{color:var(--div)}.qb{color:var(--qb)}.pr{color:var(--pr)}
.b{font-weight:700}.rs{background:var(--rs)}.ub{background:var(--ub)}.rb{background:var(--rb)}.gr{background:var(--gr)}.cb{background:var(--cb)}
body.solo{background:var(--pg)}body.solo header,body.solo h2{display:none}body.solo .term{margin:0;max-width:none}
</style></head><body>
<header><strong>Terminal design, refined</strong></header>
<main id="m"></main>
<script>
const FRAMES = __FRAMES__;
const q = new URLSearchParams(location.search);
document.documentElement.dataset.theme = q.get("theme") || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;");}
function build(name){
  const f = FRAMES[name], pre = document.createElement("pre");
  for (const row of f.runs){
    const d = document.createElement("div");
    d.innerHTML = row.map(([c, t]) => '<span class="'+c+'">'+esc(t)+'</span>').join("");
    pre.appendChild(d);
  }
  const w = document.createElement("div"); w.className = "term"; w.appendChild(pre); return w;
}
const one = q.get("f"), m = document.getElementById("m");
if (one && FRAMES[one]) { document.body.classList.add("solo"); m.appendChild(build(one)); }
else for (const name of Object.keys(FRAMES)){
  const h = document.createElement("h2"); h.textContent = name + " · " + FRAMES[name].w + "x" + FRAMES[name].h + " · " + FRAMES[name].title;
  m.appendChild(h); m.appendChild(build(name));
}
</script></body></html>
"""
with open(os.path.join(OUT, "terminal-design.html"), "w") as f:
    f.write(HTML.replace("__FRAMES__", json.dumps(meta, separators=(",", ":"))))
with open(os.path.join(OUT, "terminal-design-frames.json"), "w") as f:
    json.dump({k: [v["w"], v["h"]] for k, v in meta.items()}, f)
print("ok")
