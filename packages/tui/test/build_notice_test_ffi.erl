%% A daemon host that names a build, for the build-mismatch notice tests.
%%
%% `tui/daemon/selection.Host` wraps a `tui/daemon.Connection`, an opaque
%% record whose only public constructor authenticates against a real
%% daemon. The notice reads nothing of the connection but the greeting's
%% build, so this stand-in builds the record shape the owning modules build,
%% with a greeting that names the build the test chooses. The command
%% subject is one the test process owns and nothing is sent to it. This
%% module lives in the test tree so `src` keeps its FFI budget.
-module(build_notice_test_ffi).

-export([host_with_build/3]).

%% `Host(Connection(commands, pid, Hello(epoch, principal, control_bytes,
%% Some(Build(version, commit)))), address, token)`.
host_with_build(Subject, Version, Commit) ->
    Hello = {hello, nil, <<"operator">>, 65536, {some, {build, Version, Commit}}},
    {host, {connection, Subject, self(), Hello}, nil, <<>>}.
