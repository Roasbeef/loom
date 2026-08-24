%% Test-side FFI for the client package: a minimal websocket client,
%% just enough to prove the served endpoint end to end — TCP dial, HTTP
%% upgrade with the bearer token, one masked text frame out, the first
%% text frame back. A real client library would hide exactly the parts
%% the smoke test wants to witness (the 101, the framing), so the ~80
%% lines are the point, not an accident.
-module(client_test_ffi).

-export([ws_roundtrip/4]).

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
