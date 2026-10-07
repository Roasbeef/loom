%% Independent OS BEAMs exercise real TLS; every child has a finite watchdog,
%% its own private OTP init home, and an explicit completion/exit witness.
-module(executor_distribution_test_ffi).
-export([probe/0, independent/3]).

probe() ->
    %% macOS resolves /tmp through /private; Linux has no /private directory.
    Tmp = case filelib:is_dir("/private/tmp") of
        true -> "/private/tmp";
        false -> "/tmp"
    end,
    Directory = unicode:characters_to_binary(filename:join(Tmp,
        "loom-beam-bootstrap-" ++ integer_to_list(erlang:system_time(nanosecond)))),
    ok = file:make_dir(Directory), ok = file:change_mode(Directory, 8#700),
    try controls(Directory), {ok, nil}
    catch Class:Reason:Stack ->
        io:format(standard_error, "BEAM bootstrap failure ~p:~p~n~p~n",
            [Class, Reason, Stack]), {error, nil}
    after file:del_dir_r(Directory) end.

controls(Directory) ->
    {ok, _} = application:ensure_all_started(ssl),
    Ca = public_key:pkix_test_root_cert("distribution controls",
        [{digest, sha256}, {key, {namedCurve, secp256r1}}]),
    Suffix = integer_to_binary(erlang:system_time(nanosecond)),
    Owner = <<"owner_", Suffix/binary, "@127.0.0.1">>,
    Executor = <<"executor_", Suffix/binary, "@127.0.0.1">>,
    Wrong = <<"wrong_", Suffix/binary, "@127.0.0.1">>,
    OwnerCred = executor_distribution_fixture_ffi:credential(Ca, Owner),
    ExecutorCred = executor_distribution_fixture_ffi:credential(Ca, Executor),
    OwnerFiles = executor_distribution_fixture_ffi:write_credentials(Directory, "owner", OwnerCred),
    ExecutorFiles = executor_distribution_fixture_ffi:write_credentials(Directory, "executor", ExecutorCred),
    OwnerConfig = executor_distribution_fixture_ffi:configuration(Owner, Executor, ExecutorCred, OwnerFiles),
    ExecutorConfig = executor_distribution_fixture_ffi:configuration(Executor, Owner, OwnerCred, ExecutorFiles),
    run_pair(Directory, "positive", OwnerConfig, ExecutorConfig, owner, executor, tls),
    io:format("TLS BEAM bootstrap, hidden explicit connection, fixed discovery, exact send and private cookie passed~n"),

    OtherCred = executor_distribution_fixture_ffi:credential(Ca, Executor),
    OtherFiles = executor_distribution_fixture_ffi:write_credentials(Directory, "other", OtherCred),
    OtherConfig = executor_distribution_fixture_ffi:configuration(Executor, Owner, OwnerCred, OtherFiles),
    run_pair(Directory, "wrong_pin", OwnerConfig, OtherConfig, reject, wait, tls),

    WrongCred = executor_distribution_fixture_ffi:credential(Ca, Wrong),
    WrongFiles = executor_distribution_fixture_ffi:write_credentials(Directory, "wrong", WrongCred),
    WrongConfig = executor_distribution_fixture_ffi:configuration(Executor, Owner, OwnerCred, WrongFiles),
    WrongOwner = executor_distribution_fixture_ffi:configuration(Owner, Executor, WrongCred, OwnerFiles),
    run_pair(Directory, "wrong_node", WrongOwner, WrongConfig, reject, wrong_node, tls),
    run_pair(Directory, "plaintext", OwnerConfig, ExecutorConfig, reject, plain, plain),
    missing_certificate(Directory, OwnerConfig, ExecutorConfig, Ca),
    cookie_controls(Directory, OwnerConfig, ExecutorConfig),
    io:format("Same-CA wrong leaf/node, missing client certificate, plaintext, wrong cookie and boot override controls passed~n").

run_pair(Directory, Name, OwnerConfig, ExecutorConfig, OwnerRole, ExecutorRole, Transport) ->
    OwnerOptions = executor_distribution_fixture_ffi:write_options(Directory, Name ++ "_owner", OwnerConfig),
    ExecutorOptions = executor_distribution_fixture_ffi:write_options(Directory, Name ++ "_executor", ExecutorConfig),
    ExecutorPort = open_vm(ExecutorOptions, ExecutorConfig, ExecutorRole, Transport, []),
    try
        await_ready(ExecutorPort, <<>>),
        OwnerPort = open_vm(OwnerOptions, OwnerConfig, OwnerRole, tls, []),
        try
            await_complete(OwnerPort, <<>>),
            case ExecutorRole of executor -> ok; _ -> true = port_command(ExecutorPort, <<"stop\n">>) end,
            await_complete(ExecutorPort, <<>>)
        after close_port(OwnerPort) end
    after close_port(ExecutorPort) end.

missing_certificate(Directory, OwnerConfig, ExecutorConfig, Ca) ->
    Options = executor_distribution_fixture_ffi:write_options(Directory, "missing_owner", OwnerConfig),
    OwnerPort = open_vm(Options, OwnerConfig, wait, tls, []),
    try
        await_ready(OwnerPort, <<>>),
        {config, _, _, {credential_files, _, _, _, Cookie}} = ExecutorConfig,
        MissingPath = filename:join(filename:dirname(Cookie), "missing.options"),
        Term = [{client, [{cacerts, [Ca]}, {verify, verify_peer},
            {versions, ['tlsv1.3', 'tlsv1.2']}, {log_level, none}]}],
        ok = file:write_file(MissingPath, io_lib:format("~p.~n", [Term])),
        Child = open_vm(MissingPath, ExecutorConfig, missing, tls, []),
        try await_complete(Child, <<>>) after close_port(Child) end,
        true = port_command(OwnerPort, <<"stop\n">>),
        await_complete(OwnerPort, <<>>)
    after close_port(OwnerPort) end.

cookie_controls(Directory, OwnerConfig, ExecutorConfig) ->
    {config, _, _, {credential_files, _, _, _, Cookie}} = ExecutorConfig,
    {ok, Original} = file:read_file(Cookie),
    ok = file:write_file(Cookie, <<"different_private_cookie_0123456789">>),
    run_pair(Directory, "wrong_cookie", OwnerConfig, ExecutorConfig, reject, wait, tls),
    ok = file:write_file(Cookie, Original),
    Options = executor_distribution_fixture_ffi:write_options(Directory, "override", OwnerConfig),
    Child = open_vm(Options, OwnerConfig, override, tls,
        ["-setcookie", "fixture_cookie_override_0123456789"]),
    try await_complete(Child, <<>>) after close_port(Child) end.

open_vm(Options, Config, Role, Transport, Extra) ->
    Args = [binary_to_list(Arg) || Arg <- executor_distribution_fixture_ffi:node_arguments(Options)],
    BootArgs = case Transport of tls -> Args; plain -> remove_tls(Args) end,
    Encoded = binary_to_list(base64:encode(term_to_binary(Config))),
    Eval = lists:flatten(io_lib:format("executor_distribution_test_ffi:independent(~p,~p,~p).",
        [Encoded, Role, Transport])),
    open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {env, [{"HOME", binary_to_list(filename:dirname(Options))}]},
         {args, BootArgs ++ Extra ++ ["-noshell", "-eval", Eval]}]).
remove_tls(["-proto_dist", _ | Rest]) -> remove_tls(Rest);
remove_tls(["-ssl_dist_optfile", _ | Rest]) -> remove_tls(Rest);
remove_tls([Arg | Rest]) -> [Arg | remove_tls(Rest)];
remove_tls([]) -> [].

independent(Encoded, Role, _Transport) ->
    spawn(fun() -> receive after 10000 -> halt(3) end end),
    try
        Config = binary_to_term(base64:decode(Encoded)),
        independent_role(Role, Config),
        io:format("BOOTSTRAP_COMPLETE~n"), halt(0)
    catch Class:Reason:Stack ->
        io:format("Independent failure ~p:~p ~p~n", [Class, Reason, Stack]), halt(2)
    end.

independent_role(override, Config) ->
    {error, unsafe_boot} = 'executor@remote@distribution':start(Config),
    false = is_alive();
independent_role(missing, {config, Local, [{Target, _}], _} = Config) ->
    {error, unsafe_boot} = 'executor@remote@distribution':start(Config),
    raw_start(Local),
    false = net_kernel:hidden_connect_node(binary_to_atom(Target, utf8)),
    [] = nodes(connected);
independent_role(plain, {config, Local, _, _} = Config) ->
    {error, unsafe_boot} = 'executor@remote@distribution':start(Config),
    raw_start(Local), ready_and_wait();
independent_role(wrong_node, {config, Local, _, _} = Config) ->
    {error, invalid_credentials} = 'executor@remote@distribution':start(Config),
    raw_start(Local), ready_and_wait();
independent_role(Role, {config, _, [{Target, _}], _} = Config) ->
    {ok, Membership} = 'executor@remote@distribution':start(Config),
    [_, _, _, Cookie, Options] = 'executor@remote@distribution':protected_membership_paths(Membership),
    ".erlang.cookie" = filename:basename(binary_to_list(Cookie)),
    {ok, [[Home]]} = init:get_argument(home),
    false = filelib:is_file(filename:join(Home, "unexpected.cookie")),
    true = filelib:is_file(Options),
    {error, unsafe_boot} = 'executor@remote@distribution':start(Config),
    {ok, Peer} = 'executor@remote@distribution':peer(Membership, Target),
    {error, invalid_configuration} = 'executor@remote@distribution':peer(Membership,
        <<"network_input@127.0.0.1">>),
    run_role(Role, Peer).

run_role(wait, _Peer) -> ready_and_wait();
run_role(reject, Peer) ->
    {error, unavailable} = 'executor@remote@distribution':connect(Peer, 5000),
    [] = nodes(connected);
run_role(executor, _Peer) ->
    {ok, nil} = 'executor@remote@distribution':register_endpoint(self()),
    io:format("FIXTURE_READY~n"),
    receive
        {<<"loom.executor.endpoint/1">>, {probe, Reply}} ->
            sent = 'executor@remote@distribution':send(Reply, <<"exact_tls_payload">>),
            receive {<<"loom.executor.endpoint/1">>, consumed} -> ok after 3000 -> error(no_consumption) end
    after 5000 -> error(missing_probe) end;
run_role(owner, Peer) ->
    {ok, nil} = 'executor@remote@distribution':connect(Peer, 4000),
    [] = nodes(), [_] = nodes(hidden),
    {ok, never} = application:get_env(kernel, dist_auto_connect),
    {ok, Endpoint} = 'executor@remote@distribution':endpoint(Peer, 1000),
    true = 'executor@remote@distribution':owns(Peer, Endpoint),
    false = 'executor@remote@distribution':owns(Peer, self()),
    Reply = 'gleam@erlang@process':new_subject(),
    Subject = {subject, Endpoint, <<"loom.executor.endpoint/1">>},
    sent = 'executor@remote@distribution':send(Subject, {probe, Reply}),
    {ok, <<"exact_tls_payload">>} = 'gleam@erlang@process':'receive'(Reply, 2000),
    sent = 'executor@remote@distribution':send(Subject, consumed),
    invalid_subject = 'executor@remote@distribution':send({named_subject, forbidden}, <<"no">>).

raw_start(Name) ->
    ok = application:set_env(kernel, dist_auto_connect, never),
    ok = application:set_env(kernel, net_setuptime, 2),
    {ok, _} = net_kernel:start(binary_to_atom(Name, utf8),
        #{name_domain => longnames, hidden => true}).
ready_and_wait() ->
    io:format("FIXTURE_READY~n"), "stop\n" = io:get_line("").

await_ready(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            All = <<Acc/binary, Data/binary>>,
            case binary:match(All, <<"FIXTURE_READY">>) of
                nomatch -> await_ready(Port, All); _ -> ok end;
        {Port, {exit_status, Status}} -> error({early_fixture_exit, Status, Acc})
    after 6000 -> error(fixture_ready_timeout) end.
await_complete(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            All = <<Acc/binary, Data/binary>>,
            true = byte_size(All) =< 65536,
            await_complete(Port, All);
        {Port, {exit_status, 0}} ->
            case binary:match(Acc, <<"BOOTSTRAP_COMPLETE">>) of
                nomatch -> error(missing_final_witness); _ -> ok end;
        {Port, {exit_status, Status}} -> error({child_exit, Status, Acc})
    after 12000 -> error(child_timeout) end.
close_port(Port) -> try port_close(Port) catch _:_ -> ok end.
