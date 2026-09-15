%% Shared bounded gzip inflation. OTP zlib has no Gleam wrapper.
-module(host_zlib_ffi).
-export([inflate_gzip/2]).

inflate_gzip(Bytes, Limit) when is_binary(Bytes), is_integer(Limit) ->
    Z = zlib:open(),
    try
        zlib:inflateInit(Z, 31),
        inflate_bounded(Z, Bytes, Limit, 0, [])
    catch
        _:_ -> {error, stream_corrupt}
    after
        zlib:close(Z)
    end.

%% Input is handed to safeInflate on the first call only; every later call
%% passes <<>> so zlib drains what it already holds.
inflate_bounded(Z, Input, Limit, Written, Acc) ->
    case zlib:safeInflate(Z, Input) of
        {continue, Output} ->
            inflate_more(Z, Limit, Written + iolist_size(Output),
                         [Acc, Output]);
        {finished, Output} ->
            inflate_done(Limit, Written + iolist_size(Output), [Acc, Output])
    end.

inflate_more(Z, Limit, Written, Acc) when Written =< Limit ->
    inflate_bounded(Z, <<>>, Limit, Written, Acc);
inflate_more(_Z, _Limit, _Written, _Acc) ->
    {error, output_too_large}.

inflate_done(Limit, Written, Acc) when Written =< Limit ->
    {ok, iolist_to_binary(Acc)};
inflate_done(_Limit, _Written, _Acc) ->
    {error, output_too_large}.

