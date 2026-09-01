-module(tui_gleam_workspace_ffi).

-include_lib("kernel/include/file.hrl").

-export([read_small_regular/2]).

read_small_regular(Path, Limit) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Handle} ->
            try read_open_regular(Handle, Limit)
            after
                _ = file:close(Handle)
            end;
        {error, _} ->
            {error, nil}
    end.

read_open_regular(Handle, Limit) ->
    case file:read_file_info(Handle) of
        {ok, #file_info{type = regular, size = Size}} when Size =< Limit ->
            read_with_limit(Handle, Limit);
        {ok, _} ->
            {error, nil};
        {error, _} ->
            {error, nil}
    end.

read_with_limit(Handle, Limit) ->
    case file:read(Handle, Limit + 1) of
        {ok, Data} when byte_size(Data) =< Limit ->
            {ok, Data};
        eof ->
            {ok, <<>>};
        {ok, _} ->
            {error, nil};
        {error, _} ->
            {error, nil}
    end.
