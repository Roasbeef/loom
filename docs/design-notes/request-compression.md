# Request compression experiment

Measured October 17, 2026 against `8f66fc617ada3ee9fef1b1a46c1a4daf4757ff89`.
This is an experiment, with no production transport or default changed.

## Which bytes

Compress the conversation JSON uploaded to the model endpoint. Both the
terminal and the web component submit through the daemon, whose production
gateway uses `provider/http.httpc_transport`. Neither UI implements its own
model HTTP client. A transport improvement here can serve both hosts.

This changes bandwidth and upload latency. The decoded prompt and token count
are unchanged; compression does not reduce model prefill, generation, or tool
work. Compressing
the response stream is a separate question, with separate buffering and flush
requirements; it was not changed or measured here.

There is no compression module in [Gleam's standard library][stdlib]. The
Erlang runtime already supplies [OTP zlib][zlib], including `gzip/1`,
`gunzip/1`, and configurable deflate levels. No additional compression package
is needed for the daemon. A future Gleam binding belongs in the provider's
`internal/ffi_*` boundary; the pure portable packages remain pure. The current
web host would use the same daemon binding rather than a browser compressor.

## Experiment boundaries

`scripts/request_compression.py` supplies two local HTTP endpoints. The first
is an experiment proxy which optionally gzips the daemon's request using
Python's zlib. The second decodes the request, returns its SHA-256 in a response
header, and streams a valid Anthropic text response. The proxy refuses a
decoded hash mismatch. Both endpoints accept only the dummy `scripted` API
key, bind loopback, and never contact a provider.

The `gzip-seed` prompt receives 512 KiB of deterministic source excerpts mixed
with unique hex trace records. A subsequent `gzip-probe` therefore uploads a
long conversation using Loom's actual encoder and receives `gzip-probe-ok`.
This is synthetic text, with no images or encrypted reasoning signatures;
its compression ratio is not a claim about an operator's real sessions.

`scripts/request_compression_ui.py` drives the real terminal in a 120×40 tmux
pane and the real web UI in headless Chromium at 1440×1000. Each encoding gets
a fresh session with the same two prompts. Three pairs per UI alternate the
encoding order. The driver observes answer text on screen and saves terminal
captures or browser screenshots; it then stops its session and waits for the
daemon's `saved` state before admitting another.

The reviewed driver records a successful timing only after the capture, idle
observation, and `saved` check have succeeded. Rows carry `run_id` and
`session_id`; captures carry the same identifiers in their filenames. Select
one run when analyzing the append-only `ui.jsonl`. An ambiguous session-open
failure still attempts cleanup. Each control RPC has one deadline covering
connection, upgrade, hello, and reply; unrelated events do not renew it, and
EOF during upgrade fails promptly.

`scripts/request_compression.escript` separately measures the runtime we would
actually use in production. It times OTP gzip/gunzip, then sends identical
captured JSON through the existing `provider_ffi` native HTTP owner, bypassing
the experiment proxy. Every attempt checks the decoded request's hash, the
streamed answer and terminal event, and the original owner's **normal exit**.
Completion without handler drain is a failure.
The reviewed harness samples `drained_us` when it receives the normal owner
exit, before response validation and hashing. The first-chunk measurements
below are unchanged by this correction.

The backend models upload serialization by delaying its response by
`wire_bytes × 8 / (Mbps × 1_000_000)`. A rate of zero adds no delay. This is
an explicit simulation, not a measured or shaped WAN: it adds no RTT, packet
loss, TLS, congestion, or model processing. Native measurements include client
compression, local HTTP, server decompression and JSON parsing. UI timings also
include daemon work, event delivery, rendering, and observation overhead.

## Captured bytes and UI results

All measured TUI and web requests had the same SHA-256:

```text
dbb3371d9a64b814b417f7f6c8d4f18e0c467f22475cfecc0d7b1ba3fbaf508c
```

The request was **586,331 bytes**; gzip level 6 produced **130,226 bytes**,
a **77.8% reduction**, or about **4.5× smaller**. These bytes include the
daemon's actual system prompt and tool definitions. The text-only fixture had
no code-mode seed, so `code_mode` was absent from the offered tool set.

At a simulated 10 Mbps, submit-to-visible-answer timings were:

| Real UI | Plain median | Gzip-6 median | Median difference | Plain range | Gzip range |
| --- | ---: | ---: | ---: | ---: | ---: |
| TUI | 983 ms | 740 ms | 244 ms | 943–1,012 ms | 451–1,007 ms |
| Web | 1,145 ms | 559 ms | 585 ms | 1,142–2,219 ms | 477–1,403 ms |

There are only three samples per cell. The wide overlapping ranges make these
UI smoke measurements unsuitable for a speedup guarantee or comparison of the
two UIs. Byte-identical requests and successful visible settlements establish
that both paths can benefit; repeated native measurements isolate the upload
effect more reliably. The UI experiment uses proxy compression, not a shipped
daemon compression setting.

A final correctness smoke repeated all four UI/encoding paths after the driver
cleanup checks were added. Documentation checks ran concurrently, so those
timings are excluded from the planned three-pair series. Its web gzip case
was slower than plain, reinforcing the limit on any UI speedup claim.

## Native runtime measurements

Compression and decompression elapsed times, each the median of 21 runs after
five warmups, on the captured 586,331-byte request:

| OTP gzip level | Wire bytes | Compression | Gunzip |
| --- | ---: | ---: | ---: |
| 1 | 146,497 | 5.03 ms | 2.20 ms |
| 6 (`zlib:gzip/1`) | 130,226 | 10.78 ms | 2.15 ms |
| 9 | 130,203 | 11.61 ms | 2.21 ms |

Level 9 saves only 23 bytes beyond level 6. Level 1 saves compression time but
sends another 16,271 bytes. Which wins depends on upload bandwidth.
These are elapsed timings, not process CPU accounting or memory measurements.

Native request-to-first-body-chunk time includes compression. Each cell below
is the median of seven requests; plain requests are repeated as the control
in each level's run. Order alternates within each pair. All **112 native
attempts** passed hash, terminal, and normal handler-drain checks.

| Simulated upload | Plain, level-1 run | Gzip-1 | Plain, level-6 run | Gzip-6 |
| --- | ---: | ---: | ---: | ---: |
| No added delay | 4.0 ms | 10.0 ms | 4.5 ms | 17.6 ms |
| 1 Mbps | 4,698.9 ms | 1,185.1 ms | 4,696.3 ms | 1,060.7 ms |
| 10 Mbps | 474.3 ms | 128.8 ms | 474.6 ms | 123.1 ms |
| 100 Mbps | 51.5 ms | 23.0 ms | 52.2 ms | 27.7 ms |

At 10 Mbps, gzip-6 saves about **352 ms** on this request; at 1 Mbps it saves
about **3.64 seconds**. On unrestricted loopback it costs about **13 ms**.
Level 1 does better than level 6 in the 100 Mbps fixture, while level 6 does
better at 1 Mbps. Gzip is not a universal latency improvement.

Controls also round-trip byte-for-byte. Empty input grows from 0 to 20 bytes;
a 10-byte UTF-8 string grows to 30. An 8 KiB prefix compresses to 3,734 bytes
in 0.18 ms at level 6. A random 586,331-byte control grows to 586,529 bytes
and takes 14.88 ms to compress. Size alone cannot guarantee a useful gain.

## Reproducing it

Use the repository's Gleam/OTP toolchain, Python 3, tmux, Chromium, and the
Python `playwright` package. Build the unchanged application and helper:

```sh
make sandbox
(cd packages/client && gleam build --warnings-as-errors)
```

The focused harness regressions use only Python's standard library and local
loopback sockets:

```sh
python3 -B scripts/test_request_compression.py -v
```

The UI driver's `--ui tui` mode does not load Playwright or launch Chromium.

Use a private empty home, state directory, and workspace under
`build/compression`; initialize the workspace with `git init`. Give the daemon
this catalogue at `build/compression/state/loom.toml`:

```toml
[models.fixture]
dialect = "anthropic"
base_url = "http://127.0.0.1:18744"
api_key_env = "GZIP_LAB_KEY"
model_id = "gzip-experiment"
context_window = 2000000
max_output_tokens = 180000
[roles]
main = ["fixture"]
[memory]
inject = "off"
```

In separate terminals, start the experiment fixture and an isolated daemon.
These fixed ports must be free; run one experiment at a time.

```sh
python3 scripts/request_compression.py serve build/compression/lab
```

```sh
env HOME="$PWD/build/compression/home" GZIP_LAB_KEY=scripted \
  erl +S 4:4 -pa "$PWD"/packages/client/build/dev/erlang/*/ebin \
  -noshell -eval 'client@@main:run(client)' -extra \
  --state-dir "$PWD/build/compression/state" --bind 127.0.0.1:18745 \
  --config "$PWD/build/compression/state/loom.toml" \
  --helper "$PWD/packages/sandbox/loom-exec" --ui --best-effort
```

Run the UI driver. It creates fresh sessions, not prompts in an existing
operator session. `--chromium` can select another Chromium executable.

```sh
python3 scripts/request_compression_ui.py build/compression \
  --state build/compression/state \
  --workspace "$PWD/build/compression/workspace" --rounds 3
python3 scripts/request_compression.py summary build/compression/lab
```

The request summary separates compression levels and rejects inconsistent
byte sizes within a group. It aggregates all captured attempts in its input
directory; use the UI rows' run identifiers for a particular UI series.

The long request is saved as `build/compression/lab/<sha256>.json`. Substitute
that path below. Run timings sequentially on an otherwise quiet machine.

```sh
escript scripts/request_compression.escript cpu CAPTURE.json
ERL_LIBS="$PWD/packages/client/build/dev/erlang" \
  escript scripts/request_compression.escript transport CAPTURE.json 6
ERL_LIBS="$PWD/packages/client/build/dev/erlang" \
  escript scripts/request_compression.escript transport CAPTURE.json 1
```

The optional Python replay command alternates identity/gzip through the proxy;
the native escript is the stronger production-runtime evidence:

```sh
python3 scripts/request_compression.py replay build/compression/lab \
  --capture CAPTURE.json --count 7 --rates 0 1 10 100
```

Only use synthetic sessions here: saved captures contain complete prompts.
Generated request bodies, logs, and UI captures stay under ignored `build/`.
Terminate the private daemon and fixture after the experiment.

The recorded run used Linux x86-64, Gleam 1.18.1, OTP 29 / ERTS 17.0.5,
one scheduler for the native benchmark, and Chromium 154.0.8037.57.
The daemon ran with four schedulers and the terminal with two. The build
completed successfully with `--warnings-as-errors`; existing Erlang dependency
warnings still appeared. A disposable container held the toolchain and tmux;
a local TCP relay exposed its loopback daemon to the host browser. No model
credentials were configured, no provider request was made, and no operator
daemon was installed or restarted.

Original measurement validation passed: the application build, Python syntax checks, documentation
gate, UI settlements and cleanup, all native transport attempts, and byte-exact
compression controls. The documentation gate reported zero errors and 196
existing citation warnings. The full application test suite was not rerun;
production source is unchanged.

Harness review independently recomputed the stored capture hash, gzip-6 size,
and the UI/native table medians from the original artifacts. Fresh validation
of the repaired scripts passed eight focused tests, including silent and
truncated control peers, a peer sending unrelated events past the RPC deadline,
ambiguous open cleanup, failed attempts producing no success row, and distinct
run/session identities. Seven in-memory mutations were rejected: combining
compression levels, accepting inconsistent sizes, renewing the RPC budget,
ignoring upgrade EOF, recording before cleanup, skipping cleanup after an open
failure, and dropping run identity. These focused tests do not rerun the real
UI or native transport measurements above; those numbers remain evidence from
the original experiment.

## What this supports next

Measure a few real, consented conversation bodies and verify each intended
provider/proxy's request-encoding support before choosing a production policy.
Keep compression at the shared native transport boundary, after its begin
permit, with `Content-Encoding: gzip` and the correct binary byte length.
Do not base64 the payload, compress individual message strings, or change
the frozen typed request contract just to carry HTTP wire encoding.

Small and incompressible inputs need a bypass; gzip can enlarge them. A
compressed request rejection must not silently trigger an inference retry
after ambiguous admission. The existing cancellation, deadline, and handler
drain proofs remain part of the transport contract. There is enough evidence
to pursue request gzip, but this experiment establishes neither live provider
acceptance nor production inference latency improvements.

[stdlib]: https://hexdocs.pm/gleam_stdlib/
[zlib]: https://www.erlang.org/doc/apps/erts/zlib.html
