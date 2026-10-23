%% Standard sys operations are called only by the trusted satellite controller.
-module(ext_live_sys).
-export([suspend/2, change/3, resume/2, now/0]).
now() -> erlang:system_time(millisecond).
suspend(Pid, Within) -> bounded(fun() -> sys:suspend(Pid, Within) end).
change(Pid, Extra, Within) ->
    bounded(fun() -> sys:change_code(Pid, ext_live_sys, undefined, Extra, Within) end).
resume(Pid, Within) -> bounded(fun() -> sys:resume(Pid, Within) end).
bounded(Call) ->
    try Call() of
        ok -> {ok, nil};
        {error, Reason} -> {error, iolist_to_binary(io_lib:format("~p", [Reason]))};
        _ -> {error, <<"unexpected sys reply">>}
    catch _:_ -> {error, <<"state owner sys operation failed">>} end.
