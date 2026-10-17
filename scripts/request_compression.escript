#!/usr/bin/env escript
%%! +S 1:1
%% OTP gzip CPU and real provider_ffi transport measurements. All network work
%% targets the companion loopback fixture. No provider credentials are used.
%% Usage: escript scripts/request_compression.escript cpu|transport CAPTURE [LEVEL]
%% For transport, build packages/client and set ERL_LIBS to its build/dev/erlang.
-mode(compile).

main(["cpu", Capture]) ->
    {ok, Body} = file:read_file(Capture),
    Prefix = binary:part(Body, 0, min(8192, byte_size(Body))),
    Fixtures = [{<<"empty">>, <<>>}, {<<"utf8">>, <<"hello ", 240,159,152,128>>},
                {<<"prefix_8k">>, Prefix}, {<<"captured_request">>, Body},
                {<<"random_control">>, crypto:strong_rand_bytes(byte_size(Body))}],
    lists:foreach(fun({Name, Bytes}) ->
        lists:foreach(fun(Level) -> cpu(Name, Bytes, Level) end, [1, 6, 9])
    end, Fixtures);
main(["transport", Capture]) ->
    run_transport(Capture, 6);
main(["transport", Capture, Level]) when Level =:= "1"; Level =:= "6"; Level =:= "9" ->
    run_transport(Capture, list_to_integer(Level));
main(_) ->
    io:format(standard_error, "usage: request_compression.escript cpu|transport CAPTURE [1|6|9]~n", []),
    halt(2).

run_transport(Capture, Level) ->
    {ok, Body} = file:read_file(Capture),
    lists:foreach(fun(Rate) ->
        lists:foreach(fun(Round) ->
            Order = case Round rem 2 of 0 -> [gzip, identity]; 1 -> [identity, gzip] end,
            lists:foreach(fun(Encoding) -> transport(Body, Encoding, Level, Rate, Round) end, Order)
        end, lists:seq(1, 7))
    end, [0, 1, 10, 100]).

cpu(Name, Body, Level) ->
    Run = fun() -> gzip(Body, Level) end,
    Packed = Run(),
    Body = zlib:gunzip(Packed),
    Times = samples(Run),
    Inflate = samples(fun() -> zlib:gunzip(Packed) end),
    emit(#{kind => cpu, fixture => Name, level => Level,
           raw_bytes => byte_size(Body), wire_bytes => byte_size(Packed),
           sha256 => digest(Body), samples => length(Times),
           compress_median_us => median(Times), compress_max_us => lists:max(Times),
           inflate_median_us => median(Inflate), otp => list_to_binary(erlang:system_info(otp_release))}).

samples(Run) ->
    [Run() || _ <- lists:seq(1, 5)],
    [begin {Us, _} = timer:tc(Run), Us end || _ <- lists:seq(1, 21)].

gzip(Body, 6) -> zlib:gzip(Body);
gzip(Body, Level) ->
    Z = zlib:open(),
    try
        ok = zlib:deflateInit(Z, Level, deflated, 31, 8, default),
        Bytes = iolist_to_binary(zlib:deflate(Z, Body, finish)),
        ok = zlib:deflateEnd(Z),
        Bytes
    after
        zlib:close(Z)
    end.

transport(Body, Encoding, Level, Rate, Round) ->
    Parent = self(),
    Owner = provider_ffi:prepare_stream_request(
        fun(Status, Headers) -> Parent ! {status, Status, Headers} end,
        fun(Chunk) -> Parent ! {chunk, erlang:monotonic_time(microsecond), Chunk} end,
        fun() -> Parent ! finished end,
        fun(Reason) -> Parent ! {failed, Reason} end),
    Monitor = monitor(process, Owner),
    Start = erlang:monotonic_time(microsecond),
    {Headers, Wire} = case Encoding of
        identity -> {[], Body};
        gzip -> {[{<<"content-encoding">>, <<"gzip">>}], gzip(Body, Level)}
    end,
    provider_ffi:begin_stream_request(Owner, <<"POST">>, <<"http://127.0.0.1:18746/v1/messages">>,
        [{<<"content-type">>, <<"application/json">>}, {<<"x-api-key">>, <<"scripted">>},
         {<<"x-lab-mbps">>, integer_to_binary(Rate)} | Headers], Wire),
    {First, Reply, Status, ReplyHeaders, Finished} = collect(Monitor, undefined, [], undefined, [], false),
    true = Finished,
    200 = Status,
    true = binary:match(Reply, <<"gzip-probe-ok">>) =/= nomatch,
    true = binary:match(Reply, <<"message_stop">>) =/= nomatch,
    Expected = digest(Body),
    {<<"x-lab-sha256">>, Expected} = lists:keyfind(<<"x-lab-sha256">>, 1, ReplyHeaders),
    emit(#{kind => transport, encoding => Encoding, level => Level, simulated_mbps => Rate, round => Round,
           sha256 => Expected, raw_bytes => byte_size(Body), wire_bytes => byte_size(Wire),
           first_chunk_us => First - Start,
           drained_us => erlang:monotonic_time(microsecond) - Start}).

%% The original owner monitor, rather than ResponseEnd alone, proves the
%% production HTTP handler drained. A missing or abnormal witness fails the run.
collect(Monitor, First, Chunks, Status, Headers, Finished) ->
    receive
        {status, Code, NewHeaders} -> collect(Monitor, First, Chunks, Code, NewHeaders, Finished);
        {chunk, At, Chunk} ->
            Earliest = case First of undefined -> At; _ -> First end,
            collect(Monitor, Earliest, [Chunk | Chunks], Status, Headers, Finished);
        finished -> collect(Monitor, First, Chunks, Status, Headers, true);
        {failed, Reason} -> error({transport_failed, Reason});
        {'DOWN', Monitor, process, _, normal} ->
            {First, iolist_to_binary(lists:reverse(Chunks)), Status, Headers, Finished};
        {'DOWN', Monitor, process, _, Reason} -> error({drain_proof_lost, Reason})
    after 120000 -> error(transport_timeout)
    end.

median(Values) -> lists:nth(length(Values) div 2 + 1, lists:sort(Values)).
digest(Bytes) -> binary:encode_hex(crypto:hash(sha256, Bytes), lowercase).
emit(Value) -> io:put_chars([json:encode(Value), $\n]).
