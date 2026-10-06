%% A fixed operator model exercises view construction and Lustre cache reuse.
%% Allocated words are cumulative work, not live heap or resident memory.
-module(web_view_perf).
-export([main/1]).

main([Label]) ->
    Wire = 'gleam@erlang@process':new_subject(),
    Ready = page_fixture:ready(Wire, <<"operator">>),
    Model = 'web_view@component':apply(Ready, [lane_fixture:siblings()]),
    View = 'web_view@operator_page':view(Model),
    Cache = lane_memo_ffi:first(View),
    Run = fun() -> repeat(100, Model, View, Cache) end,
    Run(),
    {reductions, Before} = process_info(self(), reductions),
    {Time, _} = timer:tc(Run),
    {reductions, After} = process_info(self(), reductions),
    {ok, Profiler} = tprof:start(#{type => call_memory, session => web_view_perf}),
    try
        tprof:set_pattern(Profiler, '_', '_', '_'),
        tprof:enable_trace(Profiler, self(), #{set_on_spawn => false}),
        Run(),
        tprof:pause(Profiler),
        Profile = tprof:collect(Profiler),
        #{all := {_, Words, Rows}} = tprof:inspect(Profile, total, {measurement, descending}),
        io:format("RESULT ~s unchanged_renders=100 reductions=~p us=~p words=~p~n",
            [Label, After - Before, Time, Words]),
        tprof:format(#{all => {call_memory, Words, lists:sublist(Rows, 15)}})
    after
        tprof:stop(Profiler)
    end,
    halt().

repeat(0, _, _, _) -> ok;
repeat(Count, Model, View, Cache) ->
    Next = 'web_view@operator_page':view(Model),
    Updated = lane_memo_ffi:rerender(Cache, View, Next),
    repeat(Count - 1, Model, Next, Updated).
