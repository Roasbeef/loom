#!/usr/bin/env python3
"""A scripted Anthropic Messages endpoint for the README code-mode capture.

`scripts/codemode_capture/capture.sh` points a throwaway daemon at this
server. For the capture prompt it answers with a short sentence and one
`code_mode` call carrying a fixed Gleam program; once the tool result comes
back it answers with a closing sentence. Compilation, sandboxed execution
and the file reads are all real; only the model is scripted.

Usage: fake_anthropic.py PORT
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROGRAM = """import cap/fs
import cap/report
import cap/task
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> report.Outcome {
  let files = ["durability.md", "multiplayer.md", "code-mode.md"]
  let summaries = task.parallel_map(files, max_concurrency: 3, with: fn(path) {
    fs.read(path)
    |> result.map(fn(body) {
      report.object([
        #("file", report.string(path)),
        #("lines", report.int(list.length(string.split(body, "\\n")))),
      ])
    })
  })

  case summaries {
    Ok(rows) -> report.value(report.list(rows))
    Error(_) -> report.failure("Could not read a project document")
  }
}
"""

INTRO = "I'll read the three project documents concurrently and return only their line counts."
OUTRO = (
    "The three reads completed in one code-mode execution. Each document has 4 lines. "
    "The program returned structured counts; file contents stayed out of the conversation."
)


def has_tool_result(messages):
    last = messages[-1].get("content", [])
    return not isinstance(last, str) and any(b.get("type") == "tool_result" for b in last)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("fake: " + (fmt % args) + "\n")

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        messages = body.get("messages", [])
        if messages and has_tool_result(messages):
            blocks, stop = [("text", OUTRO)], "end_turn"
        else:
            blocks = [("text", INTRO), ("tool_use", "code_mode", {"program": PROGRAM})]
            stop = "tool_use"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        self.stream(body.get("model", ""), blocks, stop)

    def event(self, name, data):
        payload = ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()
        self.wfile.write(b"%x\r\n%s\r\n" % (len(payload), payload))
        self.wfile.flush()

    def stream(self, model, blocks, stop):
        usage = {"input_tokens": 1200, "output_tokens": 1,
                 "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        self.event("message_start", {"type": "message_start", "message": {
            "id": "msg_%d" % time.time_ns(), "type": "message", "role": "assistant",
            "model": model, "content": [], "stop_reason": None, "usage": usage}})
        for index, block in enumerate(blocks):
            if block[0] == "text":
                self.event("content_block_start", {"type": "content_block_start", "index": index,
                           "content_block": {"type": "text", "text": ""}})
                self.event("content_block_delta", {"type": "content_block_delta", "index": index,
                           "delta": {"type": "text_delta", "text": block[1]}})
            else:
                self.event("content_block_start", {"type": "content_block_start", "index": index,
                           "content_block": {"type": "tool_use", "id": "toolu_%d_%d" % (time.time_ns(), index),
                                             "name": block[1], "input": {}}})
                self.event("content_block_delta", {"type": "content_block_delta", "index": index,
                           "delta": {"type": "input_json_delta", "partial_json": json.dumps(block[2])}})
            self.event("content_block_stop", {"type": "content_block_stop", "index": index})
        self.event("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop},
                   "usage": {"output_tokens": 120}})
        self.event("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
