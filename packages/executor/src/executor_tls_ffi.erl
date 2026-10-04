%% OTP SSL is the missing mutual-authentication boundary; no options escape it.
-module(executor_tls_ffi).
-export([prepare/3, listen/5, accept/3, connect/5, receive_exact/3, send/2,
         transfer/2, close/1, port/1, now/0, start/0]).

start() ->
    case application:ensure_all_started(ssl) of
        {ok, _} -> {ok, nil};
        {error, _} -> {error, unavailable}
    end.

prepare(Ca, Cert, Pem) ->
    try
        _ = public_key:pkix_decode_cert(Ca, otp),
        _ = public_key:pkix_decode_cert(Cert, otp),
        [{Type, Der, not_encrypted}] = public_key:pem_decode(Pem),
        true = lists:member(Type, ['RSAPrivateKey', 'ECPrivateKey', 'PrivateKeyInfo']),
        _ = public_key:der_decode(Type, Der),
        {ok, {Ca, Cert, {Type, Der}}}
    catch _:_ -> {error, invalid_material} end.

%% The callback never overrides a PKIX failure. Pinning happens during the
%% handshake, before an authenticated socket can reach the application.
verify(_, _, {bad_cert, Reason}, _) -> {fail, Reason};
verify(_, _, {extension, _}, Pin) -> {unknown, Pin};
verify(_, _, valid, Pin) -> {valid, Pin};
verify(_, Der, valid_peer, Pin) ->
    case crypto:hash(sha256, Der) of
        Pin -> {valid, Pin};
        _ -> {fail, peer_pin_mismatch}
    end.

options({Ca, Cert, Key}, Pin, SendMs) ->
    [{cacerts, [Ca]}, {cert, Cert}, {key, Key}, {verify, verify_peer},
     {verify_fun, {fun verify/4, Pin}}, {depth, 3},
     {max_handshake_size, 262144},
     {versions, ['tlsv1.3', 'tlsv1.2']}, {reuse_sessions, false},
     {session_tickets, disabled}, {log_level, none}] ++ tcp_options(SendMs).

tcp_options(SendMs) ->
    [{active, false}, {mode, binary}, {packet, raw},
     {send_timeout, SendMs}, {send_timeout_close, true},
     {buffer, 16384}, {recbuf, 16384}, {sndbuf, 16384}].

listen(Material, Pin, Address, Port, SendMs) ->
    Ip = case Address of loopback -> {127,0,0,1}; any_ipv4 -> {0,0,0,0} end,
    safe(fun() -> ssl:listen(Port, options(Material, Pin, SendMs) ++
        [{ip, Ip}, {backlog, 8}, {reuseaddr, true}, {fail_if_no_peer_cert, true}]) end).

accept(Listener, Pin, Ms) ->
    Deadline = ?MODULE:now() + Ms,
    case safe(fun() -> ssl:transport_accept(Listener, Ms) end) of
        {ok, Socket} ->
            case remaining(Deadline) of
                0 -> close(Socket), {error, timed_out};
                Left -> authenticate(Socket, Pin,
                    safe(fun() -> ssl:handshake(Socket, Left) end))
            end;
        Error -> Error
    end.

connect(Material, Pin, Host, Port, SendMsAndDeadline) ->
    {SendMs, Ms} = SendMsAndDeadline,
    Deadline = ?MODULE:now() + Ms,
    Name = binary_to_list(Host),
    Opts = options(Material, Pin, SendMs) ++
        [{server_name_indication, Name}, {customize_hostname_check,
         [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],

    %% OTP ssl:connect/4 renews Timeout after TCP. Keep custody of the passive
    %% TCP socket until ssl:connect/3 upgrades it under the remaining budget.
    case remaining(Deadline) of
        0 -> {error, timed_out};
        Left ->
            case safe(fun() -> gen_tcp:connect(Name, Port, tcp_options(SendMs), Left) end) of
                {ok, Tcp} -> upgrade(Tcp, Opts, Pin, Deadline);
                Error -> Error
            end
    end.

upgrade(Tcp, Opts, Pin, Deadline) ->
    case remaining(Deadline) of
        0 -> close_tcp(Tcp), {error, timed_out};
        Left ->
            case safe(fun() -> ssl:connect(Tcp, Opts, Left) end) of
                {ok, Socket} ->
                    case remaining(Deadline) of
                        0 -> close(Socket), {error, timed_out};
                        _ -> authenticate(Socket, Pin, {ok, Socket})
                    end;

                %% Option failure can precede SSL ownership transfer, whereas
                %% handshake failure can follow it. Raw close covers both and
                %% is harmless if OTP already closed the underlying socket.
                Error -> close_tcp(Tcp), Error
            end
    end.

close_tcp(Socket) ->
    try gen_tcp:close(Socket) catch _:_ -> ok end.

%% Recheck the exact DER after the handshake as a fail-closed export boundary.
authenticate(Socket, Pin, {ok, Socket}) ->
    case ssl:peercert(Socket) of
        {ok, Der} ->
            case crypto:hash(sha256, Der) of
                Pin -> {ok, Socket};
                _ -> close(Socket), {error, peer_rejected}
            end;
        _ -> close(Socket), {error, peer_rejected}
    end;
authenticate(Socket, _, Error) -> close(Socket), Error.

receive_exact(Socket, Size, Ms) ->
    safe(fun() -> ssl:recv(Socket, Size, Ms) end).

send(Socket, Bytes) ->
    case safe(fun() -> ssl:send(Socket, Bytes) end) of
        {ok, nil} = Ok -> Ok;
        Error -> close(Socket), Error
    end.

transfer(Socket, Pid) ->
    case safe(fun() -> ssl:controlling_process(Socket, Pid) end) of
        {ok, nil} = Ok -> Ok;
        _ -> {error, transfer_failed}
    end.

%% Zero waits for no peer close_notify; repeated close remains harmless.
close(Socket) ->
    try ssl:close(Socket, 0) catch _:_ -> ok end,
    nil.
port(Socket) ->
    case safe(fun() -> ssl:sockname(Socket) end) of
        {ok, {_, Port}} -> {ok, Port};
        Error -> Error
    end.
now() -> erlang:monotonic_time(millisecond).
remaining(Deadline) -> max(0, Deadline - ?MODULE:now()).

%% Never render raw OTP errors, which can carry configuration and key bytes.
safe(Fun) ->
    try Fun() of
        ok -> {ok, nil};
        {ok, Value} -> {ok, Value};
        {error, timeout} -> {error, timed_out};
        {error, closed} -> {error, socket_closed};
        {error, {tls_alert, _}} -> {error, peer_rejected};
        {error, _} -> {error, io_failed}
    catch _:_ -> {error, io_failed} end.
