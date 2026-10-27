%% A fixed operator model exercises view construction and Lustre cache reuse.
%% CPU time is measured without tracing. Allocated words are cumulative work,
%% while process capacity and RSS are uncollected observations of this fixture VM.
-module(web_view_perf).
-export([main/1]).

main([Label, Scenario]) ->
    Wire = 'gleam@erlang@process':new_subject(),
    Model = fixture(Wire, Scenario),
    View = 'web_view@operator_page':view(Model),
    Cache = lane_memo_ffi:first(View),
    HandlerHash = binary:decode_unsigned(crypto:hash(sha256,
        term_to_binary(page_events_ffi:handlers(View)))),
    io:format("HANDLERS scenario=~s sha256=~64.16.0b~n", [Scenario, HandlerHash]),
    Html = 'lustre@element':to_string(View),
    %% Moving a memo changes only these bookkeeping comments in initial HTML.
    Visible = re:replace(Html, <<"<!-- lustre:memo(?: key=\"[^\"]*\")? -->">>,
        <<>>, [global, {return, binary}]),
    Hash = binary:decode_unsigned(crypto:hash(sha256, Visible)),
    case os:getenv("WEB_VIEW_PERF_HTML") of
        false -> ok;
        HtmlPath -> ok = file:write_file(HtmlPath, Html)
    end,
    {PatchBytes, _} = lane_memo_ffi:patched(Cache, View,
        'web_view@operator_page':view(Model)),
    io:format("WITNESS scenario=~s html_sha256=~64.16.0b unchanged_patch_bytes=~p~n",
        [Scenario, Hash, PatchBytes]),
    io:format("VM otp=~s word_bytes=~p schedulers=~p~n",
        [erlang:system_info(otp_release), erlang:system_info(wordsize),
         erlang:system_info(schedulers_online)]),
    measure(Label, Scenario, "unchanged", 1000,
        fun() -> repeat(1000, Model, View, Cache) end),
    measure(Label, Scenario, "first_paint", 30,
        fun() -> first_paints(30, Model) end),
    halt().

measure(Label, Scenario, Phase, Count, Run) ->
    Run(),
    BeforeMemory = memory(),
    {reductions, Before} = process_info(self(), reductions),
    {CpuBefore, _} = statistics(runtime),
    {Time, _} = timer:tc(Run),
    {CpuAfter, _} = statistics(runtime),
    {reductions, After} = process_info(self(), reductions),
    AfterMemory = memory(),
    {ok, Profiler} = tprof:start(#{type => call_memory, session => web_view_perf}),
    try
        tprof:set_pattern(Profiler, '_', '_', '_'),
        tprof:enable_trace(Profiler, self(), #{set_on_spawn => false}),
        Run(),
        tprof:pause(Profiler),
        Profile = tprof:collect(Profiler),
        #{all := {_, Words, Rows}} = tprof:inspect(Profile, total, {measurement, descending}),
        io:format("RESULT ~s scenario=~s phase=~s n=~p reductions=~p us=~p cpu_ms=~p words=~p bytes=~p~n",
            [Label, Scenario, Phase, Count, After - Before, Time,
             CpuAfter - CpuBefore, Words, Words * erlang:system_info(wordsize)]),
        io:format("MEMORY phase=~s before=~p after=~p~n",
            [Phase, BeforeMemory, AfterMemory]),
        tprof:format(#{all => {call_memory, Words, lists:sublist(Rows, 15)}})
    after
        tprof:stop(Profiler)
    end.

fixture(_Wire, "peers-" ++ Rest) ->
    [Count, Phase] = string:split(Rest, "-"),
    io:format("CATALOGUE submitted=~p listed=~p phase=~s~n",
        [list_to_integer(Count), min(list_to_integer(Count), 100), Phase]),
    peer_links_test:catalogue_fixture(list_to_integer(Count), list_to_binary(Phase));
fixture(Wire, Scenario) ->
    Ready = page_fixture:ready(Wire, <<"operator">>),
    'web_view@component':apply(Ready, [capture(Scenario)]).

capture("siblings") -> lane_fixture:siblings();
capture("reasoning") ->
    lane_fixture:reasoned(0, 40, {some, lane_fixture:main_op()});
capture("answers") -> lane_fixture:reasoned_answers(40, none).

repeat(0, _, _, _) -> ok;
repeat(Count, Model, View, Cache) ->
    Next = 'web_view@operator_page':view(Model),
    Updated = lane_memo_ffi:rerender(Cache, View, Next),
    repeat(Count - 1, Model, Next, Updated).

first_paints(0, _) -> ok;
first_paints(Count, Model) ->
    _ = lane_memo_ffi:first('web_view@operator_page':view(Model)),
    first_paints(Count - 1, Model).

memory() ->
    #{process => process_info(self(), [memory, total_heap_size]),
      vm => erlang:memory([total, processes, binary]), rss_kib => rss()}.

rss() ->
    case string:to_integer(string:trim(os:cmd("ps -o rss= -p " ++ os:getpid()))) of
        {Value, []} -> Value;
        _ -> unavailable
    end.
