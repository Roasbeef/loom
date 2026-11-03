%% Test-only Erlang shims for the session suite (never shipped in src).
%% They install a logger handler that forwards every error-level event to
%% the installing process, so a test can prove an orderly stop logs no crash
%% report. The handler callback runs in the process that logs, which for a
%% crashing proc_lib process is the crashing process itself, before its exit
%% is visible to any monitor; a count taken after the exit is therefore final.
-module(session_test_ffi).

-export([install_probe/1, remove_probe/1, captured_errors/0, crash_proc_lib/0, log/2]).

install_probe(Id) ->
    Name = binary_to_atom(Id, utf8),
    ok = logger:add_handler(Name, ?MODULE, #{level => error, config => self()}),
    nil.

remove_probe(Id) ->
    _ = logger:remove_handler(binary_to_atom(Id, utf8)),
    nil.

%% Handler callback: forward the event to the installing process.
log(#{level := Level} = Event, #{config := Owner}) ->
    case logger:compare_levels(Level, error) of
        lt -> ok;
        _ -> Owner ! {captured_error, Event}, ok
    end.

%% Drains and counts the forwarded events.
captured_errors() ->
    captured_errors(0).

captured_errors(N) ->
    receive {captured_error, _} -> captured_errors(N + 1)
    after 0 -> N
    end.

%% Control: a proc_lib process that crashes, which OTP reports as a crash
%% report. Returns once the process is gone.
crash_proc_lib() ->
    Pid = proc_lib:spawn(fun() -> erlang:error(probe_control_crash) end),
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> nil end.
