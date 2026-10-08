%% Test-only provisioning and two-emulator scenarios for client/distribution.
%% Each node runs in its own OS emulator, booted with the production boot
%% flags, its own private HOME (so its own .erlang.cookie) and an options file
%% that client/distribution itself generated. Nothing here is part of the
%% production transport: certificates are minted for the run, every child has
%% a finite watchdog and must print a completion witness, and the fixture
%% directory is deleted afterwards.
-module(client_distribution_fixture_ffi).
-export([scenario/1, child/2, installed/4, free_port/0, certificate_facts/1]).
-include_lib("public_key/include/public_key.hrl").

-define(DIST, 'client@distribution').

%% Runs one named scenario and reports Ok or a description of what failed.
scenario(Name) ->
    Root = unicode:characters_to_binary(filename:absname(
        "build/distribution-fixture-"
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

%% Correct pins both ways: connect, exchange a message, stay hidden, and keep
%% automatic connection off. The server listens on a fixed port.
run(<<"connect">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    Port = free_port(),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), {some, Port}),
    exchange(A, ConfigA, connect, #{peer => name_of(B), port => Port, expect_port => yes},
             B, ConfigB, serve, #{});

%% The server presents a different leaf (same CA, same name) than the one the
%% client pinned. The client must refuse it.
run(<<"wrong_leaf_server">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    Name = name("executor"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    Pinned = provision(Root, "pinned", Ca, Name, same, Cookie),
    Live = provision(Root, "live", Ca, Name, same, Cookie),
    ConfigA = config(A, Pinned, cert_of(Pinned), none),
    ConfigB = config(Live, A, cert_of(A), none),
    exchange(A, ConfigA, reject, #{peer => Name}, Live, ConfigB, wait, #{});

%% The client presents a leaf the server did not pin. The server must refuse
%% it, so the client's connect fails.
run(<<"wrong_leaf_client">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    AName = name("owner"),
    A = provision(Root, "owner", Ca, AName, same, Cookie),
    Other = provision(Root, "other", Ca, AName, same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, Other, cert_of(Other), none),
    exchange(A, ConfigA, reject, #{peer => name_of(B)}, B, ConfigB, wait, #{});

%% The server's leaf hashes to the pin, but its DNS name is not the node name.
%% The pin alone is not enough. The server boots through raw net_kernel, since
%% start/1 would refuse a certificate that does not carry its own node name.
run(<<"wrong_san">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"),
                  <<"intruder_x@127.0.0.1">>, Cookie),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, reject, #{peer => name_of(B)},
             B, ConfigB, raw_wait, #{local => name_of(B)});

%% The server's leaf has the right name and the right pin but was issued by a
%% CA the client does not trust. The server still trusts the client's CA, so
%% the refusal is the client's PKIX check and not TLS client-certificate
%% selection. PKIX must still fail.
run(<<"wrong_ca">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    Foreign = root_cert("foreign ca"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Foreign, name("executor"), same, Cookie, Ca),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, reject, #{peer => name_of(B)},
             B, ConfigB, raw_wait, #{local => name_of(B)});

%% Certificates and pins are right but the two cookies differ.
run(<<"wrong_cookie">>, Root) ->
    Ca = root_cert("fixture ca"),
    A = provision(Root, "owner", Ca, name("owner"), same, cookie("a")),
    B = provision(Root, "executor", Ca, name("executor"), same, cookie("b")),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, reject, #{peer => name_of(B)}, B, ConfigB, wait, #{});

%% Both nodes are up and configured for each other. A message to the other
%% node must not dial it, and neither side may end up connected.
run(<<"no_automatic_connection">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, silent_send, #{peer => name_of(B)}, B, ConfigB, idle, #{});

%% Two directory members (protocol-change/079). The connector reaches the
%% other through the production connect path, as an attach would, and both
%% ends must then list each other among their visible nodes, whichever side
%% dialed: a hidden link between members is the case Ra cannot work over.
run(<<"members_visible">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    Members = [name_of(A), name_of(B)],
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, member_connect, #{peer => name_of(B), members => Members},
             B, ConfigB, member_serve, #{peer => name_of(A), members => Members});

%% A member reaches one other member, and so does a third. `global` must not
%% join the first and the third because both reach the middle one: with
%% connect_all off, the only connections are the ones made on purpose.
run(<<"members_not_transitive">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "first", Ca, name("first"), same, Cookie),
    B = provision(Root, "middle", Ca, name("middle"), same, Cookie),
    C = provision(Root, "third", Ca, name("third"), same, Cookie),
    Members = [name_of(A), name_of(B), name_of(C)],
    ConfigA = config_all(A, [B, C], none),
    ConfigB = config_all(B, [A, C], none),
    ConfigC = config_all(C, [A, B], none),
    write_options(A, ConfigA),
    write_options(B, ConfigB),
    write_options(C, ConfigC),
    Isolated = ["-kernel", "connect_all", "false"],
    PortB = open_vm(B, ConfigB, member_wait, #{members => Members}, Isolated),
    try
        await_ready(PortB, <<>>),
        PortC = open_vm(C, ConfigC, member_reach,
                        #{peer => name_of(B), members => Members}, Isolated),
        try
            await_ready(PortC, <<>>),
            PortA = open_vm(A, ConfigA, member_alone,
                            #{peer => name_of(B), other => name_of(C),
                              members => Members}, Isolated),
            try await_complete(PortA, <<>>) after close_port(PortA) end,
            true = port_command(PortC, <<"stop\n">>),
            await_complete(PortC, <<>>)
        after close_port(PortC) end,
        true = port_command(PortB, <<"stop\n">>),
        await_complete(PortB, <<>>)
    after close_port(PortB) end,
    ok;

%% A member VM booted without connect_all off is refused before it starts.
run(<<"member_needs_connect_all_off">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    Config = config(A, B, cert_of(B), none),
    write_options(A, Config),
    Port = open_vm(A, Config, member_refused,
                   #{members => [name_of(A), name_of(B)]}, []),
    try await_complete(Port, <<>>) after close_port(Port) end,
    ok;

%% Boot-precondition and credential refusals, one emulator each.
run(<<"start_refusals">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    Good = config(A, B, cert_of(B), none),

    %% A cookie flag beside the TLS flags.
    expect(A, Good, {error, {unsafe_boot, conflicting_boot_flag}},
           ["-setcookie", "fixture_cookie_override_0123456789"]),

    %% An options file generated for a different peer set.
    Elsewhere = config(A, A, cert_of(A), none, name("elsewhere")),
    expect_with_options(A, Good, Elsewhere, {error, {unsafe_boot, options_mismatch}}),

    %% An options file other users can write.
    expect_world_writable_options(A, Good),

    %% Credential files: missing key, readable key, cookie that is not the
    %% VM's own.
    expect_missing_key(A, Good),
    expect_readable_key(A, Good),
    expect_foreign_cookie(Root, A, B),
    ok;

%% Loom boots the daemon VM without a node name, so the emulator launches no
%% epmd, and a dynamic net_kernel:start/2 does not either. These runs
%% give the child a private epmd port, so they hold on a machine with an epmd
%% already running and on one without any.
%%
%% Nothing answers on the port, so start must launch epmd and register the
%% node with it. The epmd it launched is stopped afterwards.
run(<<"start_launches_epmd">>, Root) ->
    {A, Config} = lone_node(Root, none),
    private_epmd(fun(Port) ->
        write_options(A, Config),
        Child = open_vm(A, Config, epmd_registered, #{epmd_port => Port}, []),
        try await_complete(Child, <<>>) after close_port(Child) end
    end);

%% Something that is not epmd holds the port and never answers, so no epmd can
%% be had. Start must say so, naming the port, rather than blaming credentials,
%% and must not hang on the silent listener.
run(<<"epmd_unavailable">>, Root) ->
    {A, Config} = lone_node(Root, none),
    %% A wildcard listener, so that epmd cannot bind the port beside it.
    {ok, Squatter} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Squatter),
    try
        write_options(A, Config),
        Aux = #{epmd_port => Port,
                expected => {error, {epmd_unavailable, Port}}},
        Child = open_vm(A, Config, expect, Aux, []),
        try await_complete(Child, <<>>) after close_port(Child) end
    after
        ok = gen_tcp:close(Squatter),
        %% Nothing should have started, but if an epmd did slip in beside the
        %% squatter, it is this run's and must not outlive it.
        ok = stop_epmd(Port)
    end,
    ok;

%% `-start_epmd false` says epmd is managed elsewhere, as in the tunnelled
%% orchestrator recipe, so start must not launch one even though none answers.
%% With nothing to register with, OTP then refuses to start, and nothing may
%% answer on the port afterwards.
run(<<"start_epmd_false">>, Root) ->
    {A, Config} = lone_node(Root, none),
    private_epmd(fun(Port) ->
        write_options(A, Config),
        Aux = #{epmd_port => Port, expected => {error, start_failed}},
        Child = open_vm(A, Config, expect, Aux, ["-start_epmd", "false"]),
        try await_complete(Child, <<>>) after close_port(Child) end,
        {error, econnrefused} = gen_tcp:connect({127,0,0,1}, Port, [], 1000)
    end);

%% epmd answers but the distribution listen port is taken, so net_kernel
%% cannot start. Start must report its own fault and leave the VM
%% non-distributed.
run(<<"start_failed">>, Root) ->
    {ok, Taken} = gen_tcp:listen(0, []),
    {ok, ListenPort} = inet:port(Taken),
    try
        {A, Config} = lone_node(Root, {some, ListenPort}),
        private_epmd(fun(Port) ->
            write_options(A, Config),
            Aux = #{epmd_port => Port, expected => {error, start_failed}},
            Child = open_vm(A, Config, expect, Aux, []),
            try await_complete(Child, <<>>) after close_port(Child) end
        end)
    after gen_tcp:close(Taken) end;

%% Remote tool calls over real TLS distribution (client/remote). The executor
%% emulator runs the real host over a fake workspace plane, and the orchestrator
%% emulator attaches a real surface and runs one call. The Gleam roles live in
%% test/support/remote_nodes.gleam, which each child loads through the code path
%% the parent passes with -pa.
%%
%%   remote_run          an undisturbed call that round-trips an owner callback
%%   remote_short_outage the connection is dropped while the tool runs and is
%%                       repaired at once, so the re-sent Run joins the live call
%%   remote_long_outage  the connection stays down until the tool has finished,
%%                       so the re-sent Run is answered from the ledger
run(<<"remote_run">>, Root) ->
    remote(Root, <<"run">>, <<"owner">>, 800);
run(<<"remote_short_outage">>, Root) ->
    remote(Root, <<"short_outage">>, <<"nothing">>, 800);
run(<<"remote_long_outage">>, Root) ->
    remote(Root, <<"long_outage">>, <<"nothing">>, 800);
%% The executor runs the production plane factory over a temporary checkout, and
%% the orchestrator attaches to it by name, writes a file and reads it back
%% through the real tools. The checkout path it learns is the executor's own,
%% carried in the census as an opaque string.
run(<<"remote_workspace">>, Root) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    Work = filename:join(Root, "executor-work"),
    ok = file:make_dir(Work),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, remote_workspace_orchestrator,
             #{peer => name_of(B)},
             B, ConfigB, remote_workspace_host,
             #{directory => bin(Work)}).

remote(Root, Scenario, Asks, Hold) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    Ledger = filename:join(Root, "ledger"),
    ok = file:make_dir(Ledger),
    ConfigA = config(A, B, cert_of(B), none),
    ConfigB = config(B, A, cert_of(A), none),
    exchange(A, ConfigA, remote_orchestrator,
             #{peer => name_of(B), scenario => Scenario},
             B, ConfigB, remote_host,
             #{ledger => bin(Ledger), asks => Asks, hold => Hold}).

%% ---------------------------------------------------------- installed bundles

%% Two nodes that `loom distribution install` set up from provisioned bundles:
%% each tuple is the node's HOME, its loom.toml and its options file. The
%% orchestrator connects to `PeerName`. In `accept` mode it must connect over
%% the executor's fixed `Port`, exchange a message and stay hidden; in `refuse`
%% mode the connection must fail. The configuration of each is read back from
%% the installed loom.toml with the daemon's own parser, so the proof is of the
%% files an operator would have.
installed({HomeA, ConfigA, OptionsA}, {HomeB, ConfigB, OptionsB}, {PeerName, Port}, Mode) ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        {A, CA} = installed_node(HomeA, ConfigA, OptionsA),
        {B, CB} = installed_node(HomeB, ConfigB, OptionsB),
        case Mode of
            accept ->
                exchange(A, CA, connect,
                         #{peer => PeerName, port => Port, expect_port => yes},
                         B, CB, serve, #{});
            refuse ->
                exchange(A, CA, reject, #{peer => PeerName}, B, CB, wait, #{})
        end,
        {ok, nil}
    catch Class:Reason:Stack ->
        {error, unicode:characters_to_binary(
            io_lib:format("~p:~p~n~p", [Class, Reason, Stack]))}
    end.

installed_node(Home, ConfigPath, OptionsPath) ->
    {ok, Text} = file:read_file(ConfigPath),
    {ok, {some, Config}} = ?DIST:parse(Text),
    {#{home => Home, options => OptionsPath, installed => true}, Config}.

%% The SHA-256 of a PEM certificate's DER and its DNS names, computed here from
%% public_key directly so a test does not trust the code that minted them.
certificate_facts(Pem) ->
    [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(Pem),
    #'OTPCertificate'{tbsCertificate = Tbs} = public_key:pkix_decode_cert(Der, otp),
    #'Extension'{extnValue = Names} = lists:keyfind(?'id-ce-subjectAltName',
        #'Extension'.extnID, Tbs#'OTPTBSCertificate'.extensions),
    {crypto:hash(sha256, Der),
     [unicode:characters_to_binary(Dns) || {dNSName, Dns} <- Names]}.

%% ---------------------------------------------------------------- provisioning

root_cert(Label) ->
    public_key:pkix_test_root_cert(Label,
        [{digest, sha256}, {key, {namedCurve, secp256r1}}]).

name(Label) ->
    Suffix = unique(),
    unicode:characters_to_binary(
        ["fixture_", Label, "_", Suffix, "@127.0.0.1"]).

cookie(Label) ->
    Suffix = unique(),
    unicode:characters_to_binary(
        ["loom_fixture_cookie_", Label, "_", Suffix, "_0123456789"]).

%% A node is a private directory (its HOME) holding its certificate chain,
%% key, cookie and options file. The certificate carries `San` as its node
%% name, or its real name when `San` is `same`.
provision(Root, Label, Ca, Name, San, Cookie) ->
    provision(Root, Label, Ca, Name, San, Cookie, Ca).

%% `Trust` is the CA this node's own trust file holds. It is the issuing CA
%% unless a scenario separates the two.
provision(Root, Label, Ca, Name, San, Cookie, Trust) ->
    Home = filename:join(Root, Label),
    ok = file:make_dir(Home),
    ok = file:change_mode(Home, 8#700),
    SanName = case San of same -> Name; Other -> Other end,
    Extension = #'Extension'{extnID = ?'id-ce-subjectAltName',
        extnValue = [{dNSName, binary_to_list(SanName)}, {dNSName, "127.0.0.1"},
                     {iPAddress, <<127,0,0,1>>}], critical = false},
    #{server_config := Conf} = public_key:pkix_test_data(
        #{server_chain => #{root => Ca, intermediates => [],
              peer => [{digest, sha256}, {key, {namedCurve, secp256r1}},
                       {extensions, [Extension]}]},
          client_chain => #{root => [], intermediates => [], peer => []}}),
    Der = proplists:get_value(cert, Conf),
    {Type, Key} = proplists:get_value(key, Conf),
    CaPath = filename:join(Home, "ca.pem"),
    CertPath = filename:join(Home, "cert.pem"),
    KeyPath = filename:join(Home, "key.pem"),
    CookiePath = filename:join(Home, ".erlang.cookie"),
    ok = file:write_file(CaPath, public_key:pem_encode(
        [{'Certificate', maps:get(cert, Trust), not_encrypted}])),
    ok = file:write_file(CertPath, public_key:pem_encode(
        [{'Certificate', Der, not_encrypted}])),
    ok = file:write_file(KeyPath, public_key:pem_encode([{Type, Key, not_encrypted}])),
    ok = file:write_file(CookiePath, Cookie),
    ok = file:change_mode(KeyPath, 8#600),
    ok = file:change_mode(CookiePath, 8#600),
    Files = {credential_files, bin(CaPath), bin(CertPath), bin(KeyPath), bin(CookiePath)},
    #{name => Name, home => Home, cert => Der, files => Files,
      options => filename:join(Home, "dist.options")}.

%% Names must not repeat across runs: an earlier run's emulator may still be
%% registered with epmd for a moment after its test failed.
unique() ->
    iolist_to_binary([integer_to_binary(erlang:system_time(nanosecond)), "_",
                      integer_to_binary(erlang:unique_integer([positive]))]).

bin(Path) -> unicode:characters_to_binary(Path).
str(Path) -> unicode:characters_to_list(Path).
cert_of(#{cert := Der}) -> Der.
name_of(#{name := Name}) -> Name.

%% The configuration `Local` runs with, pinning every node in `Peers`.
config_all(#{name := LocalName, files := Files}, Peers, Listen) ->
    Pins = [{peer_pin, name_of(Peer), crypto:hash(sha256, cert_of(Peer))}
            || Peer <- Peers],
    {ok, Config} = ?DIST:configure(LocalName, Pins, Files, Listen),
    Config.

%% The configuration `Local` runs with, pinning `PinDer` for the peer `Peer`.
config(Local, Peer, PinDer, Listen) ->
    config(Local, Peer, PinDer, Listen, name_of(Peer)).

config(#{name := LocalName, files := Files}, _Peer, PinDer, Listen, PeerName) ->
    Pin = crypto:hash(sha256, PinDer),
    {ok, Config} = ?DIST:configure(LocalName,
        [{peer_pin, PeerName, Pin}], Files, Listen),
    Config.

%% A node that `loom distribution install` set up already has the options file
%% the installer generated, and replacing it here would hide an installer bug.
write_options(#{installed := true, options := Path}, _Config) -> Path;
write_options(#{options := Path}, Config) ->
    ok = file:write_file(Path, ?DIST:tls_options(Config)),
    ok = file:change_mode(Path, 8#600),
    Path.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

%% One provisioned node and a configuration that pins an unstarted peer.
lone_node(Root, Listen) ->
    Ca = root_cert("fixture ca"),
    Cookie = cookie("shared"),
    A = provision(Root, "owner", Ca, name("owner"), same, Cookie),
    B = provision(Root, "executor", Ca, name("executor"), same, Cookie),
    {A, config(A, B, cert_of(B), Listen)}.

%% Runs `Fun` with a loopback port on which no epmd answers, then stops the
%% epmd that `Fun` caused to start there. Only that port is touched, never the
%% machine's own epmd on 4369. The children are given
%% ERL_EPMD_RELAXED_COMMAND_CHECK so the daemon they start accepts `-kill`
%% while a child that has just halted is still registered.
private_epmd(Fun) ->
    Port = free_port(),
    {error, econnrefused} = gen_tcp:connect({127,0,0,1}, Port, [], 1000),
    try Fun(Port) after stop_epmd(Port) end,
    ok.

stop_epmd(Port) ->
    Epmd = os:find_executable("epmd"),
    _ = os:cmd(Epmd ++ " -port " ++ integer_to_list(Port) ++ " -kill"),
    case gen_tcp:connect({127,0,0,1}, Port, [], 1000) of
        {error, _} -> ok;
        {ok, Socket} ->
            gen_tcp:close(Socket),
            timer:sleep(200),
            {error, _} = gen_tcp:connect({127,0,0,1}, Port, [], 1000),
            ok
    end.

%% ---------------------------------------------------------------- driving

%% Boots B, waits until it is listening, runs A to completion, then lets B
%% finish. Both must exit zero with the completion witness.
exchange(A, ConfigA, RoleA, AuxA, B, ConfigB, RoleB, AuxB) ->
    write_options(A, ConfigA),
    write_options(B, ConfigB),
    PortB = open_vm(B, ConfigB, RoleB, AuxB, isolation(AuxB)),
    try
        await_ready(PortB, <<>>),
        PortA = open_vm(A, ConfigA, RoleA, AuxA, isolation(AuxA)),
        try
            await_complete(PortA, <<>>),
            case RoleB of
                serve -> ok;
                member_serve -> ok;
                _ -> true = port_command(PortB, <<"stop\n">>)
            end,
            await_complete(PortB, <<>>)
        after close_port(PortA) end
    after close_port(PortB) end,
    ok.

%% A directory member boots with connect_all off, as the launcher boots it.
isolation(#{members := _}) -> ["-kernel", "connect_all", "false"];
isolation(_) -> [].

%% Runs `start` in a fresh emulator with these extra boot arguments and
%% requires exactly `Expected`, with the VM left non-distributed.
expect(Node, Config, Expected, Extra) ->
    expect_with_options(Node, Config, Config, Expected, Extra).

expect_with_options(Node, Config, OptionsFrom, Expected) ->
    expect_with_options(Node, Config, OptionsFrom, Expected, []).

expect_with_options(Node, Config, OptionsFrom, Expected, Extra) ->
    write_options(Node, OptionsFrom),
    run_expect(Node, Config, Expected, Extra).

expect_world_writable_options(Node, Config) ->
    Path = write_options(Node, Config),
    ok = file:change_mode(Path, 8#666),
    run_expect(Node, Config, {error, {unsafe_boot, options_mismatch}}, []).

expect_missing_key(Node, Config) ->
    write_options(Node, Config),
    #{files := {credential_files, _, _, Key, _}} = Node,
    ok = file:delete(binary_to_list(Key)),
    run_expect(Node, Config, {error, invalid_credentials}, []).

expect_readable_key(Node, Config) ->
    write_options(Node, Config),
    #{files := {credential_files, _, _, Key, _}} = Node,
    ok = file:write_file(binary_to_list(Key), <<"x">>),
    ok = file:change_mode(binary_to_list(Key), 8#644),
    run_expect(Node, Config, {error, invalid_credentials}, []).

%% A cookie file that is private and well formed but is not the VM's own
%% $HOME/.erlang.cookie must be refused.
expect_foreign_cookie(Root, A, B) ->
    Elsewhere = filename:join(Root, "foreign_cookie"),
    ok = file:write_file(Elsewhere, cookie("foreign")),
    ok = file:change_mode(Elsewhere, 8#600),
    #{files := {credential_files, CaP, CertP, KeyP, _}} = A,
    Moved = A#{files := {credential_files, CaP, CertP, KeyP, bin(Elsewhere)}},
    Config = config(Moved, B, cert_of(B), none),
    write_options(Moved, Config),
    run_expect(Moved, Config, {error, invalid_credentials}, []).

run_expect(Node, Config, Expected, Extra) ->
    Port = open_vm(Node, Config, expect, #{expected => Expected}, Extra),
    try await_complete(Port, <<>>) after close_port(Port) end,
    ok.

open_vm(#{home := Home, options := Options}, Config, Role, Aux, Extra) ->
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    Encoded = binary_to_list(base64:encode(term_to_binary({Config, Aux}))),
    Eval = lists:flatten(io_lib:format(
        "client_distribution_fixture_ffi:child(~p, ~p).", [Encoded, Role])),
    Args = ["+S", "2", "-pa"] ++ Paths
        ++ ["-proto_dist", "inet_tls", "-ssl_dist_optfile", str(Options)]
        ++ Extra ++ ["-noshell", "-eval", Eval],
    open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {env, [{"HOME", str(Home)} | epmd_environment(Aux)]}, {args, Args}]).

%% A scenario that names an epmd port gets an epmd of its own there.
epmd_environment(#{epmd_port := Port}) ->
    [{"ERL_EPMD_PORT", integer_to_list(Port)},
     {"ERL_EPMD_RELAXED_COMMAND_CHECK", "1"}];
epmd_environment(_) -> [].

await_ready(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            All = <<Acc/binary, Data/binary>>,
            case binary:match(All, <<"FIXTURE_READY">>) of
                nomatch -> await_ready(Port, All);
                _ -> ok
            end;
        {Port, {exit_status, Status}} -> error({early_exit, Status, Acc})
    after 30000 -> error({ready_timeout, Acc}) end.

await_complete(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            All = <<Acc/binary, Data/binary>>,
            true = byte_size(All) =< 65536,
            await_complete(Port, All);
        {Port, {exit_status, 0}} ->
            case binary:match(Acc, <<"BOOTSTRAP_COMPLETE">>) of
                nomatch -> error({missing_witness, Acc});
                _ -> ok
            end;
        {Port, {exit_status, Status}} -> error({child_exit, Status, Acc})
    after 60000 -> error({child_timeout, Acc}) end.

close_port(Port) -> try port_close(Port) catch _:_ -> ok end.

%% ---------------------------------------------------------------- children

%% The entry point of each child emulator. It has a finite lifetime and prints
%% a witness only after every assertion of its role held.
child(Encoded, Role) ->
    _ = spawn(fun() -> timer:sleep(50000), halt(3) end),
    Self = self(),
    _ = spawn(fun() -> stdin_loop(Self) end),
    try
        {Config, Aux} = binary_to_term(base64:decode(Encoded)),
        role(Role, Config, Aux),
        io:format("BOOTSTRAP_COMPLETE~n"),
        halt(0)
    catch Class:Reason:Stack ->
        io:format("child failure ~p:~p~n~p~n", [Class, Reason, Stack]),
        halt(2)
    end.

role(connect, Config, #{peer := PeerName} = Aux) ->
    {ok, Membership} = ?DIST:start(Config, not_member),
    {error, {unsafe_boot, already_distributed}} = ?DIST:start(Config, not_member),
    {error, invalid_configuration} =
        ?DIST:peer(Membership, <<"network_input@127.0.0.1">>),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    PeerNode = ?DIST:node(Peer),
    PeerName = ?DIST:name(Peer),
    {ok, nil} = ?DIST:connect(Peer, 15000),
    [] = nodes(),
    [PeerNode] = nodes(hidden),
    {ok, never} = application:get_env(kernel, dist_auto_connect),
    case Aux of
        #{expect_port := yes, port := Port} ->
            [Short | _] = string:split(binary_to_list(PeerName), "@"),
            {port, Port, _} = erl_epmd:port_please(Short, {127,0,0,1});
        _ -> ok
    end,
    {loom_dist_probe, PeerNode} ! {ping, self()},
    receive {pong, PeerNode} -> ok after 10000 -> error(no_pong) end;
role(member_connect, Config, #{peer := PeerName, members := Members}) ->
    {ok, Membership} = ?DIST:start(Config, {member, Members}),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    PeerNode = ?DIST:node(Peer),
    {ok, nil} = ?DIST:connect(Peer, 15000),
    [PeerNode] = nodes(),
    [] = nodes(hidden),
    {ok, false} = application:get_env(kernel, connect_all),
    {loom_dist_probe, PeerNode} ! {ping, self()},
    receive {pong, PeerNode, Visible} -> [_] = Visible after 10000 -> error(no_pong) end;
role(member_serve, Config, #{members := Members}) ->
    {ok, _} = ?DIST:start(Config, {member, Members}),
    true = register(loom_dist_probe, self()),
    ready(),
    receive
        {ping, From} ->
            %% The serving end did not dial; the link it was given must still
            %% be visible here.
            [_] = nodes(),
            [] = nodes(hidden),
            From ! {pong, node(), nodes()}
    after 30000 -> error(no_ping) end;
role(member_wait, Config, #{members := Members}) ->
    {ok, _} = ?DIST:start(Config, {member, Members}),
    ready_and_stop();
role(member_reach, Config, #{peer := PeerName, members := Members}) ->
    {ok, Membership} = ?DIST:start(Config, {member, Members}),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    {ok, nil} = ?DIST:connect(Peer, 15000),
    ready_and_stop();
role(member_alone, Config, #{peer := PeerName, other := OtherName,
                             members := Members}) ->
    {ok, Membership} = ?DIST:start(Config, {member, Members}),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    {ok, Other} = ?DIST:peer(Membership, OtherName),
    {ok, nil} = ?DIST:connect(Peer, 15000),
    timer:sleep(2000),
    PeerNode = ?DIST:node(Peer),
    OtherNode = ?DIST:node(Other),
    [PeerNode] = nodes(),
    false = lists:member(OtherNode, nodes(connected));
role(member_refused, Config, #{members := Members}) ->
    {error, {unsafe_boot, connect_all_enabled}} =
        ?DIST:start(Config, {member, Members}),
    false = erlang:is_alive();
role(serve, Config, _Aux) ->
    {ok, _} = ?DIST:start(Config, not_member),
    true = register(loom_dist_probe, self()),
    ready(),
    receive {ping, From} -> From ! {pong, node()} after 30000 -> error(no_ping) end,
    [_] = nodes(hidden);
role(reject, Config, #{peer := PeerName}) ->
    {ok, Membership} = ?DIST:start(Config, not_member),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    {error, unavailable} = ?DIST:connect(Peer, 15000),
    [] = nodes(connected);
role(wait, Config, _Aux) ->
    {ok, _} = ?DIST:start(Config, not_member),
    ready_and_stop();
role(raw_wait, _Config, #{local := Local}) ->
    ok = application:set_env(kernel, dist_auto_connect, never),
    %% The same epmd launch the production start does; net_kernel alone would
    %% fail to register on a machine with no epmd running.
    ok = client_distribution_ffi:ensure_epmd(),
    {ok, _} = net_kernel:start(binary_to_atom(Local, utf8),
        #{name_domain => longnames, hidden => true}),
    ready_and_stop();
role(idle, Config, _Aux) ->
    {ok, _} = ?DIST:start(Config, not_member),
    true = register(loom_dist_probe, self()),
    ready_and_stop(),
    receive {ping, _} -> error(unexpected_message) after 0 -> ok end,
    [] = nodes(connected);
role(silent_send, Config, #{peer := PeerName}) ->
    {ok, Membership} = ?DIST:start(Config, not_member),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    PeerNode = ?DIST:node(Peer),
    {loom_dist_probe, PeerNode} ! {ping, self()},
    timer:sleep(1500),
    [] = nodes(connected);
role(epmd_registered, Config, _Aux) ->
    {ok, _} = ?DIST:start(Config, not_member),
    [Short | _] = string:split(atom_to_list(node()), "@"),
    {ok, Names} = erl_epmd:names({127,0,0,1}),
    {Short, _} = lists:keyfind(Short, 1, Names);
role(expect, Config, #{expected := Expected}) ->
    Expected = ?DIST:start(Config, not_member),
    false = erlang:is_alive();
%% The executor of a remote tool call: the real host over a fake plane. It
%% stays up until the parent says stop, then checks that the tool ran once.
role(remote_host, Config, #{ledger := Ledger, asks := Asks, hold := Hold}) ->
    {ok, _} = ?DIST:start(Config, not_member),
    {ok, Handle} = support@remote_nodes:host(Ledger, Asks, Hold),
    ready_and_stop(),
    {ok, nil} = support@remote_nodes:verify_host(Handle);
%% The executor of a real workspace: the production factory over a checkout.
role(remote_workspace_host, Config, #{directory := Directory}) ->
    {ok, _} = ?DIST:start(Config, not_member),
    {ok, Handle} = support@remote_nodes:workspace_host(Directory),
    ready_and_stop(),
    {ok, nil} = support@remote_nodes:verify_workspace(Handle);
%% The orchestrator of a real workspace: attach by name, write, read back.
role(remote_workspace_orchestrator, Config, #{peer := PeerName}) ->
    {ok, Membership} = ?DIST:start(Config, not_member),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    {ok, nil} = ?DIST:connect(Peer, 15000),
    {ok, nil} = support@remote_nodes:orchestrate_workspace(Peer);
%% The orchestrator of a remote tool call: a real surface running one call.
role(remote_orchestrator, Config, #{peer := PeerName, scenario := Scenario}) ->
    {ok, Membership} = ?DIST:start(Config, not_member),
    {ok, Peer} = ?DIST:peer(Membership, PeerName),
    {ok, nil} = ?DIST:connect(Peer, 15000),
    {ok, nil} = support@remote_nodes:orchestrate(Peer, Scenario).

ready() -> io:format("FIXTURE_READY~n").

ready_and_stop() ->
    ready(),
    receive stop -> ok after 40000 -> error(no_stop) end.

%% The parent closes the port when it is done or has failed, which ends stdin.
%% A child must not outlive its parent, since its node name stays registered.
stdin_loop(Parent) ->
    case io:get_line("") of
        eof -> halt(4);
        "stop\n" -> Parent ! stop, stdin_loop(Parent);
        _ -> stdin_loop(Parent)
    end.
