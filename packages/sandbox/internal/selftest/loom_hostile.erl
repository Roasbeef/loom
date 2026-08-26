%% loom_hostile — the hostile-satellite tabletop's adversary, in the flesh.
%%
%% This module is Erlang, not Gleam. It is compiled with `erlc` by the
%% self-test itself and dropped straight into a node's code path, so it
%% never passes through code mode's vetting (which reads Gleam source),
%% never passes through the compile service (which builds with
%% `--warnings-as-errors` against a pinned manifest), and never asks the
%% cap channel for anything. It is exactly the adversary
%% packages/codemode/CLAUDE.md describes: a `.beam` that ignores the
%% capability boundary entirely and calls the runtime's own effect
%% functions — `file:read_file/1`, `file:write_file/2`,
%% `gen_tcp:connect/4` — which is what a Gleam `@external` declaration
%% compiles down to anyway.
%%
%% Nothing in Loom is supposed to stop it from *trying*. The claim under
%% test is that the kernel stops it from *reaching* anything: the jail's
%% read-only bind denies the write, the protected-path mask hides the
%% secret, and the network namespace plus the seccomp filter deny the
%% connection.
%%
%% Every branch prints a verdict, because a probe that only watched for
%% silence could not tell containment from a module that never loaded.
%% The two `control-*` lines are the load-bearing ones: they are effects
%% the jail is supposed to ALLOW, and they prove this module ran, linked,
%% and can touch a file when the policy permits it. Without them a run of
%% pure denials would be indistinguishable from a node that died on boot.
-module(loom_hostile).
-export([run/1]).

%% run is invoked as `erl -run loom_hostile run <args...>`, which calls
%% it with the plain arguments as a list of strings.
run([ReadOk, WriteOk, Secret, Outside, Port]) ->
    say("hostile-loaded"),
    control_read(ReadOk),
    control_write(WriteOk),
    secret_read(Secret),
    outside_write(Outside),
    net_connect(Port),
    say("hostile-done"),
    init:stop().

say(S) ->
    io:format("~s~n", [S]).

tag(Prefix, Verdict, Reason) ->
    io:format("~s-~s:~0p~n", [Prefix, Verdict, Reason]).

%% An effect the policy allows: reading a file the jail binds in. Proves
%% the module is really running.
control_read(Path) ->
    case file:read_file(Path) of
        {ok, _} -> say("control-read-ok");
        {error, R} -> tag("control-read", "BROKEN", R)
    end.

%% The other allowed effect: writing inside the writable root. Proves a
%% denied write below is the jail's doing and not a module that cannot
%% write at all.
control_write(Path) ->
    case file:write_file(Path, <<"the beam was here\n">>) of
        ok -> say("control-write-ok");
        {error, R} -> tag("control-write", "BROKEN", R)
    end.

%% Reach for a secret under a protected path. bwrap shadows a protected
%% directory with an empty read-only tmpfs, so the file should not exist
%% from in here.
secret_read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> tag("secret-read", "SUCCEEDED", Bin);
        {error, R} -> tag("secret-read", "denied", R)
    end.

%% Reach for the host filesystem outside every writable root. The base
%% view is bound read-only, so this should be EROFS.
outside_write(Path) ->
    case file:write_file(Path, <<"escaped\n">>) of
        ok -> say("outside-write-SUCCEEDED");
        {error, R} -> tag("outside-write", "denied", R)
    end.

%% Reach for the network: a TCP listener the self-test is holding open on
%% the host's loopback, whose port is passed in. Under `network: off` the
%% jail has its own empty network namespace and the seccomp filter denies
%% AF_INET socket creation outright.
net_connect(PortStr) ->
    Port = list_to_integer(PortStr),
    Opts = [binary, {active, false}],
    case gen_tcp:connect({127, 0, 0, 1}, Port, Opts, 3000) of
        {ok, S} ->
            gen_tcp:close(S),
            say("net-CONNECTED");
        {error, R} ->
            tag("net", "denied", R)
    end.
