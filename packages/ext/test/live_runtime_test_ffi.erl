%% Fixed trusted fixture compilation never runs authored code in the harness.
-module(live_runtime_test_ffi).
-export([artifact/0, counter/0, first/1, queued/1]).
artifact() ->
    Forms = [form(S) || S <- [
        "-module('loom_live_b@fixture').",
        "-export([definition/0, migrate/2, handle/2]).",
        "definition() -> {definition, <<\"0\">>, fun handle/2}.",
        "handle(State, _) -> {ok, {integer_to_binary(binary_to_integer(State)+2), {refused, <<\"fixture\">>, <<\"ok\">>}}}.",
        "migrate(_, State) -> {ok, integer_to_binary(binary_to_integer(State)+100)}."
    ]],
    {ok, _, Bytes} = compile:forms(Forms, [binary, no_spawn_compiler_process]),
    Digest = <<"sha256-", (binary:encode_hex(crypto:hash(sha256, Bytes), lowercase))/binary>>,
    {Bytes, Digest}.
form(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    {ok, Form} = erl_parse:parse_form(Tokens),
    Form.

%% A counter changes acknowledgement delivery only after the actual sys call.
counter() -> atomics:new(1, []).
first(Counter) -> atomics:add_get(Counter, 1, 1) =:= 1.

%% Observation does not consume queued work or alter actor scheduling.
queued(Pid) ->
    {messages, Messages} = process_info(Pid, messages),
    lists:any(fun({_, Message}) when is_tuple(Message) -> element(1, Message) =:= invoke; (_) -> false end, Messages).
