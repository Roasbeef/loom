%% OTP JSON is used only at impure byte boundaries, never from pure core.
%% Its callbacks construct core's value ABI without an intermediate map tree.
-module(json_codec_ffi).
-export([parse/2]).

parse(Input, MaximumDepth) ->
    Start = fun(Acc) -> start(Acc, MaximumDepth) end,
    Decoders = #{array_start => Start, array_push => fun array_push/2,
        array_finish => fun array_finish/2, object_start => Start,
        object_push => fun object_push/3, object_finish => fun object_finish/2,
        string => fun(Value) -> {string, Value} end,
        integer => fun(Value) -> {int, binary_to_integer(Value)} end,
        float => fun decode_float/1, null => null},
    try json:decode(Input, {0, [], #{}}, Decoders) of
        {Value, _, <<>>} -> {ok, boolean_value(Value)};
        {_, _, _Rest} -> 'core@json':parse(Input)
    catch
        %% OTP and the reference use different error vocabularies. The native
        %% attempt never publishes a partial value, and the reference owns every
        %% refusal, including byte/codepoint offsets and malformed UTF-8.
        error:_ -> 'core@json':parse(Input)
    end.

%% OTP normalizes exponent-only negative zero before invoking this callback.
%% A zero-valued float therefore needs the original text and reference parser
%% to preserve its sign; recovering it here would require another number lexer.
decode_float(Text) ->
    Value = binary_to_float(Text),
    case Value == 0.0 of
        true -> error(reference_float_zero);
        false -> {float, Value}
    end.

start({Depth, _, _}, MaximumDepth) when Depth < MaximumDepth ->
    {Depth + 1, [], #{}};
start(_, _) -> error(depth_limit).

array_push(Value, {Depth, Items, Seen}) ->
    {Depth, [boolean_value(Value) | Items], Seen}.

array_finish({_, Items, _}, Parent) ->
    {{array, lists:reverse(Items)}, Parent}.

object_push({string, Key}, Value, {Depth, Fields, Seen}) ->
    case is_map_key(Key, Seen) of
        true -> error(duplicate_key);
        false -> {Depth, [{Key, boolean_value(Value)} | Fields], Seen#{Key => true}}
    end.

object_finish({_, Fields, _}, Parent) ->
    {{object, lists:reverse(Fields)}, Parent}.

%% OTP has no boolean callback; normalize that scalar at its parent or root.
boolean_value(true) -> {bool, true};
boolean_value(false) -> {bool, false};
boolean_value(Value) -> Value.
