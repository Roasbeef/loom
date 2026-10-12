%% Test-only scenarios for the runtime assumptions of the membership ledger
%% (docs/design-notes/membership-ledger.md section 16, phase 0, and
%% protocol-change/086). Each scenario boots real emulators with the production
%% TLS distribution flags, an options file that client_distribution_ffi itself
%% generated, and the production start/5, so the verify callback under test is
%% the one the daemon would run. Nothing here is part of the production
%% transport.
%%
%% The node under test has no ledger yet, so a small stand-in process plays its
%% part: it owns the protected ETS table `loom_dist_pins`, replaces the `pins`
%% row with one insert, and takes the table with it when it dies. That is the
%% contract the verify callback reads, which is all the spike has to prove.
%%
%% A child emulator takes commands from its parent over stdin, one per line:
%% `rpc <base64 of a term>`. It answers with `REPLY <base64 of a term>`. Every
%% verdict the verify callback returns for a leaf certificate is recorded by a
%% call trace, so a test can say not only that a connection was refused but
%% which check refused it.
-module(client_ledger_spike_fixture_ffi).
-export([scenario/1, child/2]).
%% The driving and serving halves are shared with the Ra fixture.
-export([call/2, call/3, serve/2]).

-define(FIX, client_distribution_fixture_ffi).
-define(FFI, client_distribution_ffi).

%% Runs one named scenario and reports Ok or a description of what failed.
scenario(Name) ->
    Root = unicode:characters_to_binary(filename:absname(
        "build/ledger-spike-"
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

%% The verify callback reads a table that changes while both emulators run.
%% The orchestrator A dials the executor B, and each step changes one table and
%% then tries a connection, so the only difference between a refusal and an
%% acceptance is the table.
run(<<"live_pins">>, Root) ->
    {A, B} = live_pair(Root),
    Options = options_path(A),
    {ok, Written} = file:read_file(Options),
    with_nodes([{B, #{}}, {A, #{}}], fun([PortB, PortA]) ->
        OsPidA = call(PortA, os_pid),
        OsPidB = call(PortB, os_pid),

        %% No ledger process, so no table: every handshake is refused, and the
        %% refusal is the callback's own `ledger_unavailable`.
        false = connect(PortA, B),
        [{fail, ledger_unavailable}] = verdicts(PortA),

        %% An empty table is not the same state as no table, and it refuses too.
        ok = call(PortA, {start_ledger, []}),
        false = connect(PortA, B),
        [{fail, peer_identity_mismatch}] = verdicts(PortA),

        %% A pin for B at A is half of the answer. A accepts B's leaf, and B,
        %% which still has no table, refuses A's.
        ok = call(PortA, {publish, pins([B])}),
        false = connect(PortA, B),
        [{valid, live}] = verdicts(PortA),
        [{fail, ledger_unavailable}] = verdicts(PortB),

        %% The pin for A at B arrives while B runs. Both leaves are accepted,
        %% the connection is hidden on both sides, and a message crosses it.
        ok = call(PortB, {start_ledger, pins([A])}),
        true = connect(PortA, B),
        pong = ping(PortA, B),
        [{valid, live}] = verdicts(PortA),
        [{valid, live}] = verdicts(PortB),
        #{connected := [NameB], hidden := [NameB]} = call(PortA, nodes),
        NameB = name_of(B),

        %% B removes A's pin. A pin is checked at handshake, so the live
        %% connection is untouched until someone disconnects it.
        ok = call(PortB, {publish, []}),
        pong = ping(PortA, B),
        pong = ping(PortB, A),
        true = call(PortB, {disconnect, name_of(A)}),
        ok = call(PortB, {await_down, name_of(A)}),
        ok = call(PortA, {await_down, name_of(B)}),
        #{connected := []} = call(PortA, nodes),
        #{connected := []} = call(PortB, nodes),

        %% The next handshake is refused by B's callback on A's leaf.
        false = connect(PortA, B),
        [{valid, live}] = verdicts(PortA),
        [{fail, peer_identity_mismatch}] = verdicts(PortB),

        %% The pin comes back and the same pair connects again, in the same
        %% emulators.
        ok = call(PortB, {publish, pins([A])}),
        true = connect(PortA, B),
        pong = ping(PortA, B),
        _ = verdicts(PortA),
        _ = verdicts(PortB),

        %% The table is symmetric. A removes B's pin and disconnects, and A's
        %% own callback refuses B's leaf when A dials.
        ok = call(PortA, {publish, []}),
        true = call(PortA, {disconnect, name_of(B)}),
        ok = call(PortA, {await_down, name_of(B)}),
        ok = call(PortB, {await_down, name_of(A)}),
        false = connect(PortA, B),
        [{fail, peer_identity_mismatch}] = verdicts(PortA),
        ok = call(PortA, {publish, pins([B])}),
        true = connect(PortA, B),
        pong = ping(PortA, B),
        _ = verdicts(PortB),

        %% The table's owner dies. The table goes with it, the live connection
        %% is untouched, and the next handshake is refused rather than allowed.
        ok = call(PortB, kill_ledger),
        pong = ping(PortA, B),
        true = call(PortB, {disconnect, name_of(A)}),
        ok = call(PortB, {await_down, name_of(A)}),
        ok = call(PortA, {await_down, name_of(B)}),
        _ = verdicts(PortA),
        false = connect(PortA, B),
        [{fail, ledger_unavailable}] = verdicts(PortB),
        ok = call(PortB, {start_ledger, pins([A])}),
        true = connect(PortA, B),
        pong = ping(PortA, B),

        %% No emulator restarted, and the file the VM loaded at boot is still
        %% the one the daemon would generate for these credentials.
        OsPidA = call(PortA, os_pid),
        OsPidB = call(PortB, os_pid),
        {ok, Written} = file:read_file(Options)
    end);

%% net_kernel:allow/1 on a node that already filters by pin. The target T pins
%% both X and Y, so a refusal that leaves T's callback accepting the leaf can
%% only come from the allow list. OTP makes two different checks with the one
%% list. An outbound connection is checked against the exact node name. An
%% inbound connection under inet_tls_dist is checked against the certificate:
%% the peer is let in when its certificate names the host of a listed node or
%% the IP address the peer connected from (inet_tls_dist:allowed_nodes/3), and
%% the claimed node name has then to be on one of those hosts. The nodes here
%% are addressed by IP, so their certificates carry the IP, and the claimed name
%% is never what refuses them.
run(<<"allow_list">>, Root) ->
    Ca = ?FIX:root_cert("ledger spike ca"),
    Cookie = ?FIX:cookie("shared"),
    T = live_node(Root, "target", Ca, Cookie),
    X = live_node(Root, "first", Ca, Cookie),
    Y = live_node(Root, "second", Ca, Cookie),
    Specs = [{T, #{ledger => pins([X, Y])}},
             {X, #{ledger => pins([T])}},
             {Y, #{ledger => pins([T])}}],
    with_nodes(Specs, fun([PortT, PortX, PortY]) ->
        NameT = name_of(T),
        NameX = name_of(X),
        NameY = name_of(Y),
        Ghost = <<"ghost@10.9.9.9">>,
        Drop = fun() ->
            true = call(PortT, {disconnect, NameY}),
            ok = call(PortT, {await_down, NameY}),
            ok = call(PortY, {await_down, NameT}),
            _ = verdicts(PortT),
            _ = verdicts(PortY)
        end,

        %% Before the first call nobody is listed, and anybody with the cookie
        %% and a pinned leaf is let in. Y connects.
        {ok, []} = call(PortT, allowed),
        true = connect(PortY, T),
        pong = ping(PortY, T),

        %% The first call turns the list on, here with a name on another host.
        %% A node that is already connected and is not listed stays connected.
        ok = call(PortT, {allow, [Ghost]}),
        {ok, [Ghost]} = call(PortT, allowed),
        pong = ping(PortY, T),
        pong = ping(PortT, Y),

        %% Y is neither listed nor on a listed host, and it connects again: the
        %% inbound check admitted its certificate by the address it came from.
        %% The allow list is not a gate on the name an inbound peer claims.
        Drop(),
        true = connect(PortY, T),
        pong = ping(PortY, T),
        [{valid, live}] = verdicts(PortT),

        %% A later call adds, and X connects.
        ok = call(PortT, {allow, [NameX]}),
        {ok, [Ghost, NameX]} = call(PortT, allowed),
        true = connect(PortX, T),
        pong = ping(PortX, T),

        %% An outbound connection is checked by exact name. T cannot dial Y
        %% until Y is listed, and the refusal comes before TLS: neither
        %% callback is asked.
        Drop(),
        false = connect(PortT, Y),
        [] = verdicts(PortT),
        [] = verdicts(PortY),
        ok = call(PortT, {allow, [NameY]}),
        {ok, [Ghost, NameX, NameY]} = call(PortT, allowed),
        true = connect(PortT, Y),
        pong = ping(PortT, Y),

        %% A repeat adds nothing, an empty list does nothing, and a list with
        %% an element that is not an atom is refused whole, including the atom
        %% before it.
        ok = call(PortT, {allow, [NameX]}),
        {ok, [Ghost, NameX, NameY]} = call(PortT, allowed),
        ok = call(PortT, {allow, []}),
        {ok, [Ghost, NameX, NameY]} = call(PortT, allowed),
        error = call(PortT, {allow_raw, [<<"not_an_atom">>]}),
        error = call(PortT, {allow_raw, [late_name, <<"x">>]}),
        {ok, [Ghost, NameX, NameY]} = call(PortT, allowed),

        %% A listed name is not a trusted name. Removing Y's pin refuses Y at
        %% TLS, with Y still listed, and nothing removes Y from the list.
        ok = call(PortT, {publish, pins([X])}),
        Drop(),
        false = connect(PortY, T),
        [{fail, peer_identity_mismatch}] = verdicts(PortT),
        {ok, [Ghost, NameX, NameY]} = call(PortT, allowed)
    end);

%% The pin-less options file and the boot check that compares the loaded file
%% with the one the configuration generates.
run(<<"options_boot_check">>, Root) ->
    Ca = ?FIX:root_cert("ledger spike ca"),
    Cookie = ?FIX:cookie("shared"),
    A = live_node(Root, "node", Ca, Cookie),
    B = live_node(Root, "other", Ca, Cookie),
    #{files := Files} = A,
    Static = [{name_of(B), crypto:hash(sha256, ?FIX:cert_of(B))}],

    %% The live text names no pin and does not depend on any, and the static
    %% text carries each pin as a binary.
    Live = ?FFI:options(live, Files),
    Live = ?FFI:options(live, Files),
    nomatch = binary:match(Live, <<"<<">>),
    {_, _} = binary:match(?FFI:options(Static, Files), <<"<<">>),
    {_, _} = binary:match(Live, <<"live">>),

    %% A pin-less file with the live start passes every precondition and starts.
    boot_expect(A, Live, live, ok),

    %% The check still compares the file with the mode, so neither mode can
    %% start on the other's file, and a file others can write is still refused.
    boot_expect(A, Live, Static, {error, options_mismatch}),
    boot_expect(A, ?FFI:options(Static, Files), live, {error, options_mismatch}),
    boot_expect(A, Live, live, {error, options_mismatch}, world_writable),
    ok.

%% ------------------------------------------------------------ provisioning

%% A node whose options file is the pin-less one for its credentials.
live_node(Root, Label, Ca, Cookie) ->
    Node = ?FIX:provision(Root, Label, Ca, ?FIX:name(Label), same, Cookie),
    #{files := Files, options := Options} = Node,
    ok = file:write_file(Options, ?FFI:options(live, Files)),
    ok = file:change_mode(Options, 8#600),
    Node.

live_pair(Root) ->
    Ca = ?FIX:root_cert("ledger spike ca"),
    Cookie = ?FIX:cookie("shared"),
    {live_node(Root, "orchestrator", Ca, Cookie),
     live_node(Root, "executor", Ca, Cookie)}.

options_path(#{options := Options}) -> Options.
name_of(Node) -> ?FIX:name_of(Node).

%% The table a node's ledger would publish: each pin with the node name it must
%% present, as the design's map from a 32-byte pin to a name.
pins(Nodes) ->
    [{crypto:hash(sha256, ?FIX:cert_of(Node)), name_of(Node)} || Node <- Nodes].

%% ----------------------------------------------------------------- driving

%% Boots each node and hands their ports to Body in the order given. Every
%% node is told to stop when Body returns and must print its witness; a failure
%% closes the ports, which ends the children.
with_nodes(Specs, Body) -> with_nodes(Specs, [], Body).

with_nodes([], Ports, Body) -> Body(lists:reverse(Ports)), ok;
with_nodes([{Node, Aux} | Rest], Ports, Body) ->
    #{files := Files} = Node,
    Config = #{local => name_of(Node), files => Files},
    Port = ?FIX:open_vm(?MODULE, Node, Config, live_node, Aux#{lifetime => 90000}, []),
    try
        ok = ?FIX:await_ready(Port, <<>>),
        with_nodes(Rest, [Port | Ports], Body),
        true = port_command(Port, <<"stop\n">>),
        ok = ?FIX:await_complete(Port, <<>>)
    after ?FIX:close_port(Port) end.

%% Boots one emulator with `FileText` as its options file, asks the production
%% start for `Peers` (a pin list or `live`), and requires `Expected`.
boot_expect(Node, FileText, Peers, Expected) ->
    boot_expect(Node, FileText, Peers, Expected, private).

boot_expect(#{options := Options, files := Files} = Node, FileText, Peers,
            Expected, Mode) ->
    ok = file:write_file(Options, FileText),
    ok = file:change_mode(Options, case Mode of private -> 8#600;
                                              world_writable -> 8#666 end),
    Config = #{local => name_of(Node), files => Files},
    Aux = #{peers => Peers, expected => Expected},
    Port = ?FIX:open_vm(?MODULE, Node, Config, boot_check, Aux, []),
    try ok = ?FIX:await_complete(Port, <<>>) after ?FIX:close_port(Port) end.

connect(Port, Peer) -> call(Port, {connect, name_of(Peer)}).
ping(Port, Peer) -> call(Port, {ping, name_of(Peer)}).

%% What the callback decided about leaf certificates since the last call.
verdicts(Port) -> lists:usort(call(Port, take_verdicts)).

call(Port, Request) -> call(Port, Request, 20000).

call(Port, Request, TimeoutMs) ->
    Line = iolist_to_binary(["rpc ", base64:encode(term_to_binary(Request)), "\n"]),
    true = port_command(Port, Line),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_reply(Port, Request, Deadline, <<>>).

await_reply(Port, Request, Deadline, Acc) ->
    case reply_in(Acc) of
        {ok, Term} -> Term;
        none ->
            Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {Port, {data, Data}} ->
                    await_reply(Port, Request, Deadline, <<Acc/binary, Data/binary>>);
                {Port, {exit_status, Status}} ->
                    error({early_exit, Request, Status, Acc})
            after Left -> error({reply_timeout, Request, Acc}) end
    end.

%% A reply is a whole line. Anything else the emulator prints is ignored.
reply_in(Acc) ->
    case binary:split(Acc, <<"REPLY ">>) of
        [_, Rest] ->
            case binary:split(Rest, <<"\n">>) of
                [Line, _] -> {ok, binary_to_term(base64:decode(Line))};
                _ -> none
            end;
        _ -> none
    end.

%% ---------------------------------------------------------------- children

child(Encoded, Role) ->
    ?FIX:child_for(fun role/3, Encoded, Role).

%% A node under test: the production start in live mode, a probe to message,
%% a trace on the callback, and a loop that answers the parent.
role(live_node, #{local := Local, files := Files}, Aux) ->
    {ok, _Membership} = ?FFI:start(Local, live, Files, none, none),
    true = register(loom_dist_probe, spawn(fun probe/0)),
    Collector = trace_verdicts(),
    Ledger = case maps:get(ledger, Aux, none) of
        none -> none;
        Pins -> start_ledger(Pins)
    end,
    ?FIX:ready(),
    serve(fun handle/2, #{ledger => Ledger, collector => Collector});
role(boot_check, #{local := Local, files := Files}, #{peers := Peers,
                                                       expected := Expected}) ->
    case {Expected, ?FFI:start(Local, Peers, Files, none, none)} of
        {ok, {ok, _}} -> true = erlang:is_alive();
        {{error, Reason}, {error, Reason}} -> false = erlang:is_alive()
    end.

probe() ->
    receive {ping, From} -> From ! {pong, node()}, probe() end.

%% Answers each request the parent sends until it is told to stop. `Handle`
%% takes a request and the state and returns the reply and the next state.
serve(Handle, State) ->
    receive
        stop -> ok;
        {line, "rpc " ++ Encoded} ->
            Request = binary_to_term(base64:decode(Encoded)),
            {Reply, Next} = Handle(Request, State),
            io:format("REPLY ~s~n", [base64:encode(term_to_binary(Reply))]),
            serve(Handle, Next)
    after 80000 -> error(no_command)
    end.

handle(os_pid, State) -> {os:getpid(), State};
handle({start_ledger, Pins}, #{ledger := none} = State) ->
    {ok, State#{ledger := start_ledger(Pins)}};
handle({publish, Pins}, #{ledger := Ledger} = State) when is_pid(Ledger) ->
    Ledger ! {publish, self(), maps:from_list(Pins)},
    receive {published, _} -> {ok, State} after 5000 -> error(publish_timeout) end;
handle(kill_ledger, #{ledger := Ledger} = State) when is_pid(Ledger) ->
    Monitor = erlang:monitor(process, Ledger),
    exit(Ledger, kill),
    receive {'DOWN', Monitor, process, Ledger, _} -> ok end,
    undefined = ets:whereis(loom_dist_pins),
    {ok, State#{ledger := none}};
handle({connect, Name}, State) ->
    {net_kernel:hidden_connect_node(binary_to_atom(Name, utf8)), State};
handle({disconnect, Name}, State) ->
    {erlang:disconnect_node(binary_to_atom(Name, utf8)), State};
%% Returns once the node is gone from this side. A fresh monitor answers at
%% once for a node that is not connected, and with `dist_auto_connect` off it
%% never dials one, so the answer is driven by the connection and not by a poll.
handle({await_down, Name}, State) ->
    {await_down(binary_to_atom(Name, utf8)), State};
handle(nodes, State) ->
    {#{connected => [atom_to_binary(N, utf8) || N <- nodes(connected)],
       hidden => [atom_to_binary(N, utf8) || N <- nodes(hidden)]}, State};
handle({ping, Name}, State) ->
    Node = binary_to_atom(Name, utf8),
    {loom_dist_probe, Node} ! {ping, self()},
    {receive {pong, Node} -> pong after 5000 -> timeout end, State};
handle(take_verdicts, #{collector := Collector} = State) ->
    Collector ! {take, self()},
    {receive {verdicts, Seen} -> Seen after 5000 -> error(collector_timeout) end,
     State};
handle({allow, Names}, State) ->
    {net_kernel:allow([binary_to_atom(N, utf8) || N <- Names]), State};
handle({allow_raw, Names}, State) ->
    {net_kernel:allow(Names), State};
handle(allowed, State) ->
    {ok, Nodes} = net_kernel:allowed(),
    {{ok, [atom_to_binary(N, utf8) || N <- Nodes]}, State}.

await_down(Node) ->
    true = erlang:monitor_node(Node, true),
    receive {nodedown, Node} -> ok
    after 5000 ->
        true = erlang:monitor_node(Node, false),
        timeout
    end.

%% ------------------------------------------------------------ the ledger stand-in

%% The process that owns the table. The table is `protected`, so only this
%% process writes it, and the handshake processes that run the callback read it.
start_ledger(Pins) ->
    Parent = self(),
    Ledger = spawn(fun() ->
        loom_dist_pins = ets:new(loom_dist_pins, [named_table, protected, set]),
        true = ets:insert(loom_dist_pins, {pins, maps:from_list(Pins)}),
        Parent ! {self(), ready},
        ledger_loop()
    end),
    receive {Ledger, ready} -> Ledger after 5000 -> error(ledger_timeout) end.

ledger_loop() ->
    receive
        {publish, From, Map} ->
            true = ets:insert(loom_dist_pins, {pins, Map}),
            From ! {published, Map},
            ledger_loop()
    end.

%% ------------------------------------------------------------ the verdict trace

%% Records the return value of the callback for each leaf certificate. The
%% callback runs in the ssl connection processes, which are started after this
%% trace is set, so the trace is on new processes.
trace_verdicts() ->
    Collector = spawn(fun() -> collect([]) end),
    _ = erlang:trace_pattern({?FFI, verify, 4},
        [{['_', '_', valid_peer, '_'], [], [{return_trace}]}], [global]),
    _ = erlang:trace(new_processes, true, [call, {tracer, Collector}]),
    Collector.

collect(Seen) ->
    receive
        {trace, _Pid, return_from, {?FFI, verify, 4}, Verdict} ->
            collect([Verdict | Seen]);
        {take, From} ->
            From ! {verdicts, lists:reverse(Seen)},
            collect([]);
        _Other -> collect(Seen)
    end.
