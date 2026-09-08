%% Test-only process and node memory sampling.
%%
%% `erlang:process_info/2` has no pure Gleam equivalent: the whole point of
%% the measurement is the runtime's own accounting of a process, including
%% the refc binaries it references, which no term in the language exposes.
%% This module lives in the test tree so `src` keeps its FFI budget.
-module(tui_probe_ffi).

-export([probe/1, collected/1, node_memory/0]).

%% A leak measurement has to separate what a process retains from what it has
%% merely not collected yet, so every settled sample is taken after a forced
%% collection. Without this the series is dominated by garbage and says
%% nothing about retention either way.
collected(Pid) ->
    erlang:garbage_collect(Pid),
    nil.

%% Words-and-bytes account of one process. `binary` lists every refc binary
%% the process references as `{Id, Size, RefCount}`, so summing the sizes is
%% what a sub-binary leak looks like from outside: text kept is small, bytes
%% pinned are not.
probe(Pid) ->
    case erlang:process_info(Pid, [memory, message_queue_len, heap_size, binary]) of
        undefined ->
            {probe, 0, 0, 0, 0, 0};
        Info ->
            {memory, Memory} = lists:keyfind(memory, 1, Info),
            {message_queue_len, Queue} = lists:keyfind(message_queue_len, 1, Info),
            {heap_size, Heap} = lists:keyfind(heap_size, 1, Info),
            {binary, Binaries} = lists:keyfind(binary, 1, Info),
            Bytes = lists:sum([Size || {_Id, Size, _Refc} <- Binaries]),
            {probe, Memory, Queue, Heap, Bytes, length(Binaries)}
    end.

%% Node totals, for the series a leak hunt reads beside the per-process one.
node_memory() ->
    {node_memory, erlang:memory(total), erlang:memory(binary)}.
