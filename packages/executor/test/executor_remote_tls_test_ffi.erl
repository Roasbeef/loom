%% Per-test ephemeral credentials: no persistent_term or shared fixture keys.
-module(executor_remote_tls_test_ffi).
-export([fixture/0, raw_send/2, missing_certificate/2, tcp_connect/1, tcp_close/1,
         connect_deadline/1, deadline_probe/1, delayed_tcp/4, observed_ssl/3,
         observed_now/0]).
-include_lib("public_key/include/public_key.hrl").

fixture() ->
    {ok, _} = application:ensure_all_started(ssl),
    Root = public_key:pkix_test_root_cert("executor tls fixture", key_options()),
    Foreign = public_key:pkix_test_root_cert("executor tls foreign", key_options()),
    {fixture, credentials(Root, []), credentials(Root, []),
     credentials(Root, []), credentials(Root, []), credentials(Foreign, []),
     credentials(Root, [{validity, {{2020,1,1}, {2020,1,2}}}])}.

key_options() -> [{digest, sha256}, {key, {namedCurve, secp256r1}}].
credentials(Root, Extra) ->
    San = #'Extension'{extnID = ?'id-ce-subjectAltName',
        extnValue = [{dNSName, "localhost"}], critical = false},
    #{server_config := Conf} = public_key:pkix_test_data(
        #{server_chain => #{root => Root, intermediates => [],
            peer => key_options() ++ [{extensions, [San]}] ++ Extra},
          client_chain => #{root => [], intermediates => [], peer => []}}),
    Cert = proplists:get_value(cert, Conf),
    {Type, Der} = proplists:get_value(key, Conf),
    Pem = public_key:pem_encode([{Type, Der, not_encrypted}]),
    {credentials, maps:get(cert, Root), Cert, Pem, crypto:hash(sha256, Cert)}.

%% Only test code can bypass framing to exercise hostile prefixes/fragments.
raw_send({connection, Socket, _, _}, Bytes) ->
    case ssl:send(Socket, Bytes) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% A client without credentials still verifies the real server. In TLS 1.3
%% connect can return before the server rejects the absent client certificate.
missing_certificate(Ca, Port) ->
    Opts = [{cacerts, [Ca]}, {verify, verify_peer}, {active, false},
        {mode, binary}, {versions, ['tlsv1.3','tlsv1.2']}, {log_level, none},
        {customize_hostname_check,
         [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case ssl:connect("localhost", Port, Opts, 2000) of
        {ok, Socket} ->
            _ = ssl:send(Socket, <<0,0,0,1,42>>),
            Result = ssl:recv(Socket, 1, 2000),
            _ = ssl:close(Socket, 0),
            case Result of {error, _} -> {ok, nil}; _ -> {error, nil} end;
        {error, _} -> {ok, nil}
    end.

%% A connected TCP peer that deliberately never begins TLS.
tcp_connect(Port) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 1000) of
        {ok, Socket} -> {ok, Socket};
        {error, _} -> {error, nil}
    end.
tcp_close(Socket) -> gen_tcp:close(Socket), nil.

%% Instrument only the two OTP call sites in the real production module. A
%% separate emulator confines code loading even when EUnit runs in parallel.
%% The serialized closure still enters public tls.connect with real settings.
connect_deadline(Connect) ->
    Encoded = binary_to_list(base64:encode(term_to_binary(Connect))),
    Eval = "executor_remote_tls_test_ffi:deadline_probe(binary_to_term(base64:decode(\""
        ++ Encoded ++ "\"))).",
    Paths = [filename:absname(P) || P <- code:get_path()],
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {args, ["+S", "2", "-pa"] ++ Paths ++ ["-noshell", "-eval", Eval]}]),
    probe_exit(Port).

probe_exit(Port) ->
    receive
        {Port, {data, Bytes}} ->
            io:put_chars(standard_error, Bytes), probe_exit(Port);
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, _}} -> {error, nil}
    after 10000 -> port_close(Port), {error, nil}
    end.

deadline_probe(Connect) ->
    %% A stuck fixture cannot leave an emulator behind its parent test.
    spawn(fun() -> receive after 6000 -> erlang:halt(2) end end),
    try
        {ok, _} = application:ensure_all_started(ssl),
        {ok, Forms} = epp:parse_file("src/executor_tls_ffi.erl", [], []),
        {ok, executor_tls_ffi, Binary} = compile:forms(instrument(Forms), [binary]),
        {module, executor_tls_ffi} = code:load_binary(executor_tls_ffi, "deadline-probe", Binary),
        lists:foreach(fun(Delay) -> stalled_connect(Connect, Delay) end, [250, 450]),
        erlang:halt(0)
    catch Class:Reason:Stack ->
        io:format(standard_error, "TLS deadline probe failed: ~p:~p~n~p~n",
            [Class, Reason, Stack]),
        erlang:halt(1)
    end.

instrument({call, L, {remote, R, {atom, M, gen_tcp}, {atom, F, connect}}, Args})
        when length(Args) =:= 4 ->
    {call, L, {remote, R, {atom, M, ?MODULE}, {atom, F, delayed_tcp}}, instrument(Args)};
instrument({call, L, {remote, R, {atom, M, ssl}, {atom, F, connect}}, Args})
        when length(Args) =:= 3 ->
    {call, L, {remote, R, {atom, M, ?MODULE}, {atom, F, observed_ssl}}, instrument(Args)};
instrument({call, L, {remote, R, {atom, M, executor_tls_ffi}, {atom, F, now}}, []}) ->
    {call, L, {remote, R, {atom, M, ?MODULE}, {atom, F, observed_now}}, []};
instrument(Term) when is_tuple(Term) ->
    list_to_tuple([instrument(T) || T <- tuple_to_list(Term)]);
instrument(Terms) when is_list(Terms) -> [instrument(T) || T <- Terms];
instrument(Term) -> Term.

%% Record the exact real monotonic values returned to production. Comparing
%% timeout arithmetic with these samples avoids races at millisecond boundaries.
observed_now() ->
    Now = erlang:monotonic_time(millisecond),
    Previous = case get(tls_probe_times) of undefined -> []; Times -> Times end,
    put(tls_probe_times, [Now | Previous]),
    Now.

delayed_tcp(Host, Port, Options, Budget) ->
    Started = erlang:monotonic_time(millisecond),
    {ok, Socket} = gen_tcp:connect(Host, Port, Options, Budget),
    {ok, [{active, false}, {mode, binary}, {packet, 0}]} =
        inet:getopts(Socket, [active, mode, packet]),
    put(tls_probe_tcp, {Socket, Budget, Started}),
    receive after get(tls_probe_delay) -> ok end,
    {ok, Socket}.

observed_ssl(Socket, Options, Left) ->
    {Socket, Budget, Started} = get(tls_probe_tcp),
    [BeforeSSL, BeforeTCP, Initial] = get(tls_probe_times),
    true = BeforeSSL - Started >= get(tls_probe_delay),
    Expected = Budget - (BeforeSSL - BeforeTCP),
    io:format("TLS deadline probe: ssl_timeout=~p expected_remaining=~p~n", [Left, Expected]),
    Left = Expected,
    Left = Initial + 400 - BeforeSSL,
    true = Left > 0 andalso Left < Budget,
    put(tls_probe_upgrade, Left),
    ssl:connect(Socket, Options, Left).

stalled_connect(Connect, Delay) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Parent = self(),
    Peer = spawn_monitor(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener, 2000),
        %% Consume ClientHello bytes but never answer. EOF proves production
        %% closed the stream after failure, not merely returned a timeout.
        Parent ! {self(), peer_closed, drain_tcp(Socket, 0)},
        gen_tcp:close(Socket)
    end),
    put(tls_probe_delay, Delay),
    erase(tls_probe_upgrade),
    erase(tls_probe_times),
    try
        {error, timeout} = Connect(Port),
        {Socket, Budget, _} = get(tls_probe_tcp),
        {error, _} = inet:sockname(Socket),
        {PeerPid, Ref} = Peer,
        Bytes = receive {PeerPid, peer_closed, Count} -> Count
            after 2000 -> error(peer_not_closed) end,
        receive {'DOWN', Ref, process, PeerPid, normal} -> ok
            after 2000 -> error(peer_not_retired) end,
        case Delay < Budget of
            true -> true = is_integer(get(tls_probe_upgrade)), true = Bytes > 0;
            false -> undefined = get(tls_probe_upgrade), 0 = Bytes
        end,
        io:format("TLS deadline probe: tcp_budget=~p delay=~p ssl_budget=~p peer_bytes=~p closed~n",
            [Budget, Delay, get(tls_probe_upgrade), Bytes])
    after gen_tcp:close(Listener)
    end.

drain_tcp(Socket, Bytes) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, Data} -> drain_tcp(Socket, Bytes + byte_size(Data));
        {error, closed} -> Bytes;
        Error -> error({peer_did_not_close, Error})
    end.
