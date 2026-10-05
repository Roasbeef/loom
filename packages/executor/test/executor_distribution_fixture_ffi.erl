%% Test-only provisioning. No callback, MFA or term codec is part of the
%% production executor transport; fixture files are parent-owned local input.
-module(executor_distribution_fixture_ffi).
-export([provision/2, current_executable/0, node_arguments/1, run_node/4, write_provisioned/2, read_provisioned/1,
         credential/2, configuration/4, write_options/3, write_credentials/3]).
-include_lib("public_key/include/public_key.hrl").
-include_lib("kernel/include/file.hrl").

provision(Directory, Prefix) ->
    try
        true = byte_size(Prefix) >= 1 andalso byte_size(Prefix) =< 32,
        true = lists:all(fun(C) ->
            (C >= $a andalso C =< $z) orelse C =:= $_
        end, binary_to_list(Prefix)),
        absolute = filename:pathtype(Directory),
        ok = file:make_dir(Directory),
        ok = file:change_mode(Directory, 8#700),
        {ok, _} = application:ensure_all_started(ssl),
        Ca = public_key:pkix_test_root_cert("trusted BEAM fixture", key_options()),
        Suffix = integer_to_binary(erlang:system_time(nanosecond)),
        Owner = <<Prefix/binary, "_owner_", Suffix/binary, "@127.0.0.1">>,
        Executor = <<Prefix/binary, "_executor_", Suffix/binary, "@127.0.0.1">>,
        OwnerCred = credential(Ca, Owner),
        ExecutorCred = credential(Ca, Executor),
        OwnerFiles = write_credentials(Directory, "owner", OwnerCred),
        ExecutorFiles = write_credentials(Directory, "executor", ExecutorCred),
        OwnerConfig = configuration(Owner, Executor, ExecutorCred, OwnerFiles),
        ExecutorConfig = configuration(Executor, Owner, OwnerCred, ExecutorFiles),
        OwnerOptions = write_options(Directory, "owner", OwnerConfig),
        ExecutorOptions = write_options(Directory, "executor", ExecutorConfig),
        {ok, {provisioned, Directory, OwnerConfig, ExecutorConfig,
            OwnerOptions, ExecutorOptions, Owner, Executor}}
    catch _:_ -> {error, nil} end.

current_executable() ->
    unicode:characters_to_binary(filename:join([code:root_dir(),
        "erts-" ++ erlang:system_info(version), "bin", "erl"])).

node_arguments(Options) ->
    Paths = [unicode:characters_to_binary(filename:absname(Path)) || Path <- code:get_path()],
    Home = case os:getenv("HOME") of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end,
    [<<"+S">>, <<"2">>, <<"-pa">>] ++ Paths ++
        [<<"-env">>, <<"HOME">>, Home,
            <<"-proto_dist">>, <<"inet_tls">>, <<"-ssl_dist_optfile">>, Options].

run_node(Executable, Args, Directory, OtpHome) ->
    try
        Port = open_port({spawn_executable, binary_to_list(Executable)},
            [binary, exit_status, stderr_to_stdout,
             {cd, binary_to_list(Directory)},
             {env, [{"HOME", binary_to_list(OtpHome)}]},
             {args, [binary_to_list(Arg) || Arg <- Args]}]),
        collect(Port, <<>>)
    catch _:_ -> {error, <<"test BEAM launch failed">>} end.

collect(Port, Acc) ->
    receive
        {Port, {data, Bytes}} when byte_size(Acc) + byte_size(Bytes) =< 8388608 ->
            collect(Port, <<Acc/binary, Bytes/binary>>);
        {Port, {data, _}} ->
            port_close(Port), {error, <<"test BEAM output limit exceeded">>};
        {Port, {exit_status, Status}} -> {ok, {Status, Acc}}
    after 300000 ->
        port_close(Port), {error, <<"test BEAM launch timed out">>}
    end.

write_provisioned(Fixture, Path) ->
    try
        Bytes = term_to_binary(Fixture),
        true = byte_size(Bytes) =< 1048576,
        ok = file:write_file(Path, Bytes, [exclusive]),
        ok = file:change_mode(Path, 8#600),
        {ok, nil}
    catch _:_ -> {error, nil} end.

read_provisioned(Path) ->
    try
        {ok, #file_info{type = regular, size = Size}} = file:read_link_info(Path),
        true = Size > 0 andalso Size =< 1048576,
        {ok, Bytes} = file:read_file(Path),
        true = byte_size(Bytes) =< 1048576,
        {provisioned, _, _, _, _, _, _, _} = Fixture = binary_to_term(Bytes),
        {ok, Fixture}
    catch _:_ -> {error, nil} end.

configuration(Local, Peer, {_Ca, Cert, _Key}, Files) ->
    {ok, Config} = 'executor@remote@distribution':configure(Local,
        [{Peer, crypto:hash(sha256, Cert)}], Files),
    Config.
write_options(Directory, Name, Config) ->
    _ = Directory,
    {config, _, _, {credential_files, _, _, _, Cookie}} = Config,
    Path = filename:join(filename:dirname(Cookie), Name ++ ".options"),
    ok = file:write_file(Path, 'executor@remote@distribution':tls_options(Config)),
    ok = file:change_mode(Path, 8#600), unicode:characters_to_binary(Path).

key_options() -> [{digest, sha256}, {key, {namedCurve, secp256r1}}].
credential(Ca, Node) ->
    San = #'Extension'{extnID = ?'id-ce-subjectAltName',
        extnValue = [{dNSName, binary_to_list(Node)}, {dNSName, "127.0.0.1"},
            {iPAddress, <<127,0,0,1>>}], critical = false},
    #{server_config := Conf} = public_key:pkix_test_data(
        #{server_chain => #{root => Ca, intermediates => [],
            peer => key_options() ++ [{extensions, [San]}]},
          client_chain => #{root => [], intermediates => [], peer => []}}),
    {Type, Key} = proplists:get_value(key, Conf),
    {maps:get(cert, Ca), proplists:get_value(cert, Conf),
        public_key:pem_encode([{Type, Key, not_encrypted}])}.
write_credentials(Directory, Name, {Ca, Cert, Key}) ->
    Home = filename:join(Directory, Name),
    ok = file:make_dir(Home), ok = file:change_mode(Home, 8#700),
    [CaPath, CertPath, KeyPath] =
        [filename:join(Home, Name ++ Ext) || Ext <- [".ca", ".cert", ".key"]],
    CookiePath = filename:join(Home, ".erlang.cookie"),
    ok = file:write_file(CaPath, public_key:pem_encode([{'Certificate', Ca, not_encrypted}])),
    ok = file:write_file(CertPath, public_key:pem_encode([{'Certificate', Cert, not_encrypted}])),
    ok = file:write_file(KeyPath, Key),
    ok = file:write_file(CookiePath, <<"loom_bootstrap_test_cookie_0123456789">>),
    ok = file:change_mode(KeyPath, 8#600),
    ok = file:change_mode(CookiePath, 8#600),
    {credential_files, unicode:characters_to_binary(CaPath),
        unicode:characters_to_binary(CertPath), unicode:characters_to_binary(KeyPath),
        unicode:characters_to_binary(CookiePath)}.
