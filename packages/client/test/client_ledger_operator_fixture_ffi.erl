%% The emulators of the operator workflow test (protocol-change/086): nodes that
%% `loom distribution install` set up, booted from the configuration and the
%% options file the installer wrote, and a way for the operator's commands to
%% reach them.
%%
%% The test is one Gleam process that runs the real `provision`, `install`,
%% `enroll`, `revoke`, `renew` and `log` commands, so it owns the ports of the
%% nodes it starts. A node is the child of `client_ledger_live_fixture_ffi`: the
%% daemon's own boot (`client/ledger_boot`) over real TLS distribution. The
%% operator's `ledger.*` requests go to a node as a stdin line and come back as
%% one JSON line, served by `client/ledger_control` against the node's ledger
%% process, which is what the daemon's control socket calls. The socket is its
%% own test (`daemon_ledger_test`); what is new here is that the commands change
%% the membership of nodes that are really connected.
-module(client_ledger_operator_fixture_ffi).
-export([boot/2, boot_member/2, step/3, control/3, stop/1, kill/1]).

-define(FIX, client_distribution_fixture_ffi).
-define(LIVEFIX, client_ledger_live_fixture_ffi).
-define(DIST, 'client@distribution').

%% Boots the node whose installation is under `Home`: its configuration is
%% `Home/.loom/loom.toml` and its options file is the one the installer wrote.
boot(Home, ConfigPath) ->
    boot(Home, ConfigPath, []).

%% The same boot for a node that may be a member of the session directory. Such
%% a VM must run with `connect_all` off, so that `global` never connects it to a
%% node because a peer is connected there; the launchers pass the flag.
boot_member(Home, ConfigPath) ->
    boot(Home, ConfigPath, ["-kernel", "connect_all", "false"]).

boot(Home, ConfigPath, Extra) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, Text} = file:read_file(ConfigPath),
    {ok, {some, Config}} = ?DIST:parse(Text),
    Options = filename:join([binary_to_list(Home), ".loom", "distribution",
                             "dist.options"]),
    Node = #{home => binary_to_list(Home), options => Options},
    Aux = #{lines => [], observation => production, lifetime => 600000},
    Port = ?FIX:open_vm(?LIVEFIX, Node, Config, live_node, Aux, Extra),
    case await_text(Port, <<"FIXTURE_READY">>, 60000) of
        {ok, _} -> {ok, Port};
        {error, Why} ->
            ?FIX:close_port(Port),
            {error, Why}
    end.

%% Sends a command and waits for its witness.
step(Port, Command, Witness) ->
    true = port_command(Port, iolist_to_binary([Command, "\n"])),
    case await_text(Port, Witness, 90000) of
        {ok, _} -> {ok, nil};
        {error, Why} -> {error, Why}
    end.

%% Sends a control request and answers the JSON line the node printed.
control(Port, Command, Body) ->
    true = port_command(Port, iolist_to_binary(["control ", Command, " ", Body, "\n"])),
    case await_text(Port, <<"CONTROL ">>, 90000) of
        {ok, _} -> await_line(Port);
        {error, Why} -> {error, Why}
    end.

%% Tells the node to finish and waits for it to say it has.
stop(Port) ->
    true = port_command(Port, <<"stop\n">>),
    Result = await_text(Port, <<"BOOTSTRAP_COMPLETE">>, 60000),
    ?FIX:close_port(Port),
    case Result of
        {ok, _} -> {ok, nil};
        {error, Why} -> {error, Why}
    end.

%% Ends the node without letting it stop its store or its Ra system, as a
%% crashed machine would. The port closes and the emulator goes with it.
kill(Port) ->
    ?FIX:close_port(Port),
    {ok, nil}.

%% ---------------------------------------------------------------- reading

%% Waits for a witness in what the child printed, reading from where the last
%% match ended. Output that arrives with a witness and belongs to a later one is
%% kept for it.
await_text(Port, Witness, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_text(Port, Witness, Deadline, buffered(Port)).

await_text(Port, Witness, Deadline, Buffer) ->
    case binary:match(Buffer, Witness) of
        {Start, Length} ->
            Rest = binary:part(Buffer, Start + Length,
                               byte_size(Buffer) - Start - Length),
            put({buffer, Port}, Rest),
            {ok, nil};
        nomatch ->
            Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {Port, {data, Data}} ->
                    await_text(Port, Witness, Deadline,
                               <<Buffer/binary, Data/binary>>);
                {Port, {exit_status, Status}} ->
                    {error, text(["the node exited with ", integer_to_list(Status),
                                  " before ", Witness, ": ", Buffer])}
            after Left ->
                {error, text(["no ", Witness, " from the node: ", Buffer])}
            end
    end.

%% The rest of the line after a witness, which may arrive in several pieces.
await_line(Port) ->
    Deadline = erlang:monotonic_time(millisecond) + 90000,
    await_line(Port, Deadline, buffered(Port)).

await_line(Port, Deadline, Buffer) ->
    case binary:match(Buffer, <<"\n">>) of
        {Start, _} ->
            Line = binary:part(Buffer, 0, Start),
            Rest = binary:part(Buffer, Start + 1, byte_size(Buffer) - Start - 1),
            put({buffer, Port}, Rest),
            {ok, Line};
        nomatch ->
            Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {Port, {data, Data}} ->
                    await_line(Port, Deadline, <<Buffer/binary, Data/binary>>);
                {Port, {exit_status, Status}} ->
                    {error, text(["the node exited with ", integer_to_list(Status)])}
            after Left ->
                {error, <<"the node did not finish its reply line">>}
            end
    end.

buffered(Port) ->
    case get({buffer, Port}) of undefined -> <<>>; Buffer -> Buffer end.

text(Parts) -> unicode:characters_to_binary(lists:flatten(
    [case P of B when is_binary(B) -> binary_to_list(B); L -> L end || P <- Parts])).
