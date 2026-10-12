%% Test-only scenarios for ledger mode (docs/design-notes/membership-ledger.md
%% and protocol-change/086): a deployment whose trust is a signed ledger and
%% nothing else, run across real emulators.
%%
%% Each node is a separate emulator booted with the production TLS distribution
%% flags, its own HOME and an options file that client/distribution generated
%% for ledger mode. Its credentials are minted by the production PKI
%% (client_pki_ffi) under one authority, the ledger is signed with that
%% authority's key, and the child starts exactly what the daemon starts
%% (client/ledger_boot), so the verify callback, the pin table, the allow list,
%% the disconnects and the dialing under test are the production ones.
%%
%% A child takes commands from its parent over stdin, one per line, and prints
%% one witness line for each. The parent keeps a buffer per child and matches
%% witnesses in the order it asked for them, so a line printed late by a command
%% that runs in the background is not lost to the command after it.
-module(client_ledger_live_fixture_ffi).
-export([scenario/1, child/2]).

-define(FIX, client_distribution_fixture_ffi).
-define(DIST, 'client@distribution').
-define(PKI, client_pki_ffi).
-define(LIVE, 'support@ledger_live').

%% Runs one named scenario and reports Ok or a description of what failed.
scenario(Name) ->
    Root = unicode:characters_to_binary(filename:absname(
        "build/ledger-live-"
            ++ integer_to_list(erlang:unique_integer([positive]))
            ++ "-" ++ integer_to_list(erlang:system_time(nanosecond)))),
    ok = file:make_dir(Root),
    try
        {ok, _} = application:ensure_all_started(ssl),
        ok = run(Name, Root),
        {ok, nil}
    catch Class:Reason:Stack ->
        {error, unicode:characters_to_binary(
            io_lib:format("~p:~p~n~p", [Class, Reason, Stack]))}
    after
        file:del_dir_r(Root)
    end.

%% ---------------------------------------------------------------- scenarios

%% Three nodes boot from ledgers alone, with no peer in any configuration. The
%% orchestrator is linked to both executors and the executors are not linked to
%% each other. The orchestrator reaches both without being told to, which is
%% the dialing, the executors see only the orchestrator, and the unlinked pair
%% cannot connect even when the allow list is made to permit it, so the pin
%% table is what refuses.
run(<<"links_only">>, Root) ->
    Specs = [{box, executor, []}, {desk, executor, []},
             {hub, orchestrator, [box, desk]}],
    D = deployment(Root, Specs),
    Lines = script(D, Specs),
    nodes_up(D, Lines, [{hub, 3, production}, {box, 3, production},
                        {desk, 3, production}],
        fun(#{hub := Hub, box := Box, desk := Desk}) ->
            ok = step(Hub, ["await_connected ", names(D, [box, desk])],
                      <<"NODES_ARE">>),
            ok = step(Box, ["await_connected ", names(D, [hub])], <<"NODES_ARE">>),
            ok = step(Desk, ["await_connected ", names(D, [hub])], <<"NODES_ARE">>),

            %% Neither executor lists the other, so neither table does.
            ok = step(Box, ["connect ", name(D, desk)], <<"CONNECT not_linked">>),
            ok = step(Desk, ["connect ", name(D, box)], <<"CONNECT not_linked">>),

            %% Past the name check, the handshake itself is refused.
            ok = step(Box, ["force_connect ", name(D, desk)], <<"FORCE false">>),
            ok = step(Desk, ["force_connect ", name(D, box)], <<"FORCE false">>),
            ok = step(Hub, ["await_connected ", names(D, [box, desk])],
                      <<"NODES_ARE">>)
        end);

%% A member is enrolled while the others run. The new node starts from a ledger
%% that holds its own entry, as an installed bundle does, and cannot reach
%% anyone until the others have the entry. Then it reaches both linked peers
%% with no restart anywhere: the entry reached the second peer through the
%% first, the table was republished, and the allow list grew.
run(<<"enroll_without_restart">>, Root) ->
    Specs = [{box, executor, []}, {hub, orchestrator, [box]},
             {desk, executor, [hub, box]}],
    D = deployment(Root, Specs),
    Lines = script(D, Specs),
    nodes_up(D, Lines, [{hub, 2, production}, {box, 2, production},
                        {desk, 3, production}],
        fun(#{hub := Hub, box := Box, desk := Desk}) ->
            ok = step(Hub, ["await_connected ", names(D, [box])], <<"NODES_ARE">>),

            %% The others do not know the new node yet.
            ok = step(Desk, ["connect ", name(D, hub)], <<"CONNECT refused">>),
            ok = step(Desk, ["connect ", name(D, box)], <<"CONNECT refused">>),

            %% The entry is offered to one node and reaches the other by itself.
            ok = step(Hub, ["offer 3"], <<"OFFER accepted">>),
            ok = step(Box, ["await_head 3"], <<"AT 3">>),
            ok = step(Desk, ["connect ", name(D, hub)], <<"CONNECT connected">>),
            ok = step(Desk, ["connect ", name(D, box)], <<"CONNECT connected">>),
            ok = step(Hub, ["await_connected ", names(D, [box, desk])],
                      <<"NODES_ARE">>),
            ok = step(Box, ["await_connected ", names(D, [hub, desk])],
                      <<"NODES_ARE">>)
        end);

%% A member is revoked while everyone is connected. The node that applies the
%% entry drops its connection to the revoked member, the entry reaches the
%% other linked node through the connection that remains and it drops its own,
%% and the revoked node, which no connection can tell, is refused when it
%% reconnects. A revoked node never hears of its revocation here, as 086
%% section 9.2 says.
run(<<"revoke_drops_connections">>, Root) ->
    Specs = [{box, executor, []}, {desk, executor, [box]},
             {hub, orchestrator, [box, desk]}],
    D = deployment(Root, Specs),
    Lines = script(D, Specs ++ [{retire, box}]),
    nodes_up(D, Lines, [{hub, 3, production}, {box, 3, production},
                        {desk, 3, production}],
        fun(#{hub := Hub, box := Box, desk := Desk}) ->
            ok = step(Hub, ["await_connected ", names(D, [box, desk])],
                      <<"NODES_ARE">>),
            ok = step(Box, ["connect ", name(D, desk)], <<"CONNECT connected">>),
            ok = step(Box, ["await_connected ", names(D, [hub, desk])],
                      <<"NODES_ARE">>),
            ok = step(Desk, ["await_connected ", names(D, [hub, box])],
                      <<"NODES_ARE">>),

            ok = step(Hub, ["offer 4"], <<"OFFER accepted">>),
            ok = step(Hub, ["await_connected ", names(D, [desk])], <<"NODES_ARE">>),
            ok = step(Desk, ["await_head 4"], <<"AT 4">>),
            ok = step(Desk, ["await_connected ", names(D, [hub])], <<"NODES_ARE">>),
            ok = step(Box, ["await_connected -"], <<"NODES_ARE">>),

            %% The revoked node still holds the ledger it had, and both peers
            %% refuse its handshake.
            ok = step(Box, ["describe"], <<"head 3">>),
            ok = step(Box, ["connect ", name(D, hub)], <<"CONNECT refused">>),
            ok = step(Box, ["connect ", name(D, desk)], <<"CONNECT refused">>),
            ok = step(Hub, ["await_connected ", names(D, [desk])], <<"NODES_ARE">>)
        end);

%% The handshake that read the old table and finishes after a revoke was
%% published. The executor's ledger process is held while it applies the entry
%% that revokes the other node, with the old row still in the table. The other
%% node connects: the callback reads the old row and accepts. Then the process
%% is let go. It publishes the new table and it does not sweep, so the node-up
%% that is waiting in its mailbox is the only thing that can end the
%% connection, and it does. The other node learns of its own revocation from the
%% executor's next head and publishes the empty table, and it does not sweep
%% either, so nothing but the executor's node-up check ends the connection.
run(<<"node_up_after_publish">>, Root) ->
    Specs = [{box, executor, []}, {hub, executor, [box]}],
    D = deployment(Root, Specs),
    Lines = script(D, Specs ++ [{retire, hub}]),
    nodes_up(D, Lines, [{hub, 2, unswept}, {box, 2, held}],
        fun(#{hub := Hub, box := Box}) ->
            ok = step(Box, ["offer_async 3"], <<"OFFER_STARTED">>),
            ok = step(Box, ["await_held"], <<"HELD">>),

            %% The old row is still published, so the handshake is accepted.
            ok = step(Hub, ["connect ", name(D, box)], <<"CONNECT connected">>),
            ok = step(Box, ["await_up ", name(D, hub)], <<"UP">>),

            %% Only now is the ledger process let go.
            ok = step(Box, ["release"], <<"RELEASED">>),
            ok = step(Box, ["await_down ", name(D, hub)], <<"DOWN">>),
            ok = step(Box, ["offer_done"], <<"OFFER_DONE accepted">>),
            ok = step(Box, ["await_connected -"], <<"NODES_ARE">>),
            ok = step(Hub, ["await_connected -"], <<"NODES_ARE">>),

            %% And the new row refuses the next handshake.
            ok = step(Hub, ["force_connect ", name(D, box)], <<"FORCE false">>)
        end).

%% ----------------------------------------------------------------- the world

%% One authority, and for each spec a node minted under it: its name, its
%% credentials in a private home, and the pin of its certificate.
deployment(Root, Specs) ->
    {CaPem, CaKeyPem} = ?PKI:authority(<<"ledger live ca">>),
    Cookie = ?FIX:cookie("live"),
    Nodes = maps:from_list([{Label, mint(Root, Label, CaPem, CaKeyPem, Cookie)}
                            || {Label, _Role, _Links} <- Specs]),
    #{ca => CaPem, key => CaKeyPem, nodes => Nodes}.

mint(Root, Label, CaPem, CaKeyPem, Cookie) ->
    Name = ?FIX:name(atom_to_list(Label)),
    Home = filename:join(Root, atom_to_list(Label)),
    ok = file:make_dir(Home),
    ok = file:change_mode(Home, 8#700),
    {ok, {CertPem, KeyPem}} =
        ?PKI:issue(CaPem, CaKeyPem, atom_to_binary(Label, utf8),
                   [Name, <<"127.0.0.1">>]),
    {ok, Pin} = ?PKI:pin(CertPem),
    Paths = #{ca => "ca.pem", certificate => "cert.pem", key => "key.pem",
              cookie => ".erlang.cookie", options => "dist.options",
              ledger => "ledger.log"},
    P = fun(Key) -> ?FIX:bin(filename:join(Home, maps:get(Key, Paths))) end,
    ok = file:write_file(P(ca), CaPem),
    ok = file:write_file(P(certificate), CertPem),
    ok = file:write_file(P(key), KeyPem),
    ok = file:write_file(P(cookie), Cookie),
    ok = file:change_mode(P(key), 8#600),
    ok = file:change_mode(P(cookie), 8#600),
    #{label => Label, name => Name, home => Home, pin => Pin,
      options => filename:join(Home, "dist.options"),
      ledger => P(ledger),
      files => {credential_files, P(ca), P(certificate), P(key), P(cookie)}}.

%% The signed ledger of a deployment: its genesis, then one entry for each
%% step. A spec enrolls a member with the links it names; `{retire, Label}`
%% revokes one.
script(#{ca := CaPem, key := CaKeyPem, nodes := Nodes}, Steps) ->
    Name = fun(Label) -> maps:get(name, maps:get(Label, Nodes)) end,
    Entries = [case Step of
        {retire, Label} -> {retire, atom_to_binary(Label, utf8)};
        {Label, Role, Links} ->
            #{pin := Pin} = maps:get(Label, Nodes),
            {enroll, atom_to_binary(Label, utf8), Name(Label), Pin, Role,
             [atom_to_binary(L, utf8) || L <- Links]}
    end || Step <- Steps],
    {ok, Lines} = ?LIVE:script(CaKeyPem, CaPem, Entries),
    Lines.

name(#{nodes := Nodes}, Label) -> maps:get(name, maps:get(Label, Nodes)).

%% The names of some nodes, comma separated, or `-` for none.
names(_D, []) -> "-";
names(D, Labels) ->
    lists:join(",", [binary_to_list(name(D, Label)) || Label <- Labels]).

%% -------------------------------------------------------------------- driving

%% Boots each node, from the first `Count` + 1 lines of the ledger, and hands
%% the running ports to Body by label. Every node is told to stop when Body
%% returns, and a failure closes the ports, which ends the children.
nodes_up(D, Lines, Specs, Body) -> nodes_up(D, Lines, Specs, #{}, Body).

nodes_up(_D, _Lines, [], Ports, Body) -> Body(Ports), ok;
nodes_up(#{nodes := Nodes} = D, Lines, [{Label, Last, Observation} | Rest],
         Ports, Body) ->
    #{name := Name, files := Files, options := Options,
      ledger := Path} = Node = maps:get(Label, Nodes),
    Held = lists:sublist(Lines, Last + 1),
    ok = file:write_file(Path, [[Line, <<"\n">>] || Line <- Held]),
    ok = file:change_mode(Path, 8#600),
    {ok, Config} = ?DIST:configure_ledger(Name, Files, none, Path),
    ok = file:write_file(Options, ?DIST:tls_options(Config)),
    ok = file:change_mode(Options, 8#600),
    Aux = #{lines => Lines, observation => Observation, lifetime => 300000},
    Port = ?FIX:open_vm(?MODULE, Node, Config, live_node, Aux, []),
    try
        ok = expect(Port, <<"FIXTURE_READY">>, 60000),
        nodes_up(D, Lines, Rest, Ports#{Label => Port}, Body),
        true = port_command(Port, <<"stop\n">>),
        ok = expect(Port, <<"BOOTSTRAP_COMPLETE">>, 60000)
    after ?FIX:close_port(Port) end.

%% Sends a command and waits for its witness.
step(Port, Command, Witness) ->
    true = port_command(Port, iolist_to_binary([Command, "\n"])),
    expect(Port, Witness, 90000).

%% Waits for a witness in what the child printed, reading from where the last
%% match ended. Output that arrives with a witness and belongs to a later one is
%% kept for it.
expect(Port, Witness, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    expect(Port, Witness, Deadline, buffered(Port)).

expect(Port, Witness, Deadline, Buffer) ->
    case binary:match(Buffer, Witness) of
        {Start, Length} ->
            Rest = binary:part(Buffer, Start + Length,
                               byte_size(Buffer) - Start - Length),
            put({buffer, Port}, Rest),
            ok;
        nomatch ->
            Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {Port, {data, Data}} ->
                    expect(Port, Witness, Deadline, <<Buffer/binary, Data/binary>>);
                {Port, {exit_status, Status}} ->
                    error({early_exit, Witness, Status, Buffer})
            after Left -> error({text_timeout, Witness, Buffer})
            end
    end.

buffered(Port) ->
    case get({buffer, Port}) of undefined -> <<>>; Buffer -> Buffer end.

%% ---------------------------------------------------------------- children

child(Encoded, Role) ->
    ?FIX:child_for(fun role/3, Encoded, Role).

%% A node as the daemon starts it: the ledger process, the table, then
%% distribution, through the production boot. The commands that follow are the
%% parent's.
role(live_node, Config, #{lines := Lines, observation := Observation}) ->
    {ok, Node} = ?LIVE:boot(Config, Observation),
    ok = net_kernel:monitor_nodes(true, [{node_type, all}]),
    ?FIX:ready(),
    commands(Node, Lines, #{}).

commands(Node, Lines, State) ->
    receive
        stop -> ok;
        {line, "connect " ++ Name} ->
            say("CONNECT ~s", [?LIVE:connect(Node, list_to_binary(Name))]),
            commands(Node, Lines, State);
        %% A connection past the node's own name check, to see the handshake
        %% refuse a pair that is not linked.
        {line, "force_connect " ++ Name} ->
            Target = list_to_atom(Name),
            _ = net_kernel:allow([Target]),
            say("FORCE ~p", [net_kernel:hidden_connect_node(Target)]),
            commands(Node, Lines, State);
        {line, "offer " ++ Index} ->
            case ?LIVE:offer(Node, Lines, list_to_integer(Index)) of
                {ok, Word} -> say("OFFER ~s", [Word]);
                {error, Why} -> say("OFFER_FAILED ~s", [Why])
            end,
            commands(Node, Lines, State);
        %% The same offer in a process of its own, for a node whose ledger
        %% process is held and cannot answer until it is let go.
        {line, "offer_async " ++ Index} ->
            Self = self(),
            _ = spawn(fun() ->
                Self ! {offered, ?LIVE:offer(Node, Lines, list_to_integer(Index))}
            end),
            say("OFFER_STARTED", []),
            commands(Node, Lines, State);
        {line, "offer_done"} ->
            receive
                {offered, {ok, Word}} -> say("OFFER_DONE ~s", [Word]);
                {offered, {error, Why}} -> say("OFFER_FAILED ~s", [Why])
            after 60000 -> say("OFFER_FAILED no answer", [])
            end,
            commands(Node, Lines, State);
        {line, "await_head " ++ Seq} ->
            case ?LIVE:await_head(Node, list_to_integer(Seq), 60000) of
                {ok, nil} -> say("AT ~s", [Seq]);
                {error, Why} -> say("AWAIT_FAILED ~s", [Why])
            end,
            commands(Node, Lines, State);
        {line, "await_connected " ++ Names} ->
            case ?LIVE:await_connected(Node, node_list(Names), 60000) of
                {ok, nil} -> say("NODES_ARE ~s", [Names]);
                {error, Why} -> say("AWAIT_FAILED ~s", [Why])
            end,
            commands(Node, Lines, State);
        {line, "describe"} ->
            {ok, Text} = ?LIVE:describe(Node),
            say("DESCRIBE ~s", [Text]),
            commands(Node, Lines, State);
        {line, "await_held"} ->
            case ?LIVE:await_held(Node, 60000) of
                {ok, Release} ->
                    say("HELD", []),
                    commands(Node, Lines, State#{release => Release});
                {error, Why} ->
                    say("HOLD_FAILED ~s", [Why]),
                    commands(Node, Lines, State)
            end;
        {line, "release"} ->
            (maps:get(release, State))(),
            say("RELEASED", []),
            commands(Node, Lines, maps:remove(release, State));
        {line, "await_up " ++ Name} ->
            say(event(nodeup, Name, "UP"), []),
            commands(Node, Lines, State);
        {line, "await_down " ++ Name} ->
            say(event(nodedown, Name, "DOWN"), []),
            commands(Node, Lines, State)
    after 280000 -> error(no_command)
    end.

%% Waits for the VM to report a node coming up or going down. The reports are
%% the VM's own, so the wait is the event and not a poll.
event(Kind, Name, Word) ->
    receive
        {Kind, Node, _Info} ->
            case atom_to_list(Node) =:= Name of
                true -> Word;
                false -> event(Kind, Name, Word)
            end
    after 60000 -> Word ++ "_FAILED"
    end.

node_list("-") -> [];
node_list(Names) ->
    [list_to_binary(N) || N <- string:split(Names, ",", all)].

say(Format, Args) -> io:format(Format ++ "~n", Args).
