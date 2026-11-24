#!/usr/bin/env python3
"""A scripted Anthropic Messages endpoint for seeding the web view.

`scripts/web_seed/seed.sh` points a throwaway daemon's catalogue at this
server so a session exercises every piece the web view draws without a
live model: a turn that reasons, spawns a reviewer and edits two files, the
reviewer's result, a delivered advisor nudge, a long streaming answer, and
a prompt-cache miss. Each catalogue entry names a different `model_id`
(fake-main, fake-sub, fake-advisor, fake-summarize), which is how a request
says which role is asking. It answers with the streamed events the
`anthropic` adapter reads, including the usage buckets the cache ledger
folds: the first main request writes a 40k prefix with a one-hour head,
later ones read it back, and a prompt that says "after the break" reads
nothing and writes it again, which is a miss once the daemon has sat idle
for more than a minute.

Usage: fake_anthropic.py PORT
"""

import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NUDGED = threading.Event()

# A real streamed response for the Mermaid browser drive. The third fence
# deliberately fails, so a blank diagram cannot pass as a successful view.
MERMAID_ANSWER = '''## Mermaid diagrams

```mermaid
flowchart LR
    A[Request approval] --> B{Decision}
    B -->|Allow| C[Wake strand]
    B -->|Deny| D[Keep source]
```

```mermaid
sequenceDiagram
    participant M as Strand
    participant G as Gateway
    participant N as Notice
    M->>G: Request permission
    G->>N: Approval recorded
    N-->>M: Resume work
```

```mermaid
this is deliberately not a diagram
```

The source stays available when a diagram cannot be rendered.
'''

# The ask the fake main puts to the owner when a prompt says "ask me first": a
# choice with three options (one recommended, each with a note) and a confirm.
# The call ends the turn, so the session then waits on the owner's answer.
ASK_QUESTIONS = [
    {
        "prompt": "Closed items: fold under open ones, or a separate Done list?",
        "kind": "choice",
        "options": [
            {"label": "Fold under open", "note": "Matches the Inbox plugin and keeps context.", "recommended": True},
            {"label": "Separate Done list", "note": "Closed work leaves the list at once."},
            {"label": "Hide after 24h", "note": "Closed items stay a day, then drop out."},
        ],
    },
    {"prompt": "Keep the parts of the work that do not depend on it moving?", "kind": "confirm"},
]

# Asks that cover every answer kind, four questions at most per ask. The
# first set is confirm, choice, multiple choice and checklist; the second is
# the fill-in kinds. An Other answer is typed on any of the first set.
ASK_KINDS_ONE = [
    {"prompt": "Keep the retry fix in this change?", "kind": "confirm"},
    {"prompt": "Which retry policy?", "kind": "choice", "options": [
        {"label": "Fixed delay", "note": "Simple and predictable.", "recommended": True},
        {"label": "Exponential backoff", "note": "Gentler on a failing service."},
        {"label": "No retry", "note": "Surface the error at once."}]},
    {"prompt": "Which files may I touch?", "kind": "multiple", "min": 1, "max": 2, "options": [
        {"label": "src/a.gleam"}, {"label": "src/b.gleam"}, {"label": "test/a_test.gleam"}]},
    {"prompt": "Which checks should run?", "kind": "checklist", "options": [
        {"label": "format"}, {"label": "lint"}, {"label": "unit tests"}]},
]
ASK_KINDS_TWO = [
    {"prompt": "What should the branch be called?", "kind": "fill", "format": "text"},
    {"prompt": "How many retries?", "kind": "fill", "format": "number"},
    {"prompt": "Where is the tracking issue?", "kind": "fill", "format": "url"},
    {"prompt": "Which file holds the policy?", "kind": "fill", "format": "path"},
]

# The program a code_mode call submits: it asks two questions and records a
# notice, through the same capabilities the ask and notice tools back.
CODE_MODE_PROGRAM = """import cap/attention
import cap/report
import gleam/option.{None, Some}

pub fn main() -> report.Outcome {
  let questions = [
    attention.confirm("Should the program's retry change ship?"),
    attention.choose("Which cache does the program prefer?", [
      attention.alternative("Scratch tmpfs"),
      attention.alternative("Empty dir"),
    ]),
  ]
  case attention.ask(questions, to: None, why: Some("A program needs a decision.")) {
    Error(error) -> report.failure(attention.error_text(error))
    Ok(ask_id) ->
      case
        attention.notice(
          attention.Bug,
          "The program saw no backoff in the retry loop.",
          path: Some("src/a.gleam"),
          line: Some(1),
        )
      {
        Error(error) -> report.failure(attention.error_text(error))
        Ok(notice_id) -> report.text("asked " <> ask_id <> ", noticed " <> notice_id)
      }
  }
}
"""

# Many small diagrams in one answer, for measuring what each diagram's own
# renderer frame costs. Send "mermaid many" to get it.
MERMAID_MANY_ANSWER = "## Many diagrams\n\n" + "\n".join(
    f"```mermaid\nflowchart LR\n    A{n}[Step {n}] --> B{n}{{Check {n}}}\n"
    f"    B{n} -->|yes| C{n}[Done {n}]\n    B{n} -->|no| A{n}\n```\n"
    for n in range(24)
)



# An answer in the shape agents write: bold, a list whose items name worktrees
# with relative links, a code span and a link that is an address.
STATUS_REPORT = "\n".join(
    [
        "**Neither is committed, pushed, or in a PR.**",
        "",
        "- **Native RPC mTLS** is in [`.worktrees/native-rpc-mtls`](.worktrees/native-rpc-mtls) and waits on `make check`.",
        "- **Inbox markdown** is in [`.worktrees/inbox-md`](.worktrees/inbox-md), tests green.",
        "- **Docs** are at [the guide](https://example.com/guide).",
        "",
        "Next I will run `make doc-check`, then ask you before anything is pushed.",
    ]
)


def text_of(content):
    """The text of a message's content, blocks joined."""
    if isinstance(content, str):
        return content
    parts = []
    for block in content:
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
        elif block.get("type") == "tool_result":
            parts.append(text_of(block.get("content", "")))
    return "\n".join(parts)


def tool_results(message):
    content = message.get("content", [])
    if isinstance(content, str):
        return []
    return [b for b in content if b.get("type") == "tool_result"]


def called(messages, tool_use_id):
    """The name of the tool call a result answers."""
    for message in messages:
        if message.get("role") != "assistant" or isinstance(message.get("content"), str):
            continue
        for block in message["content"]:
            if block.get("type") == "tool_use" and block.get("id") == tool_use_id:
                return block.get("name")
    return None


def usage(input_tokens, read, write, hour):
    return {
        "input_tokens": input_tokens,
        "output_tokens": 1,
        "cache_read_input_tokens": read,
        "cache_creation_input_tokens": write,
        "cache_creation": {"ephemeral_1h_input_tokens": hour, "ephemeral_5m_input_tokens": write - hour},
    }


def main_turn(messages):
    """What the primary does next: a list of blocks, a stop reason, usage."""
    last = messages[-1]
    results = tool_results(last)
    warm = usage(1400, 40000, 600, 600)
    if results:
        names = {called(messages, r.get("tool_use_id")) for r in results}
        if names & {"bash", "code_mode", "notice", "fs_write"} and "agent_spawn" not in names:
            sys.stderr.write("fake-main tool result: %s\n" % json.dumps(text_of(last.get("content", ""))[:600]))
            return [("text", "Finished that step.")], "end_turn", warm
        if "fs_read" in names:
            return [("text", "The check failed: the fold-order test file is missing.")], "end_turn", warm
        if "agent_spawn" in names:
            spawned = next(r for r in results if called(messages, r.get("tool_use_id")) == "agent_spawn")
            handle = re.search(r"Handle: (\S+)", text_of(spawned.get("content", "")))
            handles = [handle.group(1).rstrip(".")] if handle else []
            return [("tool_use", "agent_wait", {"handles": handles, "within_ms": 120000})], "tool_use", warm
        answer = "\n".join(
            [
                "**Done.** The reviewer read both files and found nothing that blocks the patch.",
                "",
                "What changed:",
                "- [`notes/review.md`](notes/review.md) records the reviewer's brief and what it checked.",
                "- [`notes/plan.md`](notes/plan.md) lists the follow-ups: tighten the census and rerun the lint.",
                "",
                "The reviewer's one nit was the ordering of two imports in b.gleam, which "
                "the formatter settles on the next run. I left it for that pass rather than "
                "hand-editing a generated order.",
            ]
            + ["Line %d of a long answer, streamed a few words at a time." % n for n in range(1, 25)]
        )
        return [("text", answer)], "end_turn", warm
    said = text_of(last.get("content", ""))
    lowered = said.lower()
    if "need network" in lowered:
        # A bash call that asks for full network while the jail's network is
        # off, so the daemon records an escalation and waits for a decision.
        return (
            [("tool_use", "bash", {"command": "echo network-check-ran", "permissions": {"network": "full"}})],
            "tool_use",
            warm,
        )
    if "ask kinds one" in lowered:
        NUDGED.set()
        return [("tool_use", "ask", {"questions": ASK_KINDS_ONE, "why": "Four kinds in one ask."})], "tool_use", warm
    if "ask kinds two" in lowered:
        NUDGED.set()
        return [("tool_use", "ask", {"questions": ASK_KINDS_TWO, "why": "The fill-in kinds."})], "tool_use", warm
    if "post a notice" in lowered:
        return (
            [
                ("text", "Noting something I saw."),
                ("tool_use", "notice", {"kind": "risk", "text": "The retry loop has no backoff and can hammer the service.", "path": "src/a.gleam", "line": 1}),
            ],
            "tool_use",
            warm,
        )
    if "make changes" in lowered:
        return (
            [
                ("tool_use", "fs_write", {"path": "src/a.gleam", "content": "pub fn main() { retry(3) }\n\npub fn retry(n: Int) -> Int {\n  case n {\n    0 -> 0\n    _ -> retry(n - 1)\n  }\n}\n"}),
                ("tool_use", "fs_write", {"path": "test/a_test.gleam", "content": "pub fn retry_test() {\n  assert retry(3) == 0\n}\n"}),
            ],
            "tool_use",
            warm,
        )
    if "work slowly" in lowered:
        return [("tool_use", "bash", {"command": "sleep 45; echo slow-done"})], "tool_use", warm
    if "code mode ask" in lowered:
        NUDGED.set()
        return [("tool_use", "code_mode", {"program": CODE_MODE_PROGRAM})], "tool_use", warm
    if "ask me first" in said.lower():
        # The advisor stays quiet, so its nudge cannot wake the strand that is
        # meant to be waiting on the owner.
        NUDGED.set()
        return (
            [
                ("text", "Before I go further I need one call from you."),
                ("tool_use", "ask", {"questions": ASK_QUESTIONS, "why": "The fold order decides what I build next."}),
            ],
            "tool_use",
            warm,
        )
    if "fail the check" in said.lower():
        # Two reads of a file that does not exist: the turn's divider counts
        # two failed steps, and the rail's failed-turn card names the last.
        return (
            [
                ("tool_use", "fs_read", {"path": "src/fold_order_test.gleam"}),
                ("tool_use", "fs_read", {"path": "src/missing_fold_order_test.gleam"}),
            ],
            "tool_use",
            warm,
        )
    if "go stuck" in said.lower():
        # A sub-agent whose provider refuses the request outright, so its strand stops on a
        # failed run and the inbox draws a stuck thread for it.
        return (
            [("tool_use", "agent_spawn", {"purpose": "price the meter", "brief": "rate limit: price the meter"})],
            "tool_use",
            warm,
        )
    if "mermaid many" in said.lower():
        return [("text", MERMAID_MANY_ANSWER)], "end_turn", warm
    if "mermaid" in said.lower():
        return [("text", MERMAID_ANSWER)], "end_turn", warm
    if "advisor-nudges" in said or "[advisor nudges]" in said:
        return [("text", "Checked: the sweep leaves the generated SQL alone.\n\n" + STATUS_REPORT)], "end_turn", warm
    if "after the break" in said:
        return [("text", "Back after the break. The prefix had to be read again.")], "end_turn", usage(1500, 0, 41000, 30000)
    if "review" in said and "child runs" not in said:
        return (
            [
                ("thinking", "Plan the review: spawn a reviewer for the patch, write the notes, then wait."),
                ("tool_use", "agent_spawn", {"purpose": "review the patch", "brief": "Review the patch in src and report anything that blocks it."}),
                ("tool_use", "fs_write", {"path": "notes/review.md", "content": "# Review\n\nThe reviewer checks src.\n"}),
                ("tool_use", "fs_write", {"path": "notes/plan.md", "content": "# Plan\n\n- tighten the census\n- rerun the lint\n"}),
            ],
            "tool_use",
            usage(1800, 0, 40000, 30000),
        )
    return [("text", "Noted: " + said.strip().splitlines()[-1][:120])], "end_turn", warm


def tool_names(body):
    return {t.get("name") for t in body.get("tools", [])}


def router_turn(body, messages):
    """The project router accepts the first candidate it is offered."""
    last = messages[-1]
    if tool_results(last):
        sys.stderr.write("fake-router route result: %s\n" % json.dumps(text_of(last.get("content", ""))[:400]))
        return [("text", "Routed.")], "end_turn", usage(500, 0, 0, 0)
    said = text_of(last.get("content", ""))
    found = re.findall(r'"trigger":"([^"]+)"', said)
    sys.stderr.write("fake-router offer: %s\n" % json.dumps(said[:1500]))
    trigger = found[0] if found else "unknown"
    return (
        [("tool_use", "route", {"items": [{"trigger": trigger, "action": "accept", "title": "Fix the retry loop"}]})],
        "tool_use",
        usage(500, 0, 0, 0),
    )


def worker_commit_turn(messages):
    """A worker that commits a file and reports waiting with no question.

    The project's check rejects the commit and the host hands the worker the
    failure, which is a new user message after the worker's first report. The
    worker reports waiting again, and that second report is what leaves the
    ticket at person/check: a failed check counts as handled only until the
    worker reports again.
    """
    last = messages[-1]
    results = tool_results(last)
    names = {called(messages, r.get("tool_use_id")) for r in results}
    waiting = ("tool_use", "project_report", {"status": "waiting"})
    if "project_report" in names:
        return [("text", "Waiting for a person.")], "end_turn", usage(500, 0, 0, 0)
    if "bash" in names:
        return [waiting], "tool_use", usage(500, 0, 0, 0)
    committed = any(
        block.get("type") == "tool_use" and block.get("name") == "bash"
        for message in messages
        if message.get("role") == "assistant" and not isinstance(message.get("content"), str)
        for block in message["content"]
    )
    sys.stderr.write("fake-worker commit-mode message: %s\n" % json.dumps(text_of(last.get("content", ""))[:800]))
    if committed:
        return [waiting], "tool_use", usage(500, 0, 0, 0)
    command = (
        "printf 'retry log\\n' > retry.log && git add retry.log && "
        "git -c user.name=worker -c user.email=worker@example.com commit -qm 'Add a retry log'"
    )
    return [("tool_use", "bash", {"command": command})], "tool_use", usage(500, 0, 0, 0)


def worker_turn(body, messages):
    """A project worker asks a question and stops, which leaves its ticket at person/answer."""
    if "commit then wait" in json.dumps(messages):
        return worker_commit_turn(messages)
    last = messages[-1]
    if tool_results(last):
        return [("text", "Waiting for the answer.")], "end_turn", usage(500, 0, 0, 0)
    said = text_of(last.get("content", ""))
    sys.stderr.write("fake-worker message: %s\n" % json.dumps(said[:800]))
    return (
        [("tool_use", "project_report", {"status": "waiting", "question": "Which database should the retry log use?"})],
        "tool_use",
        usage(500, 0, 0, 0),
    )


def sub_turn(messages):
    """The reviewer takes its time, then reports."""
    time.sleep(25)
    return (
        [("text", "Looks fine. The patch keeps the ordering; one nit: two imports in b.gleam are out of order.")],
        "end_turn",
        usage(900, 8000, 400, 0),
    )


def advisor_turn(messages):
    last = messages[-1]
    if tool_results(last):
        return [("text", "Recorded.")], "end_turn", usage(700, 12000, 200, 0)
    if not NUDGED.is_set():
        NUDGED.set()
        return (
            [("tool_use", "advise", {"verdict": "nudge", "text": "Confirm the sweep excludes generated SQL."})],
            "tool_use",
            usage(900, 12000, 200, 0),
        )
    return [("tool_use", "advise", {"verdict": "quiet"})], "tool_use", usage(900, 12000, 200, 0)


def summarize_turn(body):
    asked = json.dumps(body)
    if "NOW" in asked:
        return [("text", "TITLE: Review the patch\nNOW: Reading the patch in src")], "end_turn", usage(300, 0, 0, 0)
    return [("text", "The agent plans the review before it acts.")], "end_turn", usage(300, 0, 0, 0)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("fake: " + (fmt % args) + "\n")

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        model = body.get("model", "")
        messages = body.get("messages", [])
        if model == "fake-main" and messages:
            sys.stderr.write("fake-main last message: %s\n" % json.dumps(text_of(messages[-1].get("content", ""))))
        if model == "fake-sub" and "rate limit" in json.dumps(messages):
            payload = json.dumps({"type": "error", "error": {"type": "invalid_request_error", "message": "rate limit rules refuse this request"}}).encode()
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        names = tool_names(body)
        if "route" in names:
            blocks, stop, used = router_turn(body, messages)
        elif "project_report" in names:
            blocks, stop, used = worker_turn(body, messages)
        elif model == "fake-advisor":
            blocks, stop, used = advisor_turn(messages)
        elif model == "fake-sub":
            blocks, stop, used = sub_turn(messages)
        elif model == "fake-summarize":
            blocks, stop, used = summarize_turn(body)
        else:
            blocks, stop, used = main_turn(messages)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        self.stream(model, blocks, stop, used)

    def event(self, name, data):
        payload = ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()
        self.wfile.write(b"%x\r\n%s\r\n" % (len(payload), payload))
        self.wfile.flush()

    def stream(self, model, blocks, stop, used):
        self.event("message_start", {"type": "message_start", "message": {
            "id": "msg_%d" % time.time_ns(), "type": "message", "role": "assistant",
            "model": model, "content": [], "stop_reason": None, "usage": used}})
        for index, block in enumerate(blocks):
            kind = block[0]
            if kind == "thinking":
                self.event("content_block_start", {"type": "content_block_start", "index": index,
                           "content_block": {"type": "thinking", "thinking": ""}})
                self.event("content_block_delta", {"type": "content_block_delta", "index": index,
                           "delta": {"type": "thinking_delta", "thinking": block[1]}})
                self.event("content_block_delta", {"type": "content_block_delta", "index": index,
                           "delta": {"type": "signature_delta", "signature": "c2lnbmF0dXJl"}})
            elif kind == "text":
                self.event("content_block_start", {"type": "content_block_start", "index": index,
                           "content_block": {"type": "text", "text": ""}})
                words = block[1].split(" ")
                for at in range(0, len(words), 6):
                    piece = " ".join(words[at:at + 6]) + (" " if at + 6 < len(words) else "")
                    self.event("content_block_delta", {"type": "content_block_delta", "index": index,
                               "delta": {"type": "text_delta", "text": piece}})
                    time.sleep(0.08)
            else:
                self.event("content_block_start", {"type": "content_block_start", "index": index,
                           "content_block": {"type": "tool_use", "id": "toolu_%d_%d" % (time.time_ns(), index),
                                             "name": block[1], "input": {}}})
                self.event("content_block_delta", {"type": "content_block_delta", "index": index,
                           "delta": {"type": "input_json_delta", "partial_json": json.dumps(block[2])}})
            self.event("content_block_stop", {"type": "content_block_stop", "index": index})
        self.event("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop},
                   "usage": {"output_tokens": 240}})
        self.event("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
