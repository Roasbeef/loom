%% OTP-only primitives unavailable in gleam_erlang/gleam_otp/weft. The sole
%% certificate callback retains PKIX failures and checks an administrative leaf
%% pin together with the exact full-node DNS SAN. No network input makes atoms.
-module(executor_distribution_ffi).
-export([options/2, start/3, peer/2, connect/1, send/2, verify/4,
         register_endpoint/1, endpoint/2, boot_arguments/2, protected_paths/1, bootstrap_home/1]).
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

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
        false -> {fail, executor_identity_mismatch}
    end.

exact_node_san(#'OTPCertificate'{tbsCertificate = Tbs}, Name) ->
    case lists:keyfind(?'id-ce-subjectAltName', #'Extension'.extnID,
                      Tbs#'OTPTBSCertificate'.extensions) of
        #'Extension'{extnValue = Names} ->
            [Name] =:= [Dns || {dNSName, Dns} <- Names, lists:member($@, Dns)];
        _ -> false
    end.

start(Local, Peers, Files) ->
    try
        %% Refuse pre-existing distribution: boot admission must precede any
        %% endpoint and may never enlarge an existing administrative atom set.
        false = erlang:is_alive(),
        "29" = erlang:system_info(otp_release),
        {ok, [["inet_tls"]]} = init:get_argument(proto_dist),
        error = init:get_argument(ssl_dist_opt),
        error = init:get_argument(name),
        error = init:get_argument(sname),
        error = init:get_argument(setcookie),
        error = init:get_argument(nocookie),
        undefined = persistent_term:get({?MODULE, boot_attempted}, undefined),
        {ok, [[OptionFile]]} = init:get_argument(ssl_dist_optfile),
        _ = bounded_file(OptionFile, 262144, private),
        Expected = tls_options(Peers, Files),
        Expected = ssl_dist_sup:consult(OptionFile),
        start_checked(Local, Peers, Files, unicode:characters_to_binary(OptionFile))
    catch
        _:_ -> {error, unsafe_boot}
    end.

start_checked(Local, Peers, {credential_files, Ca, Cert, Key, Cookie}, Options) ->
    try
        %% Files remain administrator-owned throughout this VM lifetime.
        %% Finite reads and private modes are checked before the listener starts.
        _ = bounded_file(Ca, 262144, public),
        CertPem = bounded_file(Cert, 262144, public),
        _ = bounded_file(Key, 32768, private),
        CookieBytes = bounded_file(Cookie, 128, private),
        {ok, [[Home]]} = init:get_argument(home),
        Cookie = unicode:characters_to_binary(filename:join(Home, ".erlang.cookie")),
        {ok, #file_info{type = directory, mode = HomeMode}} = file:read_link_info(Home),
        0 = HomeMode band 8#077,
        true = byte_size(CookieBytes) >= 16,
        true = lists:all(fun(C) ->
            (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $-
        end, binary_to_list(CookieBytes)),
        [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(CertPem),
        Certificate = public_key:pkix_decode_cert(Der, otp),
        true = exact_node_san(Certificate, binary_to_list(Local)),
        ok = application:set_env(kernel, dist_auto_connect, never),
        ok = application:set_env(kernel, net_setuptime, 5),
        persistent_term:put({?MODULE, boot_attempted}, true),
        LocalNode = binary_to_atom(Local, utf8),
        Nodes = [{Name, binary_to_atom(Name, utf8)} || {Name, _Pin} <- Peers],
        {ok, _} = net_kernel:start(LocalNode,
            #{name_domain => longnames, hidden => true}),
        %% auth reads the already checked private init-home cookie before
        %% net_kernel opens its listener. No operator HOME read/write occurs.
        CookieBytes = atom_to_binary(erlang:get_cookie(), utf8),
        ok = net_kernel:allow([Node || {_Name, Node} <- Nodes]),
        {ok, {membership, LocalNode, Nodes, [Ca, Cert, Key, Cookie, Options]}}
    catch
        _:_ ->
            %% A partial boot never returns membership. Stop the dynamic
            %% distribution subtree, including any initial authenticated lane.
            _ = net_kernel:stop(),
            {error, invalid_credentials}
    end.

bounded_file(Path, Maximum, Privacy) ->
    canonical_path(Path),
    {ok, #file_info{type = regular, size = Size, mode = Mode}} =
        file:read_link_info(Path),
    true = Size > 0 andalso Size =< Maximum,
    case Privacy of private -> 0 = Mode band 8#077; public -> ok end,
    {ok, Bytes} = file:read_file(Path),
    true = byte_size(Bytes) > 0 andalso byte_size(Bytes) =< Maximum,
    Bytes.

canonical_path(Path) ->
    absolute = filename:pathtype(Path),
    Parts = filename:split(Path),
    Spelling = unicode:characters_to_binary(Path),
    Spelling = unicode:characters_to_binary(filename:join(Parts)),
    false = lists:any(fun(Part) -> Part =:= <<"..">> orelse Part =:= <<".">>
        orelse Part =:= ".." orelse Part =:= "." end, Parts),
    %% Refusing symlink ancestors makes the retained spelling the actual
    %% protected root, rather than protecting an alias visible in another jail.
    _ = lists:foldl(fun(Part, Parent) ->
        Current = case Parent of [] -> Part; _ -> filename:join(Parent, Part) end,
        {ok, #file_info{type = Type}} = file:read_link_info(Current),
        true = Type =/= symlink,
        Current
    end, [], Parts),
    ok.

boot_arguments({credential_files, _, _, _, Cookie}, Options) ->
    _ = Cookie,
    %% An absent launcher HOME restores as empty, never the private OTP home.
    Home = case os:getenv("HOME") of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end,
    [<<"-env">>, <<"HOME">>, Home,
        <<"-proto_dist">>, <<"inet_tls">>, <<"-ssl_dist_optfile">>, Options].

bootstrap_home({credential_files, _, _, _, Cookie}) ->
    unicode:characters_to_binary(filename:dirname(Cookie)).

protected_paths({membership, _, _, Paths}) -> Paths.

peer({membership, Local, Nodes, _Paths}, Name) ->
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

send({subject, Pid, Tag}, Message) when is_pid(Pid),
        (is_reference(Tag) orelse Tag =:= <<"loom.executor.endpoint/1">>) ->
    case erlang:send(Pid, {Tag, Message}, [nosuspend, noconnect]) of
        ok -> sent;
        nosuspend -> would_block;
        noconnect -> disconnected
    end;
send(_, _) -> invalid_subject.

register_endpoint(Pid) when is_pid(Pid), node(Pid) =:= node() ->
    try true = register(loom_executor_endpoint, Pid), {ok, nil}
    catch _:_ -> {error, unavailable} end;
register_endpoint(_) -> {error, invalid_configuration}.

endpoint(Node, Within) when is_integer(Within), Within >= 1, Within =< 60000 ->
    %% The only remote function call is this literal administrative lookup.
    %% A resulting PID is an incarnation, never a durable effect identity.
    try erpc:call(Node, erlang, whereis, [loom_executor_endpoint], Within) of
        Pid when is_pid(Pid), node(Pid) =:= Node -> {ok, Pid};
        _ -> {error, unavailable}
    catch _:_ -> {error, unavailable} end;
endpoint(_, _) -> {error, invalid_configuration}.
