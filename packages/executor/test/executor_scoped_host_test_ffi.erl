%% Fixed test-role Subject transport contains no code or replacement services.
-module(executor_scoped_host_test_ffi).
-export([publish/2, read/1, suspend/1, resume/1]).

publish(Path, Door = {subject, Pid, Tag}) when is_pid(Pid), is_reference(Tag) ->
    Bytes = term_to_binary(Door),
    case byte_size(Bytes) =< 1024 of
        true -> case file:write_file(<<Path/binary, ".part">>, Bytes, [binary]) of
                    ok -> case file:rename(<<Path/binary, ".part">>, Path) of
                              ok -> {ok, nil}; _ -> {error, nil}
                          end;
                    _ -> {error, nil}
                end;
        false -> {error, nil}
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} when byte_size(Bytes) =< 1024 ->
            try binary_to_term(Bytes, [safe]) of
                Door = {subject, Pid, Tag} when is_pid(Pid), is_reference(Tag) ->
                    {ok, Door};
                _ -> {error, nil}
            catch _:_ -> {error, nil} end;
        _ -> {error, nil}
    end.

%% Fixed faults act on real local actors; they do not inspect or alter state.
suspend(Pid) -> try sys:suspend(Pid, 1000) of ok -> {ok, nil} catch _:_ -> {error, nil} end.
resume(Pid) -> try sys:resume(Pid, 1000) of ok -> {ok, nil} catch _:_ -> {error, nil} end.
