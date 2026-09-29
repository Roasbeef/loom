%% Lustre's render cache, for lane_memo_test, live_test and delivery_test. The server
%% runtime builds the cache from its first view with
%% lustre/vdom/cache:from_node/1 and carries it through every later render
%% with lustre/vdom/diff:diff/3. Both modules are internal to Lustre, so the
%% test calls them from Erlang instead of importing them.
-module(lane_memo_ffi).
-export([first/1, rerender/3, patched/3, wire_bytes/1]).

first(View) -> 'lustre@vdom@cache':from_node(View).

%% diff/3 returns {diff, Patch, Cache}; the test keeps the cache.
rerender(Cache, Old, New) -> element(3, 'lustre@vdom@diff':diff(Cache, Old, New)).

%% The same render, with the size in bytes of the patch the runtime would
%% broadcast for it: the diff encoded as JSON the way the server runtime's
%% transport encodes it, against the memos the new cache holds. Returns
%% {Bytes, Cache}.
patched(Cache, Old, New) ->
    {diff, Patch, Next} = 'lustre@vdom@diff':diff(Cache, Old, New),
    Json = 'lustre@vdom@patch':to_json(Patch, 'lustre@vdom@cache':memos(Next)),
    {byte_size(iolist_to_binary(gleam@json:to_string(Json))), Next}.

%% The size in bytes of one message the server runtime hands a client, as
%% the runtime's transport encodes it. delivery_test measures the patches a
%% burst of frames actually broadcasts.
wire_bytes(Message) ->
    Json = 'lustre@server_component':client_message_to_json(Message),
    byte_size(iolist_to_binary(gleam@json:to_string(Json))).
