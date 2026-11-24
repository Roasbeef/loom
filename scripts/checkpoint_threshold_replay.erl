%% Compare production planning inputs while a synthetic runtime holds an effect.
%% The deterministic threshold hook reads strand.config through the real SQLite writer.
-module(checkpoint_threshold_replay).
-export([main/0]).
-include("runtime@api_Runtime.hrl").
-include("runtime@effects_Effects.hrl").
-include("runtime@effects_Hooks.hrl").
-include("runtime@effects_ThresholdQuery.hrl").
-include("machine@operation_RunState.hrl").
-include("machine@operation_RunSettings.hrl").
-include("machine@operation_CompactionSettings.hrl").
-include("machine@operation_CancelRequested.hrl").
-include("machine@operation_Checkpoint.hrl").
-include("machine@operation_CheckpointPhase.hrl").
-include("machine@operation_NeedAssistant.hrl").
-include("machine@planner_PlannerInputs.hrl").

main() ->
    try run(), halt(0)
    catch Class:Reason:Stack ->
        io:format("FAILED ~p:~p ~p~n", [Class, Reason, Stack]),
        halt(1)
    end.

run() ->
    nonode@nohost = node(),
    load(os:getenv("THRESHOLD_BASELINE"), threshold_baseline),
    load(code:which('runtime@strand_runtime'), threshold_candidate),
    Path = filename:join(os:getenv("THRESHOLD_FIXTURE"), "session.db"),
    {ok, {Session, Close}} = 'session@session':open_sqlite_owned(
        list_to_binary(Path), <<"threshold-replay">>, 600000, 'core@clock':fixed(1000)),
    try
        nil = 'support@held_operation':run(Session, assistant, 200, fun inspect/1)
    after
        {ok, nil} = Close()
    end.

load(Path, Alias) ->
    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Path, [abstract_code]),
    Renamed = [case Form of
        {attribute, Line, module, 'runtime@strand_runtime'} ->
            {attribute, Line, module, Alias};
        Other -> Other
    end || Form <- Forms],
    {ok, Alias, Binary} = compile:forms(Renamed, [binary, export_all]),
    {module, Alias} = code:load_binary(Alias, "isolated threshold replay", Binary).

inspect({held, Runtime, _Counters} = Held) ->
    {answered, nil} = 'support@held_operation':wait_for_reads(Held, 2),
    {ok, Subject} = 'runtime@supervisor':strand_subject(Runtime#runtime.tree, <<"main">>),
    {ok, Driver} = 'gleam@erlang@process':subject_owner(Subject),
    %% Pausing only this fixture keeps both contenders on the same committed frontier.
    ok = sys:suspend(Driver),
    try
        State = sys:get_state(Driver),
        {ok, {open, Loaded}} = threshold_candidate:load(State),
        {some, Leaf} = element(7, Loaded),
        {ok, {Projected, _}} = threshold_candidate:project_for(State, {some, Leaf}),
        Counter = atomics:new(1, []),
        Run = element(3, Loaded),
        Settings = Run#run_state.settings,
        Compaction = Settings#run_settings.compaction,
        Enabled = Settings#run_settings{compaction=Compaction#compaction_settings{enabled=true}},
        Checkpoint = #checkpoint{checkpoint=#checkpoint_phase{
            trigger=Leaf, continuation=#need_assistant{overflow_recovery_used=false},
            threshold_checked=none, skip_inbox_once=false}},
        Ready = setelement(3, Loaded, Run#run_state{settings=Enabled, phase=Checkpoint}),
        Starting = setelement(3, Loaded, Run#run_state{phase=starting}),
        Cancelled = setelement(3, Ready, (element(3, Ready))#run_state{
            control=#cancel_requested{requested_at=2000, drained_steer=[], drained_follow_up=[]}}),
        HookState = with_hook(State, Counter, {threshold_exceeded, empty_preparation}),
        compare(assistant, HookState, Loaded, Projected, Counter, 0),
        compare(starting, HookState, Starting, Projected, Counter, 0),
        compare(cancelled_checkpoint, HookState, Cancelled, Projected, Counter, 0),
        Action = compare(running_checkpoint, HookState, Ready, Projected, Counter, 1),
        Below = with_hook(State, Counter, threshold_not_exceeded),
        {_, OtherAction} = plan(threshold_candidate, Below, Ready, Projected),
        true = Action =/= OtherAction,
        LoadedAction = fun(Module) -> plan(Module, HookState, Loaded, Projected) end,
        ReloadedAction = fun(Module) -> reload_and_plan(Module, HookState) end,
        {{_, Reloaded}, OldQueries} = counted_load(ReloadedAction, threshold_baseline),
        {{_, Reloaded}, NewQueries} = counted_load(ReloadedAction, threshold_candidate),
        OldQueries = NewQueries + 1,
        io:format("EXACT reload_and_plan sqlite_queries=~p->~p~n", [OldQueries, NewQueries]),
        wall(inputs, LoadedAction, Counter),
        wall(reload_and_plan, ReloadedAction, Counter),
        allocation(LoadedAction)
    after
        ok = sys:resume(Driver)
    end,
    nil.

with_hook(State, Counter, Signal) ->
    Writer = element(3, State),
    Effects = element(5, State),
    Hooks = Effects#effects.hooks,
    ReadThreshold = fun(#threshold_query{strand=Strand}) ->
        {ok, {some, _}} = 'runtime@writer':get_register(Writer, strand_config, Strand),
        atomics:add(Counter, 1, 1),
        Signal
    end,
    setelement(5, State, Effects#effects{
        entropy=fun() -> 17 end, hooks=Hooks#hooks{threshold=ReadThreshold}}).

compare(Name, State, Loaded, Projected, Counter, NewCalls) ->
    atomics:put(Counter, 1, 0),
    {OldInputs, Action} = plan(threshold_baseline, State, Loaded, Projected),
    1 = atomics:get(Counter, 1),
    atomics:put(Counter, 1, 0),
    {NewInputs, Action} = plan(threshold_candidate, State, Loaded, Projected),
    NewCalls = atomics:get(Counter, 1),
    %% Every planner input except an unused threshold must match exactly.
    Threshold = NewInputs#planner_inputs.threshold,
    NewInputs = OldInputs#planner_inputs{threshold=Threshold},
    io:format("EXACT ~s threshold_reads=1->~p~n", [Name, NewCalls]),
    Action.

plan(Module, State, Loaded, Projected) ->
    Inputs = Module:build_inputs(State, Loaded, no_observation, 2000, Projected),
    {Inputs, 'machine@planner':next_action(element(2, Loaded), element(3, Loaded), Inputs)}.

reload_and_plan(Module, State) ->
    {ok, {open, Loaded}} = Module:load(State),
    {ok, {Projected, NextState}} = Module:project_for(State, element(7, Loaded)),
    plan(Module, NextState, Loaded, Projected).

counted_load(Run, Module) ->
    Query = {sqlight, query, 4},
    erlang:trace_pattern(Query, true, [call_count]),
    try
        Result = Run(Module),
        {call_count, Count} = erlang:trace_info(Query, call_count),
        {Result, Count}
    after
        erlang:trace_pattern(Query, false, [call_count])
    end.

wall(Label, Run, Counter) ->
    Count = 400,
    Modules = [threshold_baseline, threshold_candidate],
    lists:foreach(fun(Round) ->
        Order = case Round rem 2 of 1 -> Modules; 0 -> lists:reverse(Modules) end,
        lists:foreach(fun(Module) ->
            atomics:put(Counter, 1, 0),
            {Us, ok} = timer:tc(fun() -> repeat(Count, fun() -> Run(Module) end) end),
            io:format("WALL ~s ~s round=~p us/op=~.3f reads=~p~n",
                [Label, Module, Round, Us / Count, atomics:get(Counter, 1)])
        end, Order)
    end, lists:seq(1, 6)).

allocation(Run) ->
    Count = 1000,
    lists:foreach(fun(Module) ->
        {ok, Profiler} = tprof:start(#{type=>call_memory, session=>threshold_replay}),
        try
            tprof:set_pattern(Profiler, Module, build_inputs, 5),
            tprof:enable_trace(Profiler, self(), #{set_on_spawn=>false}),
            repeat(Count, fun() -> Run(Module) end),
            tprof:pause(Profiler),
            #{all := {_, Words, _}} =
                tprof:inspect(tprof:collect(Profiler), total, {measurement, descending}),
            io:format("HEAP ~s caller_words/op=~.3f~n", [Module, Words / Count])
        after tprof:stop(Profiler) end
    end, [threshold_baseline, threshold_candidate]).

repeat(0, _Run) -> ok;
repeat(N, Run) -> Run(), repeat(N - 1, Run).
