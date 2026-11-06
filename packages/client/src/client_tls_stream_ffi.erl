%% A mutually authenticated TLS stream of length-prefixed frames, for the link
%% between an orchestrator and an untrusted executor (protocol-change/109),
%% reached only through client/internal/ffi_tls_stream.gleam.
%%
%% Neither gleam_stdlib, gleam_erlang, gleam_otp nor weft opens a TLS socket,
%% and the one HTTP server in the tree (mist) does not verify a pinned client
%% certificate, so the ssl calls live here. The boundary fixes every option: it
%% accepts no option list, no callback and no atom from its caller. A peer is
%% admitted only when its leaf chains to the configured authority (every PKIX
%% failure is kept) and the SHA-256 of the leaf's DER is one of the configured
%% pins, which is the same rule `client_distribution_ffi:verify/4` applies,
%% without the node name, since nothing here is a distribution node.
%%
%% Frames are `{packet, 4}` with a `packet_size` the caller names, so the
%% socket refuses an oversized frame before buffering it and the connection
%% ends. Reads are `{active, once}`: the owning process sees at most one
%% `{ssl, Socket, Frame}` message before it asks for the next, which is the
%% backpressure that bounds what one peer can make the owner hold.
%%
%% Nothing read from the network becomes an atom or a term: frames are
%% binaries, and the Gleam side decodes them as JSON.
-module(client_tls_stream_ffi).
-export([listen/7, accept/2, handshake/2, connect/8, send/2, arm/1, hand_to/2, close/1,
         close_listener/1, peer_pin/1, port_of/1, verify/4]).
-include_lib("public_key/include/public_key.hrl").

%% Listens on Port (0 picks one) at Address, a binary IP literal or the empty
%% binary for every interface, with this node's credentials and the pins of
%% the peers it admits. The handshake happens in handshake/2, so a slow or hostile
%% client cannot hold the listener.
listen(Address, Port, Ca, Cert, Key, Pins, MaxFrame) ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        Bind = case Address of
            <<>> -> [];
            Text ->
                {ok, Ip} = inet:parse_address(binary_to_list(Text)),
                [{ip, Ip}]
        end,
        Options = Bind ++ [{reuseaddr, true}, {fail_if_no_peer_cert, true}
                           | stream_options(Ca, Cert, Key, Pins, MaxFrame)],
        case ssl:listen(Port, Options) of
            {ok, Listener} -> {ok, Listener};
            {error, _} -> {error, unavailable}
        end
    catch _:_ -> {error, invalid_configuration}
    end.

%% Waits up to WithinMs for one connection and returns it before its
%% handshake, so the acceptor never waits on a slow or hostile client: the
%% process that will own the connection runs handshake/2.
accept(Listener, WithinMs) ->
    case ssl:transport_accept(Listener, WithinMs) of
        {ok, Raw} -> {ok, Raw};
        {error, timeout} -> {error, timed_out};
        {error, closed} -> {error, closed};
        {error, _} -> {error, unavailable}
    end.

%% Runs the server side of the handshake within WithinMs. Only the stream's
%% controlling process may call this.
handshake(Raw, WithinMs) ->
    case ssl:handshake(Raw, WithinMs) of
        {ok, Stream} -> {ok, Stream};
        {error, timeout} -> close(Raw), {error, timed_out};
        {error, _} -> close(Raw), {error, refused}
    end.

%% Dials Host:Port and runs the handshake within WithinMs. The calling process
%% becomes the stream's controlling process.
connect(Host, Port, Ca, Cert, Key, Pin, MaxFrame, WithinMs) ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        Target = case inet:parse_address(binary_to_list(Host)) of
            {ok, Ip} -> Ip;
            {error, _} -> binary_to_list(Host)
        end,
        %% The pin is the peer's identity, so the host name check is not
        %% asked: a certificate for an IP literal or an internal name is
        %% admitted by its digest alone.
        Options = [{server_name_indication, disable}
                   | stream_options(Ca, Cert, Key, [Pin], MaxFrame)],
        case ssl:connect(Target, Port, Options, WithinMs) of
            {ok, Stream} -> {ok, Stream};
            {error, timeout} -> {error, timed_out};
            {error, {tls_alert, _}} -> {error, refused};
            {error, _} -> {error, unavailable}
        end
    catch _:_ -> {error, invalid_configuration}
    end.

stream_options(Ca, Cert, Key, Pins, MaxFrame) ->
    [binary,
     {active, false},
     {packet, 4},
     {packet_size, MaxFrame},
     %% A peer that stops reading must not park the sender in send/2, which
     %% would stop it serving every session on the link; the send fails and
     %% the connection closes.
     {send_timeout, 30000},
     {send_timeout_close, true},
     {cacertfile, binary_to_list(Ca)},
     {certfile, binary_to_list(Cert)},
     {keyfile, binary_to_list(Key)},
     {verify, verify_peer},
     {versions, ['tlsv1.3']},
     {verify_fun, {fun ?MODULE:verify/4, Pins}},
     {log_level, none}].

%% The certificate callback: every PKIX failure stands, and the leaf must hash
%% to a configured pin.
verify(_Cert, _Der, {bad_cert, Reason}, _Pins) -> {fail, Reason};
verify(_Cert, _Der, {extension, _}, Pins) -> {unknown, Pins};
verify(_Cert, _Der, valid, Pins) -> {valid, Pins};
verify(_Cert, Der, valid_peer, Pins) ->
    case lists:member(crypto:hash(sha256, Der), Pins) of
        true -> {valid, Pins};
        false -> {fail, peer_identity_mismatch}
    end.

%% Sends one frame. The socket adds the length prefix.
send(Stream, Frame) ->
    case ssl:send(Stream, Frame) of
        ok -> {ok, nil};
        {error, closed} -> {error, closed};
        {error, _} -> {error, unavailable}
    end.

%% Asks for the next frame as one message to the controlling process.
arm(Stream) ->
    case ssl:setopts(Stream, [{active, once}]) of
        ok -> {ok, nil};
        {error, closed} -> {error, closed};
        {error, _} -> {error, unavailable}
    end.

%% Makes Pid the stream's controlling process. Only the current controlling
%% process may call this.
hand_to(Stream, Pid) ->
    case ssl:controlling_process(Stream, Pid) of
        ok -> {ok, nil};
        {error, closed} -> {error, closed};
        {error, _} -> {error, unavailable}
    end.

close(Stream) ->
    try ssl:close(Stream) catch _:_ -> ok end,
    nil.

close_listener(Listener) ->
    try ssl:close(Listener) catch _:_ -> ok end,
    nil.

%% The SHA-256 of the peer's leaf, which is the identity the handshake admitted.
peer_pin(Stream) ->
    case ssl:peercert(Stream) of
        {ok, Der} -> {ok, crypto:hash(sha256, Der)};
        {error, _} -> {error, unavailable}
    end.

%% The port a listener is bound to, for a listener started on port 0.
port_of(Listener) ->
    case ssl:sockname(Listener) of
        {ok, {_Ip, Port}} -> {ok, Port};
        {error, _} -> {error, unavailable}
    end.
