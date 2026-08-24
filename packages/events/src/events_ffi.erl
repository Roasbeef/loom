%% Erlang shim for the events package. The Gleam-side contract and the
%% confinement comments live in `events/internal/ffi_pg.gleam` (spec
%% §0.2: FFI is confined to internal ffi modules; this file is the one
%% flat per-package shim those externals bind to).
%%
%% Every function here normalizes raw OTP shapes to the Gleam calling
%% convention: no exceptions escape, tuples are only built for terms the
%% Gleam side declared, and no atom is created at runtime (the scope,
%% group, and tag atoms are all compile-time literals on one side or the
%% other).
-module(events_ffi).

-export([
    pg_start/1,
    pg_start_link/1,
    pg_join/2,
    pg_leave/2,
    pg_member_count/2,
    pg_publish/3,
    published_payload/1
]).

%% pg:start/1 — idempotent scope bring-up: an already-running scope is
%% success, because callers only need the scope to exist.
pg_start(Scope) ->
    case pg:start(Scope) of
        {ok, _Pid} -> nil;
        {error, {already_started, _Pid}} -> nil
    end.

%% pg:start_link/1 — for supervised embedding, where the caller owns the
%% scope process and an already-running scope is a real conflict.
pg_start_link(Scope) ->
    case pg:start_link(Scope) of
        {ok, Pid} -> {ok, Pid};
        {error, _Reason} -> {error, nil}
    end.

%% pg:join/3 — always joins the calling process, so membership and the
%% mailbox that receives published events cannot diverge.
pg_join(Scope, Group) ->
    ok = pg:join(Scope, Group, self()),
    nil.

%% pg:leave/3 — leaving a group one is not in is a no-op, matching the
%% hint semantics of the bus (nothing depends on membership).
pg_leave(Scope, Group) ->
    _ = pg:leave(Scope, Group, self()),
    nil.

%% pg:get_local_members/2 — an ETS lookup; this is the "local-speed
%% lookup" the design asks of the bus.
pg_member_count(Scope, Group) ->
    erlang:length(pg:get_local_members(Scope, Group)).

%% Fan-out: plain sends to the local members. Delivery is best-effort by
%% design — events are hints, loss is legal — so there is no ack, no
%% retry, and no cross-node fan-out (that is follow-up track 4).
pg_publish(Scope, Group, Published) ->
    lists:foreach(
        fun(Pid) -> Pid ! {loom_event, Published} end,
        pg:get_local_members(Scope, Group)
    ),
    nil.

%% Unwraps the tagged tuple built by pg_publish/3. Only pg_publish
%% constructs `{loom_event, _}` messages, so the payload is always the
%% `Published` record the Gleam side declared.
published_payload({loom_event, Published}) -> Published.
