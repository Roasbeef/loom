%% OTP-only primitives for trusted TLS distribution, reached only through
%% client/internal/ffi_distribution.gleam. Neither gleam_erlang, gleam_otp nor
%% weft can express any of these: the TLS verify callback runs inside the ssl
%% handshake, net_kernel:start/2 and net_kernel:hidden_connect_node/1 are not
%% wrapped, the boot checks read the emulator's own argument vector, and the
%% epmd launch has to run an OS executable before net_kernel:start/2.
%%
%% The one certificate callback keeps every PKIX failure and, for the leaf,
%% additionally requires a configured SHA-256 pin together with the exact
%% full-node DNS name in the subject alternative names. No network input is
%% ever turned into an atom: peer names become atoms once, from the finite
%% configuration, inside start/5.
%%
%% The pins come from one of two places. Static mode carries them in the
%% options file, as the state of the callback. Live mode (protocol-change/086)
%% names no pin in the file: the state is the atom `live`, and a leaf is checked
%% against the row `pins` of the protected ETS table `loom_dist_pins`, which a
%% process on this node replaces while the VM runs. Only the module that owns
%% the callback can read that table inside a handshake, which is why the live
%% read is here and not behind a wrapper.
%%
%% A node that is a member of the session directory's Khepri cluster
%% (protocol-change/083) is started visible, because Ra reads `nodes()` to
%% decide where to send snapshots and heartbeats, and every connection it makes
%% to another member is made with net_kernel:connect_node/1, because a
%% connection made with hidden_connect_node/1 stays hidden even between two
%% visible nodes. Every other connection, and every connection of a node that
%% is not a member, stays hidden exactly as before.
%%
%% In ledger mode the members change while the VM runs, so no atom list made at
%% start can say which peers are members. The ledger process publishes a second
%% row of the same table, `directory`, with the node names of the other members
%% this node is linked to, and `link/2` reads it on every connect. A node whose
%% own entry does not seat it in the directory publishes an empty list, and
%% connects hidden to everyone.
-module(client_distribution_ffi).
-export([options/2, launch_setting/0, validate/4, start/5, peer/2, link/2, connect/2, verify/4,
         ensure_epmd/0, publish_pins/1, publish_directory/1]).
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

%% The ETS table that live mode reads, and the row in it that holds the map
%% from a 32-byte leaf pin to the node name that pin must present.
-define(PIN_TABLE, loom_dist_pins).
-define(PIN_ROW, pins).

%% The row of the same table that holds the node names, as binaries, of the other
%% members of the session directory this node is linked to. A member daemon in
%% ledger mode reads it to decide whether a connection is visible, because the
%% set of members changes while the VM runs.
-define(DIRECTORY_ROW, directory).

%% The ssl_dist_optfile text for a configuration. The same term is rebuilt in
%% start/5 and compared with what the emulator actually loaded, so the file
%% cannot drift from the configuration the daemon validated.
options(Peers, Files) ->
    %% OTP defaults unmarked options files to Latin-1. Declare the UTF-8 that
    %% we emit so quoted binary pins retain their exact bytes when consulted.
    unicode:characters_to_binary(io_lib:format(
        "%% coding: utf-8~n~p.~n", [tls_options(Peers, Files)])).

tls_options(Peers, {credential_files, Ca, Cert, Key, _Cookie}) ->
    Pins = verify_state(Peers),
    Shared = [{cacertfile, binary_to_list(Ca)},
              {certfile, binary_to_list(Cert)},
              {keyfile, binary_to_list(Key)},
              {verify, verify_peer},
              {versions, ['tlsv1.3', 'tlsv1.2']},
              {verify_fun, {fun ?MODULE:verify/4, Pins}},
              {log_level, none}],
    [{server, [{fail_if_no_peer_cert, true} | Shared]}, {client, Shared}].

%% Static mode renders the pins into the file. Live mode renders none, so the
%% file is a function of the credential paths alone and enrolling or revoking a
%% node never changes it.
verify_state(live) -> live;
verify_state(Peers) -> [{binary_to_list(Name), Pin} || {Name, Pin} <- Peers].

verify(_Cert, _Der, {bad_cert, Reason}, _Pins) -> {fail, Reason};
verify(_Cert, _Der, {extension, _}, Pins) -> {unknown, Pins};
verify(_Cert, _Der, valid, Pins) -> {valid, Pins};
%% A leaf in live mode is checked against whatever map the table holds now. A
%% missing table or row refuses every handshake, so a stopped owner can only
%% close the node and never open it.
verify(Cert, Der, valid_peer, live) ->
    case live_pins() of
        {ok, Pins} ->
            case maps:find(crypto:hash(sha256, Der), Pins) of
                {ok, Name} ->
                    case exact_node_san(Cert, binary_to_list(Name)) of
                        true -> {valid, live};
                        false -> {fail, peer_identity_mismatch}
                    end;
                error -> {fail, peer_identity_mismatch}
            end;
        unavailable -> {fail, ledger_unavailable}
    end;
verify(Cert, Der, valid_peer, Pins) ->
    Digest = crypto:hash(sha256, Der),
    case lists:any(fun({Name, Pin}) ->
        Digest =:= Pin andalso exact_node_san(Cert, Name)
    end, Pins) of
        true -> {valid, Pins};
        false -> {fail, peer_identity_mismatch}
    end.

live_pins() ->
    try ets:lookup(?PIN_TABLE, ?PIN_ROW) of
        [{?PIN_ROW, Pins}] when is_map(Pins) -> {ok, Pins};
        _ -> unavailable
    catch error:badarg -> unavailable
    end.

%% Replaces the row that live mode reads with the given pairs of a 32-byte pin
%% and the node name it must present, using one insert so that a handshake
%% sees the old map or the new one. The first call creates the table, so the
%% calling process becomes its owner: the table is protected, only that process
%% can insert, and it is deleted when that process ends. Exactly one process
%% per VM, the ledger process, may call this. It is FFI because gleam_stdlib,
%% gleam_erlang and gleam_otp expose no ETS table, and only this module's
%% callback reads the row inside a handshake.
publish_pins(Pairs) ->
    case ets:whereis(?PIN_TABLE) of
        undefined ->
            ?PIN_TABLE = ets:new(?PIN_TABLE, [named_table, protected, set]);
        _ -> ok
    end,
    true = ets:insert(?PIN_TABLE, {?PIN_ROW, maps:from_list(Pairs)}),
    nil.

%% Replaces the row that says which nodes are directory members, with one
%% insert, on the table `publish_pins/1` owns. It is empty on a node that is not
%% a member itself, so such a node connects hidden to everyone. FFI for the same
%% reason as `publish_pins/1`: `link/2` reads it, and it lives in that table.
publish_directory(Names) ->
    true = ets:insert(?PIN_TABLE, {?DIRECTORY_ROW, Names}),
    nil.

%% Exactly one DNS name in the certificate contains an at sign, and it is the
%% node name. Host-only names may accompany it for the TLS hostname check.
exact_node_san(#'OTPCertificate'{tbsCertificate = Tbs}, Name) ->
    case lists:keyfind(?'id-ce-subjectAltName', #'Extension'.extnID,
                      Tbs#'OTPTBSCertificate'.extensions) of
        #'Extension'{extnValue = Names} ->
            [Name] =:= [Dns || {dNSName, Dns} <- Names, lists:member($@, Dns)];
        _ -> false
    end.

%% Capture emulator arguments, including arguments injected through ERL_FLAGS.
%% An unrepresentable distribution flag leaves no recoverable launch setting.
launch_setting() ->
    Forbidden = [ssl_dist_opt, name, sname, setcookie, nocookie, hidden,
                 start_epmd, epmd_port],
    Env = ["ERL_EPMD_PORT", "ERL_EPMD_ADDRESS"],
    Clean = lists:all(fun(Flag) -> init:get_argument(Flag) =:= error end,
                      Forbidden) andalso
            lists:all(fun(Name) -> os:getenv(Name) =:= false end, Env),
    case {Clean, init:get_argument(proto_dist),
          init:get_argument(ssl_dist_optfile), init:get_argument(kernel)} of
        {true, error, error, error} -> {ok, none};
        {true, {ok, [["inet_tls"]]}, {ok, [[Path]]},
         {ok, [["connect_all", "false"]]}} ->
            case unicode:characters_to_binary(Path) of
                Binary when is_binary(Binary) -> {ok, {some, Binary}};
                _ -> {error, nil}
            end;
        _ -> {error, nil}
    end.

%% Boot preconditions come first and name what failed, because the operator
%% has to act on it. Only then are credentials read and distribution started.
start(Local, Peers, Files, Listen, Members) ->
    case validate_checked(Local, Peers, Files, Members) of
        {ok, CookieBytes} -> start_checked(Local, Peers, CookieBytes, Listen, Members);
        {error, Refusal} -> {error, Refusal}
    end.

%% Validation performs only bounded reads and emulator argument inspection.
%% Startup repeats it immediately before any distribution side effects.
validate(Local, Peers, Files, Members) ->
    case validate_checked(Local, Peers, Files, Members) of
        {ok, _CookieBytes} -> {ok, nil};
        {error, Refusal} -> {error, Refusal}
    end.

validate_checked(Local, Peers, Files, Members) ->
    case boot_refusal(Peers, Files, Members) of
        none -> validate_credentials(Local, Files);
        Refusal -> {error, Refusal}
    end.

boot_refusal(Peers, Files, Members) ->
    Checks = [
        {already_distributed, fun() -> not erlang:is_alive() end},
        {unsupported_otp, fun() ->
            list_to_integer(erlang:system_info(otp_release)) >= 29 end},
        {not_tls_distribution, fun() ->
            init:get_argument(proto_dist) =:= {ok, [["inet_tls"]]} end},
        {options_file_unset, fun() ->
            case init:get_argument(ssl_dist_optfile) of
                {ok, [[_]]} -> true;
                _ -> false
            end end},
        {conflicting_boot_flag, fun() ->
            lists:all(fun(Flag) -> init:get_argument(Flag) =:= error end,
                      [ssl_dist_opt, name, sname, setcookie, nocookie]) end},
        {options_mismatch, fun() -> options_match(Peers, Files) end},
        %% A visible member with connect_all on would let `global` connect it
        %% to every node a peer is connected to. The application environment
        %% is read, not the argument vector, so a sys.config setting counts.
        {connect_all_enabled, fun() ->
            Members =:= none orelse
                application:get_env(kernel, connect_all) =:= {ok, false} end}],
    case [Reason || {Reason, Holds} <- Checks, not Holds()] of
        [First | _] -> First;
        [] -> none
    end.

%% The loaded options file must be private and must be exactly what this
%% configuration generates. Anything else could widen the trusted set.
options_match(Peers, Files) ->
    try
        {ok, [[OptionFile]]} = init:get_argument(ssl_dist_optfile),
        _ = bounded_file(OptionFile, 262144, private),
        tls_options(Peers, Files) =:= ssl_dist_sup:consult(OptionFile)
    catch _:_ -> false
    end.

validate_credentials(Local, {credential_files, Ca, Cert, Key, Cookie}) ->
    try
        %% Finite reads and private modes are checked before the listener starts.
        CaPem = bounded_file(Ca, 262144, public),
        CertPem = bounded_file(Cert, 262144, public),
        KeyPem = bounded_file(Key, 32768, private),
        CookieBytes = bounded_file(Cookie, 128, private),
        %% The emulator reads its cookie from the init home at listener start,
        %% so the configured file must be that file, never another one.
        {ok, [[Home]]} = init:get_argument(home),
        Cookie = unicode:characters_to_binary(filename:join(Home, ".erlang.cookie")),
        true = byte_size(CookieBytes) >= 16,
        true = lists:all(fun(C) ->
            (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $-
        end, binary_to_list(CookieBytes)),
        [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(CertPem),
        true = exact_node_san(public_key:pkix_decode_cert(Der, otp),
                              binary_to_list(Local)),
        true = valid_ca_certificates(CaPem),
        true = private_key_matches(KeyPem, Der),
        {ok, CookieBytes}
    catch
        _:_ -> {error, invalid_credentials}
    end.

%% SSL accepts a bundle of CA certificates. Decode every certificate without
%% requiring the local leaf to chain to a trust store for remote peers.
valid_ca_certificates(Pem) ->
    Certificates = [Der || {'Certificate', Der, not_encrypted} <-
                                public_key:pem_decode(Pem)],
    Certificates =/= [] andalso lists:all(fun(Der) ->
        _ = public_key:pkix_decode_cert(Der, otp), true
    end, Certificates).

%% Decode the same key-entry types and default empty password SSL accepts.
%% Prove possession against the certificate's public key using OTP primitives,
%% rather than assuming that a readable private key belongs to this leaf.
private_key_matches(Pem, CertDer) ->
    Entries = [Entry || Entry = {Type, _, _} <- public_key:pem_decode(Pem),
                        lists:member(Type, ['RSAPrivateKey', 'DSAPrivateKey',
                                            'ECPrivateKey', 'PrivateKeyInfo'])],
    [Entry] = Entries,
    Private = public_key:pem_entry_decode(Entry, ""),
    #'Certificate'{tbsCertificate = Tbs} = public_key:der_decode('Certificate', CertDer),
    Spki = Tbs#'TBSCertificate'.subjectPublicKeyInfo,
    SpkiDer = public_key:der_encode('SubjectPublicKeyInfo', Spki),
    Public = public_key:pem_entry_decode({'SubjectPublicKeyInfo', SpkiDer, not_encrypted}),
    Message = <<"loom distribution credential validation">>,
    lists:any(fun(Hash) ->
        try
            Signature = public_key:sign(Message, Hash, Private),
            public_key:verify(Message, Hash, Signature, Public)
        catch _:_ -> false
        end
    end, [sha256, sha, none]).

start_checked(Local, Peers, CookieBytes, Listen, Members) ->
    try
        ok = application:set_env(kernel, dist_auto_connect, never),
        ok = application:set_env(kernel, net_setuptime, 5),
        ok = set_listen(Listen),
        LocalNode = binary_to_atom(Local, utf8),
        Nodes = peer_nodes(Peers),
        %% Credentials are good by now, so a failure from here on is the
        %% environment's and gets its own error rather than a credential one.
        ok = case ensure_epmd() of
            ok -> ok;
            error -> throw({epmd_unavailable, epmd_port()})
        end,
        ok = case start_net(LocalNode, Members =:= none) of
            ok -> ok;
            error -> throw(start_failed)
        end,
        CookieBytes = atom_to_binary(erlang:get_cookie(), utf8),
        ok = net_kernel:allow([Node || {_Name, Node} <- Nodes]),
        {ok, {membership, LocalNode, mode_nodes(Peers, Nodes),
              member_nodes(Nodes, Members)}}
    catch
        Class:Reason ->
            %% A partial boot never returns membership.
            _ = net_kernel:stop(),
            {error, failure(Class, Reason)}
    end.

%% Static mode makes one atom per configured peer. Live mode makes none at
%% start: the ledger will make each atom when it applies a signed entry.
peer_nodes(live) -> [];
peer_nodes(Peers) -> [{Name, binary_to_atom(Name, utf8)} || {Name, _Pin} <- Peers].

%% Only the two environment failures raised above keep their own name. Any
%% other exception comes from reading or matching a credential.
failure(throw, {epmd_unavailable, _} = Refusal) -> Refusal;
failure(throw, start_failed) -> start_failed;
failure(_, _) -> invalid_credentials.

%% What the membership value remembers of its peers: the atoms made at start in
%% static mode, and the atom `live` in live mode, where the peers are whatever
%% the table holds when a name is resolved.
mode_nodes(live, _Nodes) -> live;
mode_nodes(_Peers, Nodes) -> Nodes.

%% The peers that are directory members, as the atoms made for them above. A
%% member name that is not a configured peer makes no atom and is dropped; the
%% configuration reader has already refused such a name.
member_nodes(_Nodes, none) -> [];
member_nodes(Nodes, {some, Names}) ->
    [Node || {Name, Node} <- Nodes, lists:member(Name, Names)].

start_net(LocalNode, Hidden) ->
    try net_kernel:start(LocalNode, #{name_domain => longnames, hidden => Hidden}) of
        {ok, _} -> ok;
        _ -> error
    catch _:_ -> error
    end.

%% ------------------------------------------------------------------- epmd
%%
%% `erl -name` launches epmd before the emulator starts, so a node booted with
%% a name always finds one. Loom boots the daemon VM without a name and calls
%% net_kernel:start/2 later, and OTP does not launch epmd on that path: the
%% node then fails to register with `econnrefused` on any machine where no
%% other VM happened to start an epmd first. This function does what the
%% boot-time `-name` path does. It is FFI because launching the executable in
%% the release's erts directory needs `open_port` with `spawn_executable`, and
%% asking epmd who is registered needs `erl_epmd:names/1`; gleam_erlang,
%% gleam_otp and weft expose neither.

-define(EPMD_DEFAULT_PORT, 4369).
-define(EPMD_PROBE_MS, 500).
-define(EPMD_WAIT_MS, 3000).

%% Makes sure an epmd answers on the port this VM's epmd client uses, starting
%% one if none does. `-start_epmd false` is the operator's statement that epmd
%% is managed elsewhere, for instance reached through a tunnel, so it is
%% honoured exactly as the emulator honours it at boot. ERL_EPMD_PORT and
%% ERL_EPMD_ADDRESS are not read here: the emulator has turned the port into
%% the `epmd_port` argument, and the epmd daemon reads both variables from the
%% environment it inherits from this VM.
ensure_epmd() ->
    case init:get_argument(start_epmd) of
        {ok, [["false"]]} -> ok;
        _ ->
            case epmd_answers() of
                true -> ok;
                false ->
                    case launch_epmd() of
                        ok ->
                            await_epmd(erlang:monotonic_time(millisecond)
                                       + ?EPMD_WAIT_MS);
                        error -> error
                    end
            end
    end.

%% The port the emulator's epmd client uses, as erl_epmd computes it.
epmd_port() ->
    case init:get_argument(epmd_port) of
        {ok, [[Port | _] | _]} -> list_to_integer(Port);
        error -> ?EPMD_DEFAULT_PORT
    end.

%% Asks the loopback epmd for its names. epmd always listens on loopback, even
%% under ERL_EPMD_ADDRESS, and the node registers there. The question runs in
%% its own process under a deadline, because erl_epmd waits without a timeout
%% and a port held by something that accepts and never answers must not hang
%% daemon startup.
epmd_answers() ->
    Self = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Self ! {Ref, erl_epmd:names({127,0,0,1})}
    end),
    receive
        {Ref, {ok, _}} -> erlang:demonitor(Monitor, [flush]), true;
        {Ref, _} -> erlang:demonitor(Monitor, [flush]), false;
        {'DOWN', Monitor, process, Pid, _} -> false
    after ?EPMD_PROBE_MS ->
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush]),
        receive {Ref, _} -> ok after 0 -> ok end,
        false
    end.

%% `epmd -daemon` forks and the parent exits at once, so the exit status says
%% nothing about whether the daemon bound its port. await_epmd/1 is the check.
%% The release's own epmd goes first, since a shipped release carries the epmd
%% that matches its emulator, and the executable on PATH is the fallback for a
%% VM run from a source install.
launch_epmd() ->
    case epmd_executable() of
        false -> error;
        Path ->
            Args = ["-daemon" | epmd_port_arguments()],
            Port = open_port({spawn_executable, Path},
                             [{args, Args}, exit_status, use_stdio, hide]),
            receive {Port, {exit_status, _}} -> ok after 5000 -> ok end,
            try port_close(Port) catch error:badarg -> ok end,
            flush_port(Port)
    end.

epmd_executable() ->
    Bundled = filename:join([code:root_dir(),
        "erts-" ++ erlang:system_info(version), "bin", "epmd"]),
    case filelib:is_regular(Bundled) of
        true -> Bundled;
        false -> os:find_executable("epmd")
    end.

%% A port given as a VM argument rather than as ERL_EPMD_PORT would not reach
%% the daemon through the environment, so it is passed on explicitly.
epmd_port_arguments() ->
    case init:get_argument(epmd_port) of
        {ok, [[Port | _] | _]} -> ["-port", Port];
        error -> []
    end.

flush_port(Port) ->
    receive {Port, _} -> flush_port(Port) after 0 -> ok end.

await_epmd(Deadline) ->
    case epmd_answers() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error;
                false -> timer:sleep(50), await_epmd(Deadline)
            end
    end.

set_listen({some, Port}) ->
    ok = application:set_env(kernel, inet_dist_listen_min, Port),
    ok = application:set_env(kernel, inet_dist_listen_max, Port);
set_listen(none) -> ok.

bounded_file(Path, Maximum, Privacy) ->
    {ok, #file_info{type = regular, size = Size, mode = Mode}} =
        file:read_link_info(Path),
    true = Size > 0 andalso Size =< Maximum,
    case Privacy of private -> 0 = Mode band 8#077; public -> ok end,
    {ok, Bytes} = file:read_file(Path),
    true = byte_size(Bytes) > 0 andalso byte_size(Bytes) =< Maximum,
    Bytes.

%% In live mode a name resolves when the table lists it, which means it is an
%% active member linked to this node. Its atom exists because the ledger process
%% made it with net_kernel:allow/1 when it applied the member's entry, so a name
%% that was never enrolled cannot make an atom here.
peer({membership, Local, live, _Members}, Name) ->
    case erlang:node() =:= Local andalso erlang:is_alive() of
        true -> live_peer(Name);
        false -> {error, unavailable}
    end;
peer({membership, Local, Nodes, _Members}, Name) ->
    case erlang:node() =:= Local andalso erlang:is_alive() of
        true ->
            case lists:keyfind(Name, 1, Nodes) of
                {Name, Node} -> {ok, Node};
                false -> {error, invalid_configuration}
            end;
        false -> {error, unavailable}
    end.

live_peer(Name) ->
    case live_pins() of
        {ok, Pins} ->
            try lists:member(Name, maps:values(Pins)) of
                true -> {ok, binary_to_existing_atom(Name, utf8)};
                false -> {error, invalid_configuration}
            catch error:badarg -> {error, unavailable}
            end;
        unavailable -> {error, unavailable}
    end.

%% How this node connects to a peer: visibly when both are directory members,
%% hidden otherwise. The list of members is empty on a node that is not one.
link({membership, _Local, live, _Members}, Node) ->
    case directory_names() of
        {ok, Names} ->
            case lists:member(atom_to_binary(Node, utf8), Names) of
                true -> visible;
                false -> hidden
            end;
        unavailable -> hidden
    end;
link({membership, _Local, _Nodes, Members}, Node) ->
    case lists:member(Node, Members) of
        true -> visible;
        false -> hidden
    end.

%% In ledger mode the members are whatever the published row names now: the
%% atoms of a static boot do not exist, and a ledger entry can seat a node while
%% the VM runs. A missing table or row is hidden, which is the safe link.
directory_names() ->
    try ets:lookup(?PIN_TABLE, ?DIRECTORY_ROW) of
        [{?DIRECTORY_ROW, Names}] when is_list(Names) -> {ok, Names};
        _ -> unavailable
    catch error:badarg -> unavailable
    end.

connect(Node, visible) -> connected(net_kernel:connect_node(Node));
connect(Node, hidden) -> connected(net_kernel:hidden_connect_node(Node)).

connected(true) -> {ok, nil};
connected(_) -> {error, unavailable}.
