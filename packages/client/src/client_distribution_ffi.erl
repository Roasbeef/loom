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
%% configuration, inside start/4.
-module(client_distribution_ffi).
-export([options/2, start/4, peer/2, connect/1, verify/4, ensure_epmd/0]).
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

%% The ssl_dist_optfile text for a configuration. The same term is rebuilt in
%% start/4 and compared with what the emulator actually loaded, so the file
%% cannot drift from the configuration the daemon validated.
options(Peers, Files) ->
    unicode:characters_to_binary(io_lib:format("~p.~n", [tls_options(Peers, Files)])).

tls_options(Peers, {credential_files, Ca, Cert, Key, _Cookie}) ->
    Pins = [{binary_to_list(Name), Pin} || {Name, Pin} <- Peers],
    Shared = [{cacertfile, binary_to_list(Ca)},
              {certfile, binary_to_list(Cert)},
              {keyfile, binary_to_list(Key)},
              {verify, verify_peer},
              {versions, ['tlsv1.3', 'tlsv1.2']},
              {verify_fun, {fun ?MODULE:verify/4, Pins}},
              {log_level, none}],
    [{server, [{fail_if_no_peer_cert, true} | Shared]}, {client, Shared}].

verify(_Cert, _Der, {bad_cert, Reason}, _Pins) -> {fail, Reason};
verify(_Cert, _Der, {extension, _}, Pins) -> {unknown, Pins};
verify(_Cert, _Der, valid, Pins) -> {valid, Pins};
verify(Cert, Der, valid_peer, Pins) ->
    Digest = crypto:hash(sha256, Der),
    case lists:any(fun({Name, Pin}) ->
        Digest =:= Pin andalso exact_node_san(Cert, Name)
    end, Pins) of
        true -> {valid, Pins};
        false -> {fail, peer_identity_mismatch}
    end.

%% Exactly one DNS name in the certificate contains an at sign, and it is the
%% node name. Host-only names may accompany it for the TLS hostname check.
exact_node_san(#'OTPCertificate'{tbsCertificate = Tbs}, Name) ->
    case lists:keyfind(?'id-ce-subjectAltName', #'Extension'.extnID,
                      Tbs#'OTPTBSCertificate'.extensions) of
        #'Extension'{extnValue = Names} ->
            [Name] =:= [Dns || {dNSName, Dns} <- Names, lists:member($@, Dns)];
        _ -> false
    end.

%% Boot preconditions come first and name what failed, because the operator
%% has to act on it. Only then are credentials read and distribution started.
start(Local, Peers, Files, Listen) ->
    case boot_refusal(Peers, Files) of
        none -> start_checked(Local, Peers, Files, Listen);
        Refusal -> {error, Refusal}
    end.

boot_refusal(Peers, Files) ->
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
        {options_mismatch, fun() -> options_match(Peers, Files) end}],
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

start_checked(Local, Peers, {credential_files, Ca, Cert, Key, Cookie}, Listen) ->
    try
        %% Finite reads and private modes are checked before the listener starts.
        _ = bounded_file(Ca, 262144, public),
        CertPem = bounded_file(Cert, 262144, public),
        _ = bounded_file(Key, 32768, private),
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
        ok = application:set_env(kernel, dist_auto_connect, never),
        ok = application:set_env(kernel, net_setuptime, 5),
        ok = set_listen(Listen),
        LocalNode = binary_to_atom(Local, utf8),
        Nodes = [{Name, binary_to_atom(Name, utf8)} || {Name, _Pin} <- Peers],
        %% Credentials are good by now, so a failure from here on is the
        %% environment's and gets its own error rather than a credential one.
        ok = case ensure_epmd() of
            ok -> ok;
            error -> throw({epmd_unavailable, epmd_port()})
        end,
        ok = case start_net(LocalNode) of
            ok -> ok;
            error -> throw(start_failed)
        end,
        CookieBytes = atom_to_binary(erlang:get_cookie(), utf8),
        ok = net_kernel:allow([Node || {_Name, Node} <- Nodes]),
        {ok, {membership, LocalNode, Nodes}}
    catch
        Class:Reason ->
            %% A partial boot never returns membership.
            _ = net_kernel:stop(),
            {error, failure(Class, Reason)}
    end.

%% Only the two environment failures raised above keep their own name. Any
%% other exception comes from reading or matching a credential.
failure(throw, {epmd_unavailable, _} = Refusal) -> Refusal;
failure(throw, start_failed) -> start_failed;
failure(_, _) -> invalid_credentials.

start_net(LocalNode) ->
    try net_kernel:start(LocalNode, #{name_domain => longnames, hidden => true}) of
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

peer({membership, Local, Nodes}, Name) ->
    case erlang:node() =:= Local andalso erlang:is_alive() of
        true ->
            case lists:keyfind(Name, 1, Nodes) of
                {Name, Node} -> {ok, Node};
                false -> {error, invalid_configuration}
            end;
        false -> {error, unavailable}
    end.

connect(Node) ->
    case net_kernel:hidden_connect_node(Node) of
        true -> {ok, nil};
        _ -> {error, unavailable}
    end.
