%% Test-only Erlang shims for the broker suite (never shipped in src).
%% Used by the feature-detected integration test to find and drive the
%% Go toolchain; see test/broker/support/shell.gleam.
-module(broker_test_ffi).

-export([find_executable/1, os_cmd/1,
         egress_start/0, egress_stop/1, egress_foreign_root/0]).

-include_lib("public_key/include/public_key.hrl").

%% os:find_executable/1 — PATH lookup for feature detection.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% os:cmd/1 — run a shell command, capturing stdout. Test-only; the
%% production spawn path goes through erlang ports in broker_ffi.
os_cmd(Command) ->
    unicode:characters_to_binary(os:cmd(unicode:characters_to_list(Command))).

%% ---------------------------------------------------------------------
%% A real TLS origin server for the broker/egress suite.
%%
%% The point of running a real server with a real chain is that the
%% client's verification path is exercised rather than bypassed: nothing
%% in the suite may set verify_none, so the certificate the test pins has
%% to actually validate. The chain is generated once per node with
%% public_key:pkix_test_data/1 and cached, so two servers started for the
%% same test share a root and differ only in port — which is what makes
%% "two origins, one secret" testable without a second hostname.
%% ---------------------------------------------------------------------

%% Starts a server on an ephemeral loopback port. Answers with the
%% server's controlling pid, its port, and the DER of the root the
%% client must pin to reach it.
egress_start() ->
    {ok, _} = application:ensure_all_started(ssl),
    {RootDer, ServerConf} = egress_chain(),
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> egress_listen(Parent, Ref, ServerConf) end),
    receive
        {Ref, Port} -> {Pid, Port, RootDer}
    after 10000 ->
        exit(egress_server_start_timeout)
    end.

%% Killing the owner closes the listen socket with it.
egress_stop(Pid) ->
    erlang:exit(Pid, kill),
    nil.

%% The root of an unrelated chain: pinning it must make every connection
%% to the test server fail verification.
egress_foreign_root() ->
    Key = {?MODULE, egress_foreign_root},
    case persistent_term:get(Key, undefined) of
        undefined ->
            #{cert := Der} = public_key:pkix_test_root_cert(
                               "loom egress foreign root", egress_key_opts()),
            persistent_term:put(Key, Der),
            Der;
        Der ->
            Der
    end.

egress_chain() ->
    Key = {?MODULE, egress_chain},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Chain = egress_generate_chain(),
            persistent_term:put(Key, Chain),
            Chain;
        Chain ->
            Chain
    end.

%% The peer certificate names localhost in a subjectAltName, because the
%% default the generator would supply is this machine's own hostname and
%% the tests request https://localhost:<port>.
egress_generate_chain() ->
    Root = public_key:pkix_test_root_cert("loom egress test root",
                                          egress_key_opts()),
    San = #'Extension'{extnID = ?'id-ce-subjectAltName',
                       extnValue = [{dNSName, "localhost"}],
                       critical = false},
    Peer = egress_key_opts() ++ [{extensions, [San]}],
    #{server_config := ServerConf} =
        public_key:pkix_test_data(
          #{server_chain => #{root => Root,
                              intermediates => [],
                              peer => Peer},
            client_chain => #{root => [], intermediates => [], peer => []}}),
    #{cert := RootDer} = Root,
    {RootDer, ServerConf}.

%% The generator's default key is whatever curve OpenSSL lists first,
%% which on this machine is a 160-bit legacy curve that TLS 1.2 and 1.3
%% both refuse outright. Naming P-256 and SHA-256 keeps the failure the
%% suite observes the one it is testing for.
egress_key_opts() ->
    [{digest, sha256}, {key, {namedCurve, secp256r1}}].

egress_listen(Parent, Ref, ServerConf) ->
    Options = ServerConf ++ [{reuseaddr, true}, {active, false},
                             {mode, binary}, {ip, {127, 0, 0, 1}}],
    {ok, Listen} = ssl:listen(0, Options),
    {ok, {_Address, Port}} = ssl:sockname(Listen),
    Parent ! {Ref, Port},
    egress_accept(Listen, Port).

%% The handshake runs in the acceptor (it is fast and its failure is the
%% untrusted-certificate case), but the exchange itself is handed to a
%% per-connection process so that a deliberately slow route cannot stall
%% the next test's connection.
egress_accept(Listen, Port) ->
    case ssl:transport_accept(Listen, 60000) of
        {ok, Socket} ->
            egress_handshake(Socket, Port),
            egress_accept(Listen, Port);
        {error, timeout} ->
            egress_accept(Listen, Port);
        {error, _Closed} ->
            ok
    end.

egress_handshake(Socket, Port) ->
    case ssl:handshake(Socket, 5000) of
        {ok, Tls} ->
            Handler = spawn(fun() ->
                receive
                    go -> egress_serve(Tls, Port)
                end
            end),
            ssl:controlling_process(Tls, Handler),
            Handler ! go;
        {error, _Rejected} ->
            ok
    end.

egress_serve(Socket, Port) ->
    case egress_read_head(Socket, <<>>) of
        {ok, Head, Rest} ->
            {Method, Path, Headers} = egress_parse(Head),
            egress_drain(Socket, Headers, Rest),
            egress_route(Socket, Method, Path, Headers, Port);
        {error, _Reason} ->
            ok
    end.

egress_read_head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Position, Length} ->
            Head = binary:part(Acc, 0, Position),
            Start = Position + Length,
            {ok, Head, binary:part(Acc, Start, byte_size(Acc) - Start)};
        nomatch ->
            case ssl:recv(Socket, 0, 10000) of
                {ok, Data} ->
                    egress_read_head(Socket, <<Acc/binary, Data/binary>>);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

egress_parse(Head) ->
    [RequestLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [Method, Path | _Version] = binary:split(RequestLine, <<" ">>, [global]),
    Headers = [egress_header(Line) || Line <- HeaderLines, Line =/= <<>>],
    {Method, Path, Headers}.

egress_header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] -> {string:lowercase(Name), string:trim(Value)};
        [Name] -> {string:lowercase(Name), <<>>}
    end.

%% A request body is read and discarded. Answering a POST without
%% draining it would leave the client writing into a socket that is
%% about to close, which shows up as a transport failure rather than as
%% the redirect the test is asking about.
egress_drain(Socket, Headers, Rest) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_Key, Value} ->
            {Declared, _} = string:to_integer(Value),
            egress_drain_bytes(Socket, Declared - byte_size(Rest));
        false ->
            ok
    end.

egress_drain_bytes(_Socket, Remaining) when Remaining =< 0 ->
    ok;
egress_drain_bytes(Socket, Remaining) ->
    case ssl:recv(Socket, 0, 5000) of
        {ok, Data} -> egress_drain_bytes(Socket, Remaining - byte_size(Data));
        {error, _Reason} -> ok
    end.

egress_route(Socket, Method, <<"/echo">>, Headers, _Port) ->
    egress_respond(Socket, 200, [{<<"content-type">>, <<"text/plain">>}],
                   egress_echo(Method, Headers));
egress_route(Socket, _Method, <<"/redirect-same">>, _Headers, Port) ->
    egress_redirect(Socket, 302, egress_url(Port, <<"/echo">>));
egress_route(Socket, _Method, <<"/redirect-relative">>, _Headers, _Port) ->
    egress_redirect(Socket, 302, <<"/echo">>);
egress_route(Socket, _Method, <<"/redirect-off">>, _Headers, _Port) ->
    egress_redirect(Socket, 302, <<"https://elsewhere.example/echo">>);
egress_route(Socket, _Method, <<"/redirect-loop">>, _Headers, Port) ->
    egress_redirect(Socket, 302, egress_url(Port, <<"/redirect-loop">>));
egress_route(Socket, _Method, <<"/see-other">>, _Headers, Port) ->
    egress_redirect(Socket, 303, egress_url(Port, <<"/echo">>));
egress_route(Socket, _Method, <<"/declared-big">>, _Headers, _Port) ->
    egress_declared_big(Socket);
egress_route(Socket, _Method, <<"/slow">>, _Headers, _Port) ->
    egress_slow(Socket);
egress_route(Socket, _Method, <<"/sleep">>, _Headers, _Port) ->
    timer:sleep(2000),
    egress_respond(Socket, 200, [], <<"late">>);
egress_route(Socket, _Method, _Path, _Headers, _Port) ->
    egress_respond(Socket, 404, [], <<"no such route">>).

egress_url(Port, Path) ->
    iolist_to_binary([<<"https://localhost:">>, integer_to_binary(Port), Path]).

egress_echo(Method, Headers) ->
    Lines = [[string:lowercase(Method), <<"\n">>] |
             [[Name, <<": ">>, Value, <<"\n">>] || {Name, Value} <- Headers]],
    iolist_to_binary(Lines).

egress_redirect(Socket, Status, Location) ->
    egress_respond(Socket, Status, [{<<"location">>, Location}], <<>>).

%% Declares far more than any test's cap and then stops. The client must
%% refuse on the declaration alone, so the bytes never need to exist.
egress_declared_big(Socket) ->
    Head = [<<"HTTP/1.1 200 OK\r\n">>,
            <<"content-length: 100000000\r\n">>,
            <<"connection: close\r\n\r\n">>],
    ssl:send(Socket, Head),
    ssl:send(Socket, binary:copy(<<"x">>, 64)),
    ssl:close(Socket).

%% A chunked body that never ends, dribbled out until the client hangs
%% up. Ending it would make the test weaker than it looks: a client that
%% silently buffered the whole thing would still answer ResponseTooLarge
%% once the body arrived, so only an endless body distinguishes the brake
%% from the check. A client that buffers instead runs out of deadline.
%%
%% The chunk ceiling is a stop for a wedged run, not part of the
%% behaviour: at 20ms a hop it is far past any deadline in the suite.
egress_slow(Socket) ->
    Head = [<<"HTTP/1.1 200 OK\r\n">>,
            <<"transfer-encoding: chunked\r\n">>,
            <<"connection: close\r\n\r\n">>],
    ssl:send(Socket, Head),
    egress_chunks(Socket, 8192),
    ssl:close(Socket).

egress_chunks(_Socket, 0) ->
    ok;
egress_chunks(Socket, Left) ->
    Chunk = binary:copy(<<"y">>, 8192),
    Frame = [<<"2000\r\n">>, Chunk, <<"\r\n">>],
    case ssl:send(Socket, Frame) of
        ok ->
            timer:sleep(20),
            egress_chunks(Socket, Left - 1);
        {error, _Closed} ->
            ok
    end.

egress_respond(Socket, Status, Headers, Body) ->
    Head = [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" OK\r\n">>,
            [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
            <<"content-length: ">>, integer_to_binary(byte_size(Body)),
            <<"\r\n">>,
            <<"connection: close\r\n\r\n">>],
    ssl:send(Socket, [Head, Body]),
    ssl:close(Socket).
