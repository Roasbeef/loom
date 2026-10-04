%% Test-side FFI for the client package: a minimal websocket client,
%% just enough to prove the served endpoint end to end — TCP dial, HTTP
%% upgrade with the bearer token, one masked text frame out, the first
%% text frame back. A real client library would hide exactly the parts
%% the smoke test wants to witness (the 101, the framing), so the ~80
%% lines are the point, not an accident.
-module(client_test_ffi).

-export([ws_roundtrip/4, which/1, run/3, gzip/1,
         origin_start/0, origin_stop/1, origin_seen/1, monitored_by/1,
         owner_label_of/1, reductions_of/1, log_capture_start/0,
         log_capture_stop/0, log/2, utf_codepoint_calls/1,
         workspace_credentials/0]).

-include_lib("public_key/include/public_key.hrl").

%% OTP's private trace session witnesses the removed Unicode list walk in
%% this test process alone. No Gleam process primitive exposes function call
%% counters; the session always retires, including when the callback raises.
utf_codepoint_calls(Run) ->
    {module, 'gleam@string'} = code:ensure_loaded('gleam@string'),
    {ok, Session} = tprof:start(#{type => call_memory, session => transfer_cpu_test}),
    try
        1 = tprof:set_pattern(Session, 'gleam@string', to_utf_codepoints_loop, 2),
        tprof:enable_trace(Session, self(), #{set_on_spawn => false}),
        Value = Run(),
        tprof:pause(Session),
        {call_memory, Rows} = tprof:collect(Session),
        Calls = lists:sum([Count || {_, _, _, PerPid} <- Rows,
                                   {Pid, Count, _} <- PerPid, Pid =:= self()]),
        {Value, Calls}
    after
        tprof:stop(Session)
    end.

%% Returns {ok, Payload} with the first text frame the server sends
%% after our frame, or {error, Reason} naming the step that failed.
ws_roundtrip(Host, Port, Token, Text) ->
    Options = [binary, {packet, raw}, {active, false}, {nodelay, true}],
    case gen_tcp:connect(binary_to_list(Host), Port, Options, 5000) of
        {error, Reason} -> fail(connect, Reason);
        {ok, Socket} ->
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Upgrade =
                [<<"GET /v1/ws HTTP/1.1\r\n">>, <<"host: ">>, Host,
                 <<"\r\n">>, <<"upgrade: websocket\r\n">>,
                 <<"connection: Upgrade\r\n">>, <<"sec-websocket-key: ">>,
                 Key, <<"\r\n">>, <<"sec-websocket-version: 13\r\n">>,
                 <<"authorization: Bearer ">>, Token, <<"\r\n\r\n">>],
            ok = gen_tcp:send(Socket, Upgrade),
            Outcome = handshake_then_roundtrip(Socket, Text),
            gen_tcp:close(Socket),
            Outcome
    end.

handshake_then_roundtrip(Socket, Text) ->
    case read_http_response(Socket, <<>>) of
        {error, Reason} -> fail(upgrade, Reason);
        {ok, 101, Rest} ->
            ok = gen_tcp:send(Socket, mask_text_frame(Text)),
            read_text_frame(Socket, Rest);
        {ok, Status, _Rest} -> fail(upgrade_status, Status)
    end.

%% Accumulates until the header terminator; anything after it is the
%% start of the frame stream and is handed back to the frame reader.
read_http_response(Socket, Buffer) ->
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            case Head of
                <<"HTTP/1.1 ", StatusText:3/binary, _/binary>> ->
                    {ok, binary_to_integer(StatusText), Rest};
                _ -> {error, {bad_status_line, Head}}
            end;
        [_] ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, More} ->
                    read_http_response(Socket, <<Buffer/binary, More/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

%% One client->server text frame: FIN set, opcode 1, masked as RFC 6455
%% requires of clients. The payloads here are short commands, so only
%% the 7-bit and 16-bit length forms are implemented.
mask_text_frame(Text) ->
    Mask = crypto:strong_rand_bytes(4),
    Masked = crypto:exor(Text, expand_mask(Mask, byte_size(Text))),
    Length =
        case byte_size(Text) of
            Short when Short < 126 -> <<1:1, Short:7>>;
            Long when Long < 65536 -> <<1:1, 126:7, Long:16>>
        end,
    <<16#81, Length/bitstring, Mask/binary, Masked/binary>>.

expand_mask(Mask, Size) ->
    binary:part(binary:copy(Mask, Size div 4 + 1), 0, Size).

%% Reads server frames until a text frame arrives (control frames are
%% skipped); server frames are unmasked. 64-bit lengths are out of
%% scope for a smoke payload and reported as errors.
read_text_frame(Socket, Buffer) ->
    case Buffer of
        <<_Fin:1, _Rsv:3, Opcode:4, 0:1, 126:7, Length:16, Rest/binary>>
          when byte_size(Rest) >= Length ->
            deliver(Socket, Opcode, Length, Rest);
        <<_Fin:1, _Rsv:3, Opcode:4, 0:1, Length:7, Rest/binary>>
          when Length < 126, byte_size(Rest) >= Length ->
            deliver(Socket, Opcode, Length, Rest);
        <<_Fin:1, _Rsv:3, _Op:4, 0:1, 127:7, _/binary>> ->
            fail(frame, payload_too_large);
        _ ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, More} ->
                    read_text_frame(Socket, <<Buffer/binary, More/binary>>);
                {error, Reason} -> fail(frame, Reason)
            end
    end.

deliver(Socket, Opcode, Length, Rest) ->
    <<Payload:Length/binary, After/binary>> = Rest,
    case Opcode of
        1 -> {ok, Payload};
        _ -> read_text_frame(Socket, After)
    end.

fail(Step, Reason) ->
    {error, iolist_to_binary(io_lib:format("~p: ~p", [Step, Reason]))}.

%% --- running a program -----------------------------------------------------
%%
%% `open_port({spawn_executable, ...}, [{args, ...}])` rather than
%% `os:cmd/1`: the arguments reach execve as a vector, so nothing the
%% test builds is ever parsed by a shell. That matters here because the
%% strings being passed are terminal keystrokes.

%% The absolute path of a program on PATH, or `Error(Nil)`.
which(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

%% Runs Exe with Args in Dir, returning {ok, {ExitStatus, Output}} with
%% stdout and stderr interleaved, or {error, Reason} if the program could
%% not be started or did not exit within the window.
run(Exe, Args, Dir) ->
    Options =
        [{args, [binary_to_list(A) || A <- Args]}, {cd, binary_to_list(Dir)},
         binary, exit_status, stderr_to_stdout, hide],
    try erlang:open_port({spawn_executable, binary_to_list(Exe)}, Options) of
        Port -> collect(Port, <<>>)
    catch
        _Class:Reason ->
            {error, iolist_to_binary(io_lib:format("spawn: ~p", [Reason]))}
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {ok, {Status, Acc}}
    after 300000 ->
        try erlang:port_close(Port)
        catch
            _:_ -> ok
        end,
        {error, <<"the program did not exit within five minutes">>}
    end.

%% --- gzip, for the extension archive tests ---------------------------------
%%
%% zlib:gzip/1 rather than a `tar`/`gzip` binary: the archive tests build
%% their tars byte by byte in Gleam precisely so that nothing about what
%% they assert depends on a tool version, and shelling out for the
%% compression would put that back.
gzip(Bytes) ->
    zlib:gzip(Bytes).

%% ---------------------------------------------------------------------
%% A real TLS origin on loopback, for the extension egress end-to-end.
%%
%% `broker/egress` refuses anything but https and verifies every chain
%% against the policy's roots, and no test may relax either. So this is
%% an actual `ssl` listener with a chain generated at test time by
%% `public_key:pkix_test_data/1`, whose root the test pins through
%% `egress.PinnedRoots` — the client's verification path runs for real.
%% `packages/broker` has its own copy for its own suite; the two are
%% deliberately separate rather than a shared module, because a test
%% module inside a package is a module *of* that package and neither
%% suite may import the other's.
%%
%% One route, `/get`, answering a fixed body that does **not** echo the
%% request. That is the point: the extension end-to-end asserts that the
%% injected credential reached the origin *and* that its value appears in
%% no frame on the capability channel, and a server that echoed its
%% headers back would put the value in the response body and defeat the
%% second half. What the origin saw is read out of band with
%% `origin_seen/1`, which never travels through the jail at all.
%% ---------------------------------------------------------------------

%% Starts a server on an ephemeral loopback port. Answers with the
%% owning pid, the port, and the DER of the root a client must pin.
origin_start() ->
    {ok, _} = application:ensure_all_started(ssl),
    {RootDer, ServerConf} = origin_chain(),
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> origin_listen(Parent, Ref, ServerConf) end),
    receive
        {Ref, Port} -> {Pid, Port, RootDer}
    after 10000 ->
        exit(origin_server_start_timeout)
    end.

%% Killing the owner closes the listen socket with it.
origin_stop(Pid) ->
    erlang:exit(Pid, kill),
    nil.

%% The headers of every request this origin has answered, newest first,
%% each rendered as one `name: value` line. Read out of band, so nothing
%% here has crossed the capability channel.
origin_seen(Pid) ->
    Ref = make_ref(),
    Pid ! {seen, self(), Ref},
    receive
        {Ref, Lines} -> Lines
    after 5000 ->
        []
    end.

origin_chain() ->
    Key = {?MODULE, origin_chain},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Chain = origin_generate_chain(),
            persistent_term:put(Key, Chain),
            Chain;
        Chain ->
            Chain
    end.

%% The peer certificate names localhost in a subjectAltName: the
%% generator's default is this machine's own hostname, and the extension
%% under test requests https://localhost:<port>.
origin_generate_chain() ->
    Root = public_key:pkix_test_root_cert("loom extension test root",
                                          origin_key_opts()),
    San = #'Extension'{extnID = ?'id-ce-subjectAltName',
                       extnValue = [{dNSName, "localhost"}],
                       critical = false},
    Peer = origin_key_opts() ++ [{extensions, [San]}],
    #{server_config := ServerConf} =
        public_key:pkix_test_data(
          #{server_chain => #{root => Root,
                              intermediates => [],
                              peer => Peer},
            client_chain => #{root => [], intermediates => [], peer => []}}),
    #{cert := RootDer} = Root,
    {RootDer, ServerConf}.

%% The generator's default key is whatever curve OpenSSL lists first,
%% which on some machines is a legacy curve TLS 1.2 and 1.3 both refuse.
%% Naming P-256 and SHA-256 keeps the failure the suite observes the one
%% it is testing for.
origin_key_opts() ->
    [{digest, sha256}, {key, {namedCurve, secp256r1}}].

origin_listen(Parent, Ref, ServerConf) ->
    Options = ServerConf ++ [{reuseaddr, true}, {active, false},
                             {mode, binary}, {ip, {127, 0, 0, 1}}],
    {ok, Listen} = ssl:listen(0, Options),
    {ok, {_Address, Port}} = ssl:sockname(Listen),
    Parent ! {Ref, Port},
    origin_loop(Listen, []).

%% One process owns the listener, the accept loop and the record of what
%% has been seen, so `origin_seen/1` is a message to the one party that
%% knows. Accept is polled with a short timeout rather than blocked on,
%% because the same process has to stay able to answer that message.
origin_loop(Listen, Seen) ->
    Next = case ssl:transport_accept(Listen, 200) of
               {ok, Socket} -> origin_handshake(Socket, Seen);
               {error, timeout} -> Seen;
               {error, _Closed} -> Seen
           end,
    receive
        {seen, From, Ref} ->
            From ! {Ref, Next},
            origin_loop(Listen, Next)
    after 0 ->
        origin_loop(Listen, Next)
    end.

origin_handshake(Socket, Seen) ->
    case ssl:handshake(Socket, 5000) of
        {ok, Tls} ->
            Headers = origin_serve(Tls),
            ssl:close(Tls),
            [Headers | Seen];
        {error, _Rejected} ->
            Seen
    end.

origin_serve(Socket) ->
    case origin_read_head(Socket, <<>>) of
        {ok, Head} ->
            {Path, Headers} = origin_parse(Head),
            origin_respond(Socket, Path),
            Headers;
        {error, _Reason} ->
            []
    end.

origin_read_head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Position, _Length} ->
            {ok, binary:part(Acc, 0, Position)};
        nomatch ->
            case ssl:recv(Socket, 0, 10000) of
                {ok, Data} -> origin_read_head(Socket, <<Acc/binary, Data/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

origin_parse(Head) ->
    [RequestLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Method, Path | _Version] = binary:split(RequestLine, <<" ">>, [global]),
    Headers = [origin_header(Line) || Line <- HeaderLines, Line =/= <<>>],
    {Path, Headers}.

origin_header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            iolist_to_binary([string:lowercase(Name), <<": ">>,
                              string:trim(Value)]);
        [Name] ->
            iolist_to_binary([string:lowercase(Name), <<": ">>])
    end.

%% The body carries no part of the request, deliberately: see the header
%% comment. A path this origin does not know answers 404 with a body that
%% is still not the request.
origin_respond(Socket, <<"/get">>) ->
    origin_send(Socket, 200, <<"the origin answered">>);
origin_respond(Socket, _Path) ->
    origin_send(Socket, 404, <<"no such route">>).

%% The processes monitoring Pid, or none once it has exited. A test reads
%% this to learn that a caller has begun waiting on a process, which no
%% message announces: the monitor is the wait.
monitored_by(Pid) ->
    case erlang:process_info(Pid, monitored_by) of
        {monitored_by, Monitors} -> [M || M <- Monitors, is_pid(M)];
        undefined -> []
    end.

%% The frozen `{pickglass_owner, 1, Path, Role}` label of another process,
%% as `{some, {Path, Role}}`, or `none` for a process that carries no label
%% of that shape. This is exactly what the ownership inspector reads.
owner_label_of(Pid) ->
    case erlang:process_info(Pid, label) of
        {label, {pickglass_owner, 1, Path, Role}} -> {some, {Path, Role}};
        _ -> none
    end.

origin_send(Socket, Status, Body) ->
    Head = [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" OK\r\n">>,
            <<"content-type: text/plain\r\n">>,
            <<"content-length: ">>, integer_to_binary(byte_size(Body)),
            <<"\r\n">>, <<"connection: close\r\n\r\n">>],
    ssl:send(Socket, [Head, Body]).

%% The reductions a process has run: a number that moves only when the process
%% does work. A test reads it before and after a request to learn whether the
%% request made the registry do any.
reductions_of(Pid) ->
    case erlang:process_info(Pid, reductions) of
        {reductions, Count} -> Count;
        undefined -> 0
    end.

%% Captures every daemon log line written until `log_capture_stop/0`, so a test
%% can look through what the daemon said for a value it must never say. The
%% daemon's logger writes one report whose `loom` key holds the rendered line
%% (`telemetry_ffi:log/2`); this handler keeps those lines and nothing else. The
%% primary level is lowered to `info` for the capture, which is what the daemon
%% runs at, and put back by the stop.
log_capture_start() ->
    Previous = maps:get(level, logger:get_primary_config()),
    persistent_term:put({?MODULE, previous_level}, Previous),
    _ = logger:set_primary_config(level, info),
    _ = ets:new(loom_log_capture, [named_table, public, ordered_set]),
    ok = logger:add_handler(loom_log_capture, ?MODULE, #{level => info}),
    nil.

%% The lines captured since `log_capture_start/0`, oldest first.
log_capture_stop() ->
    _ = logger:remove_handler(loom_log_capture),
    Lines = [Line || {_, Line} <- ets:tab2list(loom_log_capture)],
    ets:delete(loom_log_capture),
    _ = logger:set_primary_config(level,
                                  persistent_term:get({?MODULE, previous_level},
                                                      notice)),
    Lines.

%% The logger handler callback.
log(#{msg := {report, #{loom := Line}}}, _Config) ->
    ets:insert(loom_log_capture, {erlang:unique_integer([monotonic]),
                                  iolist_to_binary([Line])});
log(_Event, _Config) ->
    ok.

%% Fresh mutually authenticated peer credentials for workspace consumer tests.
%% This package cannot depend on another package's private test modules.
workspace_credentials() ->
    {ok, _} = application:ensure_all_started(ssl),
    Root = public_key:pkix_test_root_cert("client workspace test", origin_key_opts()),
    {workspace_credentials, workspace_peer(Root), workspace_peer(Root)}.

workspace_peer(Root) ->
    San = #'Extension'{extnID = ?'id-ce-subjectAltName',
        extnValue = [{dNSName, "localhost"}], critical = false},
    #{server_config := Conf} = public_key:pkix_test_data(
        #{server_chain => #{root => Root, intermediates => [],
            peer => origin_key_opts() ++ [{extensions, [San]}]},
          client_chain => #{root => [], intermediates => [], peer => []}}),
    Cert = proplists:get_value(cert, Conf),
    {Type, Der} = proplists:get_value(key, Conf),
    Pem = public_key:pem_encode([{Type, Der, not_encrypted}]),
    {credentials, maps:get(cert, Root), Cert, Pem, crypto:hash(sha256, Cert)}.
