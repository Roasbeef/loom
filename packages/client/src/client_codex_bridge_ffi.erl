%% Raw port and registry operations for client/codex_bridge.gleam. The
%% process state machine, request IDs and frame interpretation stay in Gleam.
-module(client_codex_bridge_ffi).
-export([open_stdio/2, port_send/2, port_event/1, claim/2, lookup/1]).

-define(TABLE, client_codex_bridge_profiles).
-define(MAX_FRAME, 4194304).

open_stdio(Executable, Profile) ->
    try erlang:open_port(
          {spawn_executable, unicode:characters_to_list(Executable)},
          [binary, stream, exit_status, hide,
           {args, ["--profile", unicode:characters_to_list(Profile)]}]) of
        Port -> {ok, Port}
    catch
        error:enoent -> {error, <<"helper executable not found">>};
        _:_ -> {error, <<"helper process could not be started">>}
    end.

port_send(Port, Json) when is_binary(Json), byte_size(Json) > 0,
                           byte_size(Json) =< ?MAX_FRAME ->
    try erlang:port_command(Port, <<(byte_size(Json)):32/big, Json/binary>>) of
        true -> {ok, nil}
    catch
        _:_ -> {error, nil}
    end;
port_send(_, _) -> {error, nil}.

port_event({Port, {data, Bytes}}) when is_port(Port), is_binary(Bytes) ->
    {port_bytes, Bytes};
port_event({Port, {exit_status, Status}}) when is_port(Port), is_integer(Status) ->
    {port_closed, Status};
port_event(_) -> port_invalid.

claim(Profile, Subject) when is_binary(Profile) ->
    %% The table is owned by this actor and therefore covers exactly one
    %% profile. A second actor cannot insert a row into a table that would
    %% disappear on the first actor's death. Two concurrent creators race
    %% only on ets:new; its winner alone owns the profile lock.
    try ets:new(?TABLE, [named_table, public, set,
                         {read_concurrency, true}]) of
        _ ->
            true = ets:insert_new(?TABLE, {Profile, Subject}),
            {ok, nil}
    catch
        error:badarg -> {error, <<"another subscription profile is active">>}
    end.

lookup(Profile) when is_binary(Profile) ->
    case ets:whereis(?TABLE) of
        undefined -> {error, <<"subscription profile is not active">>};
        _ -> lookup_live(Profile)
    end.

lookup_live(Profile) ->
    try case ets:lookup(?TABLE, Profile) of
        [{Profile, {subject, Pid, _} = Subject}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Subject};
                false -> {error, <<"subscription profile is not active">>}
            end;
        [] ->
            case ets:first(?TABLE) of
                '$end_of_table' -> {error, <<"subscription profile is not active">>};
                _ -> {error, <<"another subscription profile is active">>}
            end
    end catch error:badarg ->
        {error, <<"subscription profile is not active">>}
    end.
