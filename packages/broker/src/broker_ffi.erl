%% Erlang shims for the broker package (house rule: one flat FFI module
%% per package; every function here is reached only through the Gleam
%% externals in broker/internal/ffi_*.gleam).
%%
%% Each shim converts to Gleam conventions at the boundary: exceptions
%% are caught and returned as {ok, X} | {error, nil}, and raw terms are
%% normalized into the tuple shapes of the Gleam types declared on the
%% other side of the external.
-module(broker_ffi).

-export([
    strong_rand_bytes/1,
    constant_time_equal/2,
    open_helper/2,
    port_send/2,
    close_port/1,
    port_os_pid/1,
    kill_os_process/1,
    write_private_file/3,
    delete_file/1,
    port_event/1,
    os_name/0,
    schedulers_online/0,
    egress_fetch/7,
    egress_monotonic_ms/0
]).

%% The broker owns a private httpc profile so that the egress client's
%% options — no proxy, no cookie jar, no automatic redirect — cannot be
%% observed or altered by the provider's streaming client, which runs on
%% the default profile.
-define(EGRESS_PROFILE, loom_egress).

%% How long the calling process waits past the worker's own deadline
%% before deciding the worker itself is wedged. The worker enforces the
%% deadline; this only bounds a bug in it.
-define(EGRESS_GRACE_MS, 2000).

%% A transport error term is rendered for a human and truncated, because
%% it comes from a remote-influenced failure and ends up in a refusal
%% message.
-define(EGRESS_REASON_LIMIT, 400).

%% How deep a transport error term is printed before the rest is elided.
%% Measured rather than guessed: 16 is where the shapes that carry the
%% diagnosis survive whole — {failed_connect,[{to_address,_},{inet,_,
%% {tls_alert,{unknown_ca,"..."}}}]} — while a forwarded handler crash
%% carrying an #request{} in a stacktrace argument still elides its
%% header list well before any value in it.
-define(EGRESS_REASON_DEPTH, 16).

%% crypto:strong_rand_bytes/1 — a cryptographically strong entropy
%% source for capability token minting.
strong_rand_bytes(Count) when is_integer(Count), Count >= 0 ->
    crypto:strong_rand_bytes(Count).

%% crypto:hash_equals/2 — constant-time byte comparison, so checking a
%% presented capability token leaks no timing information about how many
%% leading bytes matched. hash_equals raises badarg on length mismatch;
%% lengths are public (all tokens are 32 bytes), so unequal lengths are
%% simply not equal.
constant_time_equal(A, B) when is_binary(A), is_binary(B) ->
    case byte_size(A) =:= byte_size(B) of
        true -> crypto:hash_equals(A, B);
        false -> false
    end.

%% erlang:open_port/2 with spawn_executable — the only way to run and
%% stream to an OS process from the BEAM without a NIF. Options: binary
%% frames both ways, stream mode (the broker's own deframer owns frame
%% boundaries), exit_status so channel death is a message, and hide to
%% suppress a console window on other platforms.
open_helper(Executable, Args) ->
    try
        Port = erlang:open_port(
            {spawn_executable, unicode:characters_to_list(Executable)},
            [{args, Args}, binary, stream, exit_status, hide]
        ),
        {ok, Port}
    catch
        _:_ -> {error, nil}
    end.

%% erlang:port_command/2 — write bytes to the helper's stdin. Raises
%% badarg once the port is closed; that is normalized to an error so the
%% caller settles the effect in-band instead of crashing.
port_send(Port, Bytes) ->
    try
        true = erlang:port_command(Port, Bytes),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

%% erlang:port_close/1 — closes the helper's stdio. The helper treats
%% channel close as an order to reap any running jail. Already-closed
%% ports raise badarg; closing is idempotent from the caller's view.
close_port(Port) ->
    try
        erlang:port_close(Port),
        nil
    catch
        _:_ -> nil
    end.

%% erlang:port_info/2 with os_pid — the helper's OS pid, kept for the
%% broker-side cancel escalation (SIGKILL as the last resort).
port_os_pid(Port) ->
    try erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid) -> {ok, Pid};
        _ -> {error, nil}
    catch
        _:_ -> {error, nil}
    end.

%% os:cmd/1 running kill(1) — the BEAM has no direct kill(2) binding
%% without a NIF; this is the belt-and-braces escalation used only after
%% the helper missed its own 2-second TERM-to-KILL ladder.
kill_os_process(Pid) when is_integer(Pid), Pid > 1 ->
    _ = os:cmd("kill -KILL " ++ integer_to_list(Pid)),
    nil;
kill_os_process(_) ->
    nil.

%% filelib:ensure_path/1 + file:write_file/3 + file:change_mode/2 —
%% creates Dir (mode 0700) and writes Name inside it exclusively, then
%% tightens the file to 0600. The directory is chmodded before the file
%% is written so the policy bytes are never readable by other users,
%% even between create and chmod of the file itself.
write_private_file(Dir, Name, Bytes) ->
    try
        DirList = unicode:characters_to_list(Dir),
        ok = filelib:ensure_path(DirList),
        ok = file:change_mode(DirList, 8#700),
        Path = filename:join(DirList, unicode:characters_to_list(Name)),
        ok = file:write_file(Path, Bytes, [exclusive, raw]),
        ok = file:change_mode(Path, 8#600),
        {ok, unicode:characters_to_binary(Path)}
    catch
        _:_ -> {error, nil}
    end.

%% file:delete/1 — removes the temp policy file once the helper has read
%% it (signalled by the helper's hello). Idempotent: a missing file is
%% success.
delete_file(Path) ->
    _ = file:delete(unicode:characters_to_list(Path)),
    nil.

%% os:type/0's name half, as a binary ("linux", "darwin", "nt"). An
%% ambient fact of the running system with no pure answer, fixed for the
%% life of the node. No normalization happens here: deciding what a name
%% means for the jail is a decision, and decisions belong in Gleam.
os_name() ->
    {_Family, Name} = os:type(),
    atom_to_binary(Name, utf8).

%% erlang:system_info(schedulers_online) — how many schedulers this node
%% is actually running on, which is the closest the BEAM comes to
%% "how big is this machine". Used only to size the helper pool's
%% default ceiling; the clamping that turns it into a pool size is a
%% decision and stays in Gleam.
schedulers_online() ->
    erlang:system_info(schedulers_online).

%% Normalizes a raw port message (received via a record selector on the
%% port) into the broker/internal/ffi_port.PortEvent shape. Pure term
%% inspection; it lives here because the message arrives as a Dynamic
%% whose shape only Erlang pattern matching can take apart safely.
port_event(Msg) ->
    case Msg of
        {Port, {data, Bin}} when is_port(Port), is_binary(Bin) ->
            {port_bytes, Bin};
        {Port, {exit_status, Status}} when is_port(Port), is_integer(Status) ->
            {port_closed, Status};
        _ ->
            port_junk
    end.

%% erlang:monotonic_time/1 in milliseconds. The egress deadline is
%% measured against the monotonic clock rather than wall time so a clock
%% step during a slow transfer cannot lengthen or shorten the budget the
%% caller asked for.
egress_monotonic_ms() ->
    erlang:monotonic_time(millisecond).

%% Performs one HTTPS hop under the caller's caps and answers with the
%% broker/internal/ffi_egress.FetchOutcome shape.
%%
%% The request runs in a spawned worker rather than in the caller. httpc
%% delivers a response as a stream of ordinary messages, and a cancelled
%% or timed-out request can leave some of them in flight; a worker whose
%% mailbox dies with it is the only way to guarantee that nothing from
%% this call is still sitting in the harness process afterwards.
egress_fetch(Method, Url, Headers, Body, MaxBytes, TimeoutMs, Roots) ->
    Parent = self(),
    Ref = make_ref(),
    {Worker, Monitor} =
        spawn_monitor(fun() ->
            Parent ! {Ref, egress_perform(Method, Url, Headers, Body,
                                          MaxBytes, TimeoutMs, Roots)}
        end),
    receive
        {Ref, Outcome} ->
            erlang:demonitor(Monitor, [flush]),
            Outcome;
        {'DOWN', Monitor, process, Worker, Reason} ->
            {fetch_failed, egress_reason(Reason)}
    after TimeoutMs + ?EGRESS_GRACE_MS ->
        %% exit/2 is asynchronous, so the worker may still be between
        %% sending its result and dying. Waiting for the DOWN makes the
        %% flush conclusive: after it, no {Ref, _} can still arrive.
        erlang:exit(Worker, kill),
        receive
            {'DOWN', Monitor, process, Worker, _Killed} -> ok
        end,
        egress_flush(Ref),
        fetch_timed_out
    end.

%% Drops a result the worker managed to send in the moment between the
%% grace timeout firing and the kill landing, so it cannot surface later
%% as an unexpected message in the harness process.
egress_flush(Ref) ->
    receive
        {Ref, _Late} -> ok
    after 0 -> ok
    end.

egress_perform(Method, Url, Headers, Body, MaxBytes, TimeoutMs, Roots) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    try
        ok = egress_ensure_profile(),
        MethodAtom = egress_method(Method),
        UrlList = unicode:characters_to_list(Url),
        HeaderList = [{unicode:characters_to_list(K),
                       unicode:characters_to_list(V)} || {K, V} <- Headers],
        Request = egress_request(MethodAtom, UrlList, HeaderList, Body),
        HttpOptions = egress_http_options(UrlList, TimeoutMs, Roots),
        Options = [{sync, false}, {stream, {self, once}},
                   {body_format, binary}, {receiver, self()}],
        egress_admit(MethodAtom, Request, HttpOptions, Options, Deadline,
                     MaxBytes)
    catch
        Class:Error -> {fetch_failed, egress_reason({Class, Error})}
    end.

egress_admit(MethodAtom, Request, HttpOptions, Options, Deadline, MaxBytes) ->
    case httpc:request(MethodAtom, Request, HttpOptions, Options,
                       ?EGRESS_PROFILE) of
        {ok, RequestId} -> egress_await(RequestId, Deadline, MaxBytes);
        {error, Reason} -> {fetch_failed, egress_reason(Reason)}
    end.

%% Starting the profile is idempotent and cheap after the first call: the
%% persistent_term flag turns every later request into one lookup. Two
%% processes racing here both succeed, because one of them sees
%% already_started and the options they would set are identical.
egress_ensure_profile() ->
    case persistent_term:get({?MODULE, egress_profile}, undefined) of
        ready -> ok;
        _Absent -> egress_start_profile()
    end.

egress_start_profile() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    case inets:start(httpc, [{profile, ?EGRESS_PROFILE}]) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    %% httpc reads no proxy environment of its own and a profile starts
    %% with none configured, so the only thing to say here is that this
    %% profile keeps no cookie jar either. Setting a proxy is refused by
    %% set_options unless one is actually named, which is why the absence
    %% is stated in this comment rather than in an option.
    ok = httpc:set_options([{cookies, disabled}], ?EGRESS_PROFILE),
    persistent_term:put({?MODULE, egress_profile}, ready),
    ok.

egress_method(<<"get">>) -> get;
egress_method(<<"post">>) -> post;
egress_method(<<"put">>) -> put;
egress_method(<<"delete">>) -> delete;
egress_method(<<"patch">>) -> patch;
egress_method(<<"head">>) -> head.

%% httpc takes the body form only for the methods that carry one, and
%% takes the content type as an argument rather than a header; the
%% caller's own content-type is moved into that position so the request
%% cannot end up carrying two.
egress_request(Method, Url, Headers, Body) ->
    case egress_sends_body(Method, Body) of
        true ->
            Type = egress_content_type(Headers),
            Rest = [{K, V} || {K, V} <- Headers,
                              string:lowercase(K) =/= "content-type"],
            {Url, Rest, Type, Body};
        false ->
            {Url, Headers}
    end.

egress_sends_body(post, _Body) -> true;
egress_sends_body(put, _Body) -> true;
egress_sends_body(patch, _Body) -> true;
egress_sends_body(delete, Body) -> byte_size(Body) > 0;
egress_sends_body(_Method, _Body) -> false.

egress_content_type(Headers) ->
    Lowered = [{string:lowercase(K), V} || {K, V} <- Headers],
    case lists:keyfind("content-type", 1, Lowered) of
        {_Key, Value} -> Value;
        false -> "application/octet-stream"
    end.

egress_http_options(UrlList, TimeoutMs, Roots) ->
    [{ssl, egress_ssl_options(egress_sni(UrlList), Roots)},
     {autoredirect, false},
     {autoretry, 0},
     {relaxed, false},
     {timeout, TimeoutMs},
     {connect_timeout, TimeoutMs}].

%% Server Name Indication is the URL's host and nothing else. Gleam has
%% already refused a URL with no host, so a parse that finds none here is
%% a bug rather than an input, and the empty name fails the handshake
%% closed.
egress_sni(UrlList) ->
    case uri_string:parse(UrlList) of
        #{host := Host} -> unicode:characters_to_list(Host);
        _Other -> ""
    end.

%% verify_peer with hostname verification, against exactly the roots the
%% policy named. There is deliberately no path here that reaches
%% verify_none: an unverifiable peer is a TransportFailed, never a
%% quieter success.
%%
%% reuse_sessions is off because ssl's client session cache is
%% node-global and keyed on {host, port} alone. A resumed TLS 1.2
%% handshake carries no Certificate message, so without this a session
%% cached by any other policy — or by the provider's own client, which
%% shares the node — would let a request skip the verification its roots
%% were supposed to force. The policy's roots have to be applied to a
%% full handshake every time or they are not applied at all.
egress_ssl_options(Host, Roots) ->
    [{verify, verify_peer},
     {depth, 10},
     {reuse_sessions, false},
     {server_name_indication, Host},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
     {versions, ['tlsv1.2', 'tlsv1.3']},
     {cacerts, egress_cacerts(Roots)}].

egress_cacerts(system_trust) ->
    public_key:cacerts_get();
egress_cacerts({pinned_trust, Ders}) ->
    Ders.

%% The first message decides which of httpc's two delivery shapes this
%% response uses. A 200 or 206 streams, and the cap is a brake applied
%% chunk by chunk; anything else arrives whole, and the cap is a check.
%% Either way a declared Content-Length over the cap is refused before a
%% body byte is read.
egress_await(RequestId, Deadline, MaxBytes) ->
    case egress_remaining(Deadline) of
        0 ->
            egress_cancel(RequestId),
            fetch_timed_out;
        Left ->
            receive
                {http, {RequestId, stream_start, Headers, Handler}} ->
                    egress_begin(RequestId, Handler, Headers, Deadline,
                                 MaxBytes);
                {http, {RequestId, {{_Version, Status, _Phrase}, Headers,
                                    Body}}} ->
                    egress_whole(Status, Headers, Body, MaxBytes);
                {http, {RequestId, {error, Reason}}} ->
                    egress_transport_error(Reason)
            after Left ->
                egress_cancel(RequestId),
                fetch_timed_out
            end
    end.

%% httpc reports its own expiry as an ordinary error. It is the same
%% event as the deadline above, so it answers the same way rather than as
%% an opaque transport failure the caller would have to parse.
egress_transport_error(timeout) ->
    fetch_timed_out;
egress_transport_error(Reason) ->
    {fetch_failed, egress_reason(Reason)}.

egress_begin(RequestId, Handler, Headers, Deadline, MaxBytes) ->
    Lowered = egress_headers(Headers),
    case egress_declared_over(Lowered, MaxBytes) of
        true ->
            egress_cancel(RequestId),
            {fetch_too_large, MaxBytes};
        false ->
            httpc:stream_next(Handler),
            egress_stream(RequestId, Handler, Deadline, MaxBytes, [], 0)
    end.

egress_whole(Status, Headers, Body, MaxBytes) ->
    Lowered = egress_headers(Headers),
    case byte_size(Body) > MaxBytes orelse
         egress_declared_over(Lowered, MaxBytes) of
        true -> {fetch_too_large, MaxBytes};
        false -> {fetched, Status, Lowered, Body}
    end.

%% One chunk is requested at a time, so the accumulator is checked
%% against the cap before the next chunk is even asked for: a server
%% feeding an endless body is cancelled after the first chunk that
%% crosses the line, not after the body is buffered.
egress_stream(RequestId, Handler, Deadline, MaxBytes, Acc, Size) ->
    case egress_remaining(Deadline) of
        0 ->
            egress_cancel(RequestId),
            fetch_timed_out;
        Left ->
            receive
                {http, {RequestId, stream, Part}} ->
                    egress_chunk(RequestId, Handler, Deadline, MaxBytes, Acc,
                                 Size + byte_size(Part), Part);
                {http, {RequestId, stream_end, Headers}} ->
                    Lowered = egress_headers(Headers),
                    {fetched, egress_streamed_status(Lowered), Lowered,
                     iolist_to_binary(lists:reverse(Acc))};
                {http, {RequestId, {error, Reason}}} ->
                    egress_transport_error(Reason)
            after Left ->
                egress_cancel(RequestId),
                fetch_timed_out
            end
    end.

egress_chunk(RequestId, Handler, Deadline, MaxBytes, Acc, Grown, Part) ->
    case Grown > MaxBytes of
        true ->
            egress_cancel(RequestId),
            {fetch_too_large, MaxBytes};
        false ->
            httpc:stream_next(Handler),
            egress_stream(RequestId, Handler, Deadline, MaxBytes,
                          [Part | Acc], Grown)
    end.

%% httpc's stream messages carry no status line, and it streams only 200
%% and 206. A 206 always carries Content-Range, so the header is the one
%% signal available and it is exact for the responses that reach here.
egress_streamed_status(Headers) ->
    case lists:keyfind(<<"content-range">>, 1, Headers) of
        false -> 200;
        _Present -> 206
    end.

egress_declared_over(Headers, MaxBytes) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_Key, Value} ->
            case string:to_integer(Value) of
                {Declared, _Rest} when is_integer(Declared) ->
                    Declared > MaxBytes;
                _Unparseable ->
                    false
            end;
        false ->
            false
    end.

%% Header names are lowercased once, here, so the Gleam side has a single
%% spelling to match on. Both halves are re-encoded from latin1 so that a
%% byte a server chose cannot reach Gleam as an invalid UTF-8 string.
egress_headers(Headers) ->
    [{unicode:characters_to_binary(string:lowercase(K), latin1, utf8),
      unicode:characters_to_binary(V, latin1, utf8)} || {K, V} <- Headers].

egress_remaining(Deadline) ->
    max(Deadline - erlang:monotonic_time(millisecond), 0).

egress_cancel(RequestId) ->
    try httpc:cancel_request(RequestId, ?EGRESS_PROFILE)
    catch
        _Class:_Error -> ok
    end.

%% ~0P rather than ~0p: a handler crash forwarded as {error, {Error,
%% Stacktrace}} can carry an #request{} argument with the outgoing
%% headers in it, and an unbounded print would put an injected credential
%% into a refusal message. Depth 8 elides that while leaving the shapes
%% that actually matter — {failed_connect,[{to_address,_},{inet,_,
%% {tls_alert,{unknown_ca,_}}}]} — intact.
egress_reason(Reason) ->
    Rendered = unicode:characters_to_binary(
                 io_lib:format("~0P", [Reason, ?EGRESS_REASON_DEPTH]),
                 unicode, utf8),
    string:slice(Rendered, 0, ?EGRESS_REASON_LIMIT).
