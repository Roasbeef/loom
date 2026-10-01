# Official Go MCP SDK fixture provenance

`go_sdk.json` contains the actual `tools/list` result from a running server
built with the [official Go MCP SDK](https://github.com/modelcontextprotocol/go-sdk).
The capture ran on 2026-10-01 with Go 1.26.1 on darwin/arm64. We used
`mcp.AddTool` with concrete input and output structs and supplied no schema
objects. The SDK inferred both schemas and serialized the response over stdio.

The application's business data and handler are synthetic. The schemas and
wire responses are captured SDK output, rather than hand-written approximations
of a production service. The one captured tool, `list_applications`, has an
`outputSchema`. The capture driver asserts that every advertised tool has one.

## Dependency pin

The module is `github.com/modelcontextprotocol/go-sdk` at `v1.7.0`, whose
[release commit](https://github.com/modelcontextprotocol/go-sdk/commit/bc72835f62eb94d0fb484439f886b6885b075f36)
is `bc72835f62eb94d0fb484439f886b6885b075f36`. The annotated tag object is
`25cb00203c6b693780f602ab4041c06f7f4b9570`. `go mod download -json` reported
module sum `h1:yqjY2dsbKAC0LSuWZVBMrHgiG8ukXv6NRo0JiALay44=` and module-file sum
`h1:dL7u98E/zjJTGzEq+j30jQ8K2k1mb6LeAH4inEcSGts=`.

The SDK infers nullable schemas for slices and pointers. Required `filter.tags`
and output `applications` therefore accept null as well as arrays. The optional
`limit`, `cursor`, and `next_cursor` properties accept null separately from
absence. Objects are closed with `additionalProperties: false`. These are SDK
choices preserved in the fixture, including the `ttlMs` and `cacheScope` result
metadata.

## Server source

Save this as `main.go` in a temporary directory. The source compiles without
repository dependencies.

```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type Filter struct {
	Region string   `json:"region" jsonschema:"Region containing the application"`
	Tags   []string `json:"tags" jsonschema:"Tags matched by the filter"`
}

type ListApplicationsInput struct {
	JobID  string  `json:"job_id" jsonschema:"Job whose applications are listed"`
	Filter Filter  `json:"filter"`
	Limit  *int    `json:"limit,omitempty" jsonschema:"Optional maximum number of applications"`
	Cursor *string `json:"cursor,omitempty" jsonschema:"Optional pagination cursor"`
}

type Stage struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type Application struct {
	ID    string  `json:"id"`
	Score float64 `json:"score"`
	Stage Stage   `json:"stage"`
}

type ListApplicationsOutput struct {
	Applications []Application `json:"applications"`
	HasMore      bool          `json:"has_more"`
	NextCursor   *string       `json:"next_cursor,omitempty"`
}

func listApplications(_ context.Context, _ *mcp.CallToolRequest, _ ListApplicationsInput) (*mcp.CallToolResult, ListApplicationsOutput, error) {
	return nil, ListApplicationsOutput{
		Applications: []Application{{ID: "application-1", Score: 0.75, Stage: Stage{ID: "stage-1", Name: "Screen"}}},
		HasMore:      false,
	}, nil
}

func main() {
	server := mcp.NewServer(&mcp.Implementation{Name: "loom-go-sdk-fixture", Version: "1.0.0"}, nil)
	mcp.AddTool(server, &mcp.Tool{Name: "list_applications", Description: "List synthetic applications with nested filters and a typed result."}, listApplications)
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

## Capture and verification

Run these commands from the temporary directory containing `main.go` and the
capture driver below. The driver sends initialize, waits for its response,
sends the initialized notification, then requests tools/list. It writes the
unmodified response lines and formats the result object without changing its
JSON values. The server exited with status zero after stdin closed.

```sh
go mod init loom449capture
go get github.com/modelcontextprotocol/go-sdk@v1.7.0
gofmt -w main.go
go mod tidy
go build -o server .
go mod download -json github.com/modelcontextprotocol/go-sdk@v1.7.0
git ls-remote https://github.com/modelcontextprotocol/go-sdk.git \
  refs/tags/v1.7.0 'refs/tags/v1.7.0^{}'
python3 capture.py
cp tools-list-result.json "$LOOM_WORKTREE/packages/mcp/test/mcp/fixtures/go_sdk.json"
```

`LOOM_WORKTREE` names the target Loom checkout. The temporary module and capture
driver are outside the repository; Loom gains no Go dependency or build step.

```python
import json
import select
import subprocess
from pathlib import Path

proc = subprocess.Popen(["./server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
transcript = []

def send(message):
    line = json.dumps(message, separators=(",", ":"))
    transcript.append(("client", line))
    proc.stdin.write((line + "\n").encode())
    proc.stdin.flush()

def receive(expected_id):
    assert select.select([proc.stdout], [], [], 10)[0], "server response timed out"
    line = proc.stdout.readline().decode().strip()
    transcript.append(("server", line))
    response = json.loads(line)
    assert response.get("id") == expected_id and "error" not in response, response
    return response

send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"loom-fixture-capture","version":"1.0.0"}}})
initialized = receive(1)
send({"jsonrpc":"2.0","method":"notifications/initialized"})
send({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
listed = receive(2)
assert len(listed["result"]["tools"]) == 1
assert all(isinstance(tool.get("outputSchema"), dict) for tool in listed["result"]["tools"])
Path("tools-list-wire.json").write_text(transcript[-1][1] + "\n")
Path("initialize-wire.json").write_text(transcript[1][1] + "\n")
Path("tools-list-result.json").write_text(json.dumps(listed["result"], indent=2) + "\n")
Path("transcript.txt").write_text("\n".join(who + " " + line for who, line in transcript) + "\n")
proc.stdin.close()
assert proc.wait(timeout=10) == 0, proc.stderr.read().decode()
print(json.dumps(listed["result"], indent=2))
```

The fixture contains the result object extracted from request 2 so it can use
Loom's existing tools-page decoder. The exact wire response envelopes captured
from stdout follow. Formatting the result object is the only normalization.

Initialize response:

```json
{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"logging":{},"tools":{"listChanged":true}},"protocolVersion":"2025-06-18","serverInfo":{"name":"loom-go-sdk-fixture","version":"1.0.0"}}}
```

Tools/list response:

```json
{"jsonrpc":"2.0","id":2,"result":{"ttlMs":0,"cacheScope":"public","tools":[{"description":"List synthetic applications with nested filters and a typed result.","inputSchema":{"type":"object","properties":{"job_id":{"type":"string","description":"Job whose applications are listed"},"filter":{"type":"object","properties":{"region":{"type":"string","description":"Region containing the application"},"tags":{"type":["null","array"],"items":{"type":"string"},"description":"Tags matched by the filter"}},"required":["region","tags"],"additionalProperties":false},"limit":{"type":["null","integer"],"description":"Optional maximum number of applications"},"cursor":{"type":["null","string"],"description":"Optional pagination cursor"}},"required":["job_id","filter"],"additionalProperties":false},"name":"list_applications","outputSchema":{"type":"object","properties":{"applications":{"type":["null","array"],"items":{"type":"object","properties":{"id":{"type":"string"},"score":{"type":"number"},"stage":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":["id","name"],"additionalProperties":false}},"required":["id","score","stage"],"additionalProperties":false}},"has_more":{"type":"boolean"},"next_cursor":{"type":["null","string"]}},"required":["applications","has_more"],"additionalProperties":false}}]}}
```

The committed fixture's SHA-256 is `c9b13a87f97125e310157da68c7710d516712084783f3befe8abf5cd6574b72b`.
