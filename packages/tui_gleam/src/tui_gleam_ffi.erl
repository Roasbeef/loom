-module(tui_gleam_ffi).

-include_lib("kernel/include/file.hrl").

-export([read_prefix/2, read_bounded/2]).

read_prefix(Path, Bytes) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Handle} ->
            Result = case file:read_file_info(Handle) of
                {ok, #file_info{type = regular}} ->
                    case file:read(Handle, Bytes) of
                        {ok, Data} -> {ok, Data};
                        eof -> {ok, <<>>};
                        {error, Reason} -> {error, describe(Reason)}
                    end;
                {ok, _} ->
                    {error, <<"not a regular file">>};
                {error, Reason} ->
                    {error, describe(Reason)}
            end,
            _ = file:close(Handle),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

read_bounded(Path, Limit) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Handle} ->
            Result = case file:read_file_info(Handle) of
                {ok, #file_info{type = regular}} ->
                    read_bounded_loop(Handle, Limit, 0, []);
                {ok, _} ->
                    {error, <<"not a regular file">>};
                {error, Reason} ->
                    {error, describe(Reason)}
            end,
            _ = file:close(Handle),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

read_bounded_loop(Handle, Limit, Limit, Chunks) ->
    case file:read(Handle, 1) of
        eof -> {ok, iolist_to_binary(lists:reverse(Chunks))};
        {ok, _} -> {error, <<"file exceeds the bounded read limit">>};
        {error, Reason} -> {error, describe(Reason)}
    end;
read_bounded_loop(Handle, Limit, Total, Chunks) ->
    Remaining = Limit - Total,
    ChunkSize = erlang:min(Remaining, 65536),
    case file:read(Handle, ChunkSize) of
        eof ->
            {ok, iolist_to_binary(lists:reverse(Chunks))};
        {ok, Data} ->
            read_bounded_loop(
                Handle,
                Limit,
                Total + byte_size(Data),
                [Data | Chunks]
            );
        {error, Reason} ->
            {error, describe(Reason)}
    end.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
