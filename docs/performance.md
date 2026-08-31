# Performance on Gleam and the BEAM

Performance work in Loom starts with a process, a workload, and a measurement.
An Activity Monitor row named `beam.smp` is not enough: a development machine
can have a server, a terminal client, a test node, and yesterday's forgotten
preview under that same name. Find the exact process first, state what it was
doing, then measure the property we intend to change.

The eTUI work for issue #114 exposed both sides of this rule. Rebuilding and
comparing the complete transcript on every terminal tick made idle CPU scale
with conversation length. A scalar render revision removed that history walk
from idle cache refresh, and a per-record row cache removed settled-history
parsing from live stream refresh. The next layer pins etui's identical-Buffer
diff fast path, reuses the exact completed frame when no visible input changed,
and backs the terminal poll from 40 ms to 400 ms after 320 ms of inactivity.
The same client can still grow its transcript projection forever, so a quiet CPU
sample says nothing about its long-session memory bound. Those are separate
claims and need separate evidence.

## Name the experiment

A useful result carries enough context for another developer to reproduce it.
Record the commit, Erlang/OTP and Gleam versions, command line, terminal size,
history size, and workload. For an interactive client, use at least these three
workloads:

1. Idle after initial synchronization.
2. A steady text stream while the viewport follows the tail.
3. A long transcript while the viewport is scrolled away from the tail.

Let each workload settle before sampling. Run it more than once, and compare the
same workload before and after the patch. Cold compilation, package download,
websocket startup, and a warmed render loop answer different questions.

Identify every candidate `beam.smp` process and its process group before picking
a PID:

```sh
ps -axo pid=,ppid=,pgid=,%cpu=,rss=,etime=,command= | rg 'beam.smp|tui_gleam|loom'
```

`RSS` is resident memory in KiB on macOS. `%CPU` is a recent average, so take a
series rather than trusting one row:

```sh
tui_pid=12345
for sample_number in 1 2 3 4 5 6 7 8 9 10; do
  ps -o pid=,ppid=,pgid=,%cpu=,rss=,etime=,command= -p "$tui_pid"
  sleep 1
done
```

Do not reuse a shell variable such as `HOME` for a PID or output directory.
Keep the client and server PIDs beside the result so the two cannot be confused
later.

## Measure from the outside first

The operating system gives a cheap first cut before tracing changes the program.
On macOS, `footprint` separates the process's physical footprint from its broad
virtual address space:

```sh
footprint -p "$tui_pid"
footprint --sample 1 --sample-duration 10 -p "$tui_pid"
```

Use `sample` when CPU stays high and we do not yet know which native stack is
busy:

```sh
sample "$tui_pid" 10 1 -file tui-idle.sample.txt
sample_status=$?
printf 'SAMPLE_EXIT=%s\n' "$sample_status"
```

Repeated UTF-8 conversion, regular-expression compilation, list reversal, or
garbage collection in an idle sample points to work above the terminal driver.
Sleeping scheduler threads point the other way: the remaining cost may be the
poll cadence, buffer diff, or wakeup path rather than one hot Gleam function.
An OS sample names the neighborhood. It does not replace a BEAM function
profile.

Every benchmark and gate must preserve the status of the command being measured.
Do not let `tail`, `tee`, or an `echo` become the reported result. This form keeps
the log and the gate's own status:

```sh
set -o pipefail
make check-tui_gleam 2>&1 | tee check-tui_gleam.log
gate_status=${pipestatus[1]}
printf 'CHECK_TUI_GLEAM_EXIT=%s\n' "$gate_status"
exit "$gate_status"
```

The array syntax above is for zsh, which is the development shell used for these
measurements. In bash, read `PIPESTATUS[0]` instead. For a plain command with no
pipeline, capture `$?` immediately and print it before running another command.

## Move inside the BEAM when the question narrows

Erlang/OTP ships several profilers, each with a different cost and answer. Use
the lightest one that can confirm or reject the current hypothesis.

`tprof` is the first choice on OTP 27 and newer. It can count calls, measure call
time, or measure heap allocation. `call_count` has the smallest overhead. The
`call_time` and `call_memory` modes can follow one process and the processes it
spawns. `tprof` is still marked experimental in OTP 27, so record the OTP release
with the result.

For one repeatable operation, profile a function and restrict the trace pattern
to the generated Erlang module under investigation. First build the package and
read the module's `-module(...)` declaration under
`build/dev/erlang/<package>/_gleam_artefacts/`. Gleam module paths and generated
Erlang atoms are not interchangeable. In the examples below,
`GeneratedModule` means the exact atom read from that build output:

```erlang
GeneratedModule = 'the@exact_generated@module'.
tprof:profile(
  fun() -> tui_benchmark:render_long_transcript() end,
  #{
    type => call_memory,
    pattern => [{GeneratedModule, '_', '_'}],
    report => {total, {measurement, descending}}
  }
).
```

For a running node, start the server-aided profiler, trace the exact BEAM process,
and collect only the relevant module:

```erlang
{ok, _} = tprof:start(#{type => call_time}).
tprof:enable_trace(TuiPid).
tprof:set_pattern(GeneratedModule, '_', '_').
Sample = tprof:collect().
tprof:format(tprof:inspect(Sample)).
tprof:stop().
```

Do not hot-reload a traced module. Reloading clears that module's tracing state
and makes the accumulated result incomplete.

`eprof` is useful when the question is simply where a known set of processes
spends time:

```erlang
{ok, _} = eprof:start().
profiling = eprof:start_profiling([TuiPid]).
%% Exercise one measured workload here.
profiling_stopped = eprof:stop_profiling().
eprof:analyze(total).
stopped = eprof:stop().
```

`fprof` records call and return traces, then reports both a function's own time
and its accumulated time including callees. Reach for it when call relationships
matter and `tprof` has already narrowed the target. Its trace can be large, and
tracing still perturbs the node even though the events go to a file:

```erlang
ok = fprof:trace([start, {procs, [TuiPid]}, {file, "tui.trace"}]).
%% Exercise one short measured workload here.
ok = fprof:trace(stop).
ok = fprof:profile([{file, "tui.trace"}]).
ok = fprof:analyse([{dest, "tui.analysis"}]).
```

Observer gives the widest live view:

```erlang
observer:start().
```

Use its process table, reductions, mailbox lengths, memory, scheduler activity,
and allocation views to choose the next focused measurement. Observer is a
diagnostic UI, not a benchmark harness. Opening it adds processes and sampling
work to the node.

The runtime can also report its own allocation totals without opening a GUI:

```erlang
erlang:memory().
process_info(TuiPid, [
  memory,
  heap_size,
  total_heap_size,
  stack_size,
  message_queue_len,
  garbage_collection
]).
```

`erlang:memory/0` covers the whole node; `process_info/2` covers one Erlang
process, not the whole operating-system `beam.smp` process. Read both beside
`footprint`. A large native binary pool, loaded code, emulator allocation, or
another Erlang process can explain why their totals differ.

The profiler reports generated Erlang module and function names. Keep the
generated `.erl` file open while reading a profile so each reported function can
be mapped back to its `.gleam` definition.

## Immutable data makes cost visible in the update shape

Gleam lists are singly linked. Prepending an element is O(1); appending to the
end walks the left list. This innocent-looking update is therefore O(n):

```gleam
let records = list.append(model.records, [record])
```

Repeating it for every entry makes total ingest O(n squared). Keep append-heavy
collections in reverse order, prepend each new value, then reverse once at the
boundary that needs chronological order:

```gleam
let newest_first = [record, ..model.records]
let chronological = list.reverse(newest_first)
```

The verified append-heavy eTUI offender was the durable `records` collection;
local transcript notices use the same shape but are not admitted per stream
event. The same shape can occur one level down, but the presence of
`list.append` alone does not prove a quadratic path. Inspect whether the left
operand grows inside a loop or recursion, then profile that workload. A one-time
append of two already-built markdown fragments may be the clearest linear join;
repeatedly extending the same rendered line is the shape to investigate.

Bounded questions should stop at their bound. `list.length(items) > limit` walks
the whole list even though element `limit + 1` settles the answer. Prefer a
bounded operation such as `list.drop(items, limit) != []`. Loom's R5 lint rule
detects this shape; `make lint-<package>` is part of performance verification,
not merely a style pass.

Eager function arguments are another hidden hot path. `bool.guard`'s `return:`,
`option.unwrap`'s fallback, and replacement errors run before the call decides
whether it needs them. Use the lazy form when a fallback recurses, allocates,
walks a collection, or formats a report. `docs/gleam-style.md` records the JSON
parser failure that made this rule concrete.

## Cache by mutation, not by structural comparison

An immutable model makes ownership clear, but comparing two complete models on
every tick can turn immutability into an accidental traversal. A render cache
should be invalidated where its source data changes. In the eTUI, event handlers
advance a scalar `render_revision`; the cache stores `rendered_revision` beside
the derived rows:

```gleam
let changed =
  model.render_revision != model.rendered_revision
  || width_changed
  || detail_mode_changed
```

An idle tick now compares integers and a small set of scalar presentation keys.
It does not compare `transcript`, `records`, or `streams`. The update that adds a
durable entry or stream fragment must advance the revision in the same branch.
That local pairing is the invariant. If invalidation moves elsewhere, a new event
path can update the source without updating the screen.

The completed-frame cache extends that mutation discipline through the etui
boundary. A visible mutation advances `frame_revision` and eagerly builds the
next Buffer and cursor tuple into the immutable model. An unchanged view returns
that exact tuple rather than reconstructing an equal Buffer, which lets etui's
physical-term check skip the structural cell walk. The cache key is only the
revision and screen rectangle; it never compares `transcript`, `records`,
`streams`, or the complete Model.

A stream fragment still wraps the live fragment and builds one new frame, as it
must. The eTUI keeps durable rows newest-first and prepends only newly admitted
records, so that active work does not reparse settled history. Profile both idle
and streaming workloads around the two cache layers. They still need an eventual
projection bound, and matched measurements remain the evidence for their effect.

## Polling is a latency budget

The eTUI drains its websocket actor inbox on terminal ticks. Recent keyboard,
paste, resize, scroll, or decoded websocket activity selects a 40 ms poll. After
320 ms without one of those events, the loop selects 400 ms. The asymmetric
transition is deliberate hysteresis: activity returns to the fast path
immediately, while quiet requires a sustained window. A live operation does not
hold the fast cadence by itself; its thinking glyph continues at the quiet
cadence so it remains legible without restoring twenty wakeups per second.

The latency cost is explicit. The socket actor sends a BEAM message as soon as a
websocket frame arrives, but it cannot wake etui's terminal poll. The first
external event after quiet may therefore wait up to 400 ms before it is drained;
that event resets the policy and subsequent fragments return to 40 ms. A true
event-driven path still needs a wakeable etui backend or a custom loop that waits
on terminal input and the socket notification together.

An idle same-session comparison on the development Mac used a 120x60 terminal
after both clients had synchronized. The prior fixed-50-ms client at etui
`699d2c0` reported 5.1-5.4% CPU over the six settled samples of an eight-sample,
two-second series. The candidate at `fd1ff36` with exact frame reuse and adaptive
polling reported 0.0% at the same display precision; its accumulated CPU time
advanced by about 0.01 seconds over 14 seconds, or roughly 0.07% of one core.
Treat the result as a directional greater-than-50x idle reduction, not a general
throughput benchmark: it covers one machine, one terminal size, and the idle
workload only.

The two clients used the same server session and this launch shape from their
respective `packages/tui_gleam` directories:

```sh
stty rows 60 cols 120
gleam run -- --addr ws://127.0.0.1:PORT/v1/ws \
  --session SESSION --token-file SESSION.db.token
top -l 8 -s 2 -stats pid,cpu,time,threads,mem | rg '^(OLD_PID|NEW_PID)'
```

The settled old-client CPU samples were `5.1, 5.1, 5.4, 5.3, 5.2, 5.3`;
all eight candidate samples displayed `0.0`. Over the same settled 14-second
window, the old process advanced from `5:01.74` to `5:02.32` of CPU time while
the candidate advanced from `1.09` to `1.10` seconds. Preserve both the raw
samples and the CPU-time cross-check when repeating the experiment because
`top` rounds values below its display precision.

That wakeup boundary must still leave visible state in the terminal model. A
socket actor that renders directly creates a second presentation owner; a
blocking receive in keyboard handling makes the UI quiet by making it
unresponsive. Keep periodic ticks only for UI work that is genuinely driven by
time.

Batching also needs a stated bound. `drain_connection(model, 64)` limits one tick
to 64 decoded messages, so a burst cannot hold the keyboard loop forever. A
smaller batch improves fairness but may fall behind the producer. A larger batch
reduces scheduling overhead but lengthens one frame. Measure mailbox depth,
stream latency, and key latency together.

## Accumulate streams without copying their prefix

Streaming providers may deliver hundreds of small fragments. Replacing
`current` with `current <> fragment` can repeatedly copy the accumulated prefix,
depending on the binary shape the runtime can preserve. The cost rises with the
length of one live stream, not just the number of transcript entries.

Keep fragments newest-first and join them once when rendering or settlement
needs a contiguous string. This changes the stream representation, so preserve
the existing strand-and-kind key and the settlement rule that clears transient
text when its durable entry arrives. The optimization is invalid if it renders
fragments backward or lets live text duplicate the committed answer.

Profile allocation before claiming this change materially helps. `tprof` with
`call_memory` can show whether concatenation was the real source of heap churn.
A plausible asymptotic argument is a reason to measure, not evidence that the
current runtime was slow.

## Bound client projections, never rewrite durable history

Loom's conversation store is durable and write-once. A terminal client does not
need every durable entry, every wrapped row, and every syntax-highlighted span in
memory at once. Keep a bounded window around the viewport and discard derived
rows outside it. The server remains authoritative; the client may rebuild a
projection from durable entries.

The bound must cover the whole projection chain. Capping `records` while keeping
old `transcript` lines and `rendered_rows` changes no memory law. Conversely,
discarding durable entry records without a way to retrieve them makes scrollback
silently incomplete. ClientGateway full snapshots contain a recent-entry window,
while older-history paging remains a named protocol concern. Define an entry
window and its sequence frontier only alongside a proven retrieval path; until
then, keep the current history limit explicit instead of truncating behind the
operator's back. Once retrieval exists, evict every derived value outside the
same frontier.

Measure memory as a curve, not one footprint. Replay successively larger histories
and record physical footprint after garbage collection has had time to settle.
A bounded projection should approach a ceiling once the window is full. One flat
idle sample only proves that the process did not grow during that sample.

## Close the loop

The useful optimization loop is short:

1. State one property and one workload.
2. Capture the baseline and the exact command status.
3. Use OS sampling to locate the subsystem, then a BEAM profiler to name the
   function, call count, time, or allocation.
4. Change one cost shape while preserving the boundary's invariants.
5. Re-run the same workload, package gate, and Loom lint.
6. Record the result and the remaining limit separately.

Tests prove semantics; profiles prove where resources went. Keep both. A patch
that lowers CPU but breaks scroll anchoring, transient settlement, or keyboard
latency is a regression. A patch that preserves every test but has no matched
before-and-after measurement is still a hypothesis.
