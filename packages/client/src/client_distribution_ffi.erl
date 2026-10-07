%% OTP-only primitives for trusted TLS distribution, reached only through
%% client/internal/ffi_distribution.gleam. Neither gleam_erlang, gleam_otp nor
%% weft can express any of these: the TLS verify callback runs inside the ssl
%% handshake, net_kernel:start/2 and net_kernel:hidden_connect_node/1 are not
%% wrapped, and the boot checks read the emulator's own argument vector.
%%
%% The one certificate callback keeps every PKIX failure and, for the leaf,
%% additionally requires a configured SHA-256 pin together with the exact
%% full-node DNS name in the subject alternative names. No network input is
%% ever turned into an atom: peer names become atoms once, from the finite
%% configuration, inside start/4.
-module(client_distribution_ffi).
-export([options/2, start/4, peer/2, connect/1, verify/4]).
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
        {ok, _} = net_kernel:start(LocalNode,
            #{name_domain => longnames, hidden => true}),
        CookieBytes = atom_to_binary(erlang:get_cookie(), utf8),
        ok = net_kernel:allow([Node || {_Name, Node} <- Nodes]),
        {ok, {membership, LocalNode, Nodes}}
    catch
        _:_ ->
            %% A partial boot never returns membership.
            _ = net_kernel:stop(),
            {error, invalid_credentials}
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
