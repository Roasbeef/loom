%% Stand-in transport handles for the effect tests.
%%
%% A websocket handle and a daemon control handle are opaque records owned by
%% `host/websocket`, `tui/daemon` and `tui/daemon/selection`, and the only
%% public way to obtain either is to open a real connection. The effect tests
%% need neither a server nor a socket: they check which handle a step's
%% effects name, and that the step itself wrote nothing. So each stand-in
%% wraps a subject the test process owns, in the record shape the owning
%% module builds. Anything performed against the handle then arrives in the
%% test's own mailbox, which is how a test sees that the step performed
%% nothing and that the runtime performed it afterwards. This module lives
%% in the test tree so `src` keeps its FFI budget.
-module(effects_test_ffi).

-export([socket_on/1, host_on/1]).

%% `host/websocket.Connection(subject)`.
socket_on(Subject) ->
    {connection, Subject}.

%% `tui/daemon/selection.Host(control, address, token)` around a
%% `tui/daemon.Connection(commands, pid, hello)`. Closing a control handle
%% touches only `commands`, so the route, the credential and the greeting
%% are placeholders nothing reads.
host_on(Subject) ->
    {host, {connection, Subject, self(), nil}, nil, <<>>}.
