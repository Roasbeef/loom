%% The runtime package's one Erlang shim (docs/gleam-style.md Part III:
%% one flat module per package). Every function here is reached only
%% through runtime/internal/ffi_sup.gleam, which documents the why; this
%% file owns the how.
-module(runtime_ffi).

-export([terminate_supervisor/2, send_to_pid/2]).

%% sys:terminate/3 against a running OTP supervisor: the only graceful
%% external stop a supervisor offers, and the one gleam_otp's
%% static_supervisor does not wrap. The supervisor replies to the system
%% message before it begins terminating, so `ok` means "the shutdown is
%% under way", not "the tree is gone" -- the caller waits for the pid to
%% die. Every failure (a pid that is already dead, a process that is not
%% sys-compliant, a shutdown that outruns the timeout) collapses to
%% {error, nil}: the caller's recourse is identical whichever it was.
terminate_supervisor(Pid, TimeoutMs) ->
    try sys:terminate(Pid, shutdown, TimeoutMs) of
        ok -> {ok, nil};
        _Other -> {error, nil}
    catch
        _:_ -> {error, nil}
    end.

%% `!` to a pid, once, with no name resolution anywhere in it. `Pid ! Msg`
%% is a silent no-op when Pid has already exited -- Erlang never crashes
%% the sender over a dead pid, only over an unregistered *name* -- so
%% there is nothing here to guard: the one thing that could fail already
%% happened, in whatever resolved Pid before this was called.
send_to_pid(Pid, Message) ->
    Pid ! Message,
    nil.
