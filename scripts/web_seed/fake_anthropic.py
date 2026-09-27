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
        if "agent_spawn" in names:
            spawned = next(r for r in results if called(messages, r.get("tool_use_id")) == "agent_spawn")
            handle = re.search(r"Handle: (\S+)", text_of(spawned.get("content", "")))
            handles = [handle.group(1).rstrip(".")] if handle else []
            return [("tool_use", "agent_wait", {"handles": handles, "within_ms": 120000})], "tool_use", warm
        answer = "\n".join(
            [
                "Done. The reviewer read both files and found nothing that blocks the patch.",
                "",
                "What changed:",
                "- `notes/review.md` records the reviewer's brief and what it checked.",
                "- `notes/plan.md` lists the follow-ups: tighten the census and rerun the lint.",
                "",
                "The reviewer's one nit was the ordering of two imports in b.gleam, which "
                "the formatter settles on the next run. I left it for that pass rather than "
                "hand-editing a generated order.",
            ]
            + ["Line %d of a long answer, streamed a few words at a time." % n for n in range(1, 25)]
        )
        return [("text", answer)], "end_turn", warm
    said = text_of(last.get("content", ""))
    if "advisor-nudges" in said or "[advisor nudges]" in said:
        return [("text", "Checked: the sweep leaves the generated SQL alone.")], "end_turn", warm
    if "after the break" in said:
        return [("text", "Back after the break. The prefix had to be read again.")], "end_turn", usage(1500, 0, 41000, 30000)
    if "review" in said:
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
        if model == "fake-advisor":
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
