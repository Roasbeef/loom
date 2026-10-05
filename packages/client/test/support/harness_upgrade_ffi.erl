%% Test-only compiled reviewed implementations. Real new BEAM bytes are created
%% after recipient startup, rather than selecting callbacks present at boot.
-module(harness_upgrade_ffi).
-export([pause_slots/0, pause_pid/1, resume_pid/1, queued_controls/2]).
-export([compile_fixture/4, hold/2, queued/2, paused_pid/1, continue_worker/1, monitor_count/1]).

compile_fixture(Slot, Version, Mode, Observer) ->
    Module = case Slot of <<"a">> -> loom_scratch_a; <<"b">> -> loom_scratch_b end,
    case Mode of <<"hold">> -> persistent_term:put(harness_upgrade_observer, Observer); _ -> ok end,
    V = erl_parse:abstract(Version),
    S = {var, 1, 'State'}, M = {var, 1, 'Message'},
    Remote = fun(Mod, F, Args) -> {call, 1, {remote, 1, {atom, 1, Mod}, {atom, 1, F}}, Args} end,
    Transform = case Mode of
        <<"reject">> -> erl_parse:abstract({error, <<"reviewed migration refused">>});
        <<"crash">> -> Remote(erlang, error, [{atom, 1, regression_crash}]);
        <<"timeout">> -> {block, 1, [Remote(timer, sleep, [{integer, 1, 250}]), {tuple, 1, [{atom, 1, ok}, S]}]};
        <<"hold">> -> Remote(harness_upgrade_ffi, hold, [S, {atom, 1, fixture_observer}]);
        _ -> {tuple, 1, [{atom, 1, ok}, S]}
    end,
    VersionBody = case Mode of
        <<"hang_version">> -> {block, 1, [Remote(timer, sleep, [{integer, 1, 250}]), V]};
        _ -> V
    end,
    Exports = case Mode of
        <<"badabi">> -> [{handle, 2}, {version, 0}];
        _ -> [{handle, 2}, {version, 0}, {migrate, 1}]
    end,
    Forms = [
        {attribute, 1, module, Module},
        {attribute, 1, export, Exports},
        {function, 1, version, 0, [{clause, 1, [], [], [VersionBody]}]},
        {function, 1, handle, 2, [{clause, 1, [S, M], [], [Remote('client@scratch', handle_release, [S, M, V])]}]},
        {function, 1, migrate, 1, [{clause, 1, [S], [], [Transform]}]}
    ],
    case compile:forms(Forms, [binary, return_errors, return_warnings]) of
        {ok, Module, Bytes, _} -> {ok, Bytes};
        _ -> {error, <<"native reviewed fixture compilation failed">>}
    end.

%% Instrumentation deliberately has effects to establish overlap. Released
%% migration code uses the pure current-state transform, never this test helper.
hold(State, _Observer) ->
    Observer = persistent_term:get(harness_upgrade_observer),
    Observer ! {harness_migration_paused, self()},
    receive harness_continue -> {ok, State}
    after 1000 -> {error, <<"fixture release was not delivered">>}
    end.

queued(Pid, Key) ->
    case erlang:process_info(Pid, messages) of
        {messages, Messages} -> lists:any(fun(Msg) -> contains(Msg, Key) end, Messages);
        _ -> false
    end.
contains({set, Key, _, _}, Key) -> true;
contains(Term, Key) when is_tuple(Term) -> lists:any(fun(Item) -> contains(Item, Key) end, tuple_to_list(Term));
contains(_, _) -> false.

paused_pid({harness_migration_paused, Pid}) when is_pid(Pid) -> {ok, Pid};
paused_pid(_) -> {error, nil}.
continue_worker(Pid) -> Pid ! harness_continue, nil.

monitor_count(Pid) ->
    {monitored_by, Owners} = erlang:process_info(Pid, monitored_by),
    length(Owners).

%% Scheduler suspension supplies a deterministic message-delivery barrier.
pause_slots() ->
    Pid = whereis(loom_reviewed_scratch_slots),
    true = erlang:suspend_process(Pid), Pid.
pause_pid(Pid) -> true = erlang:suspend_process(Pid), nil.
resume_pid(Pid) -> true = erlang:resume_process(Pid), nil.
queued_controls(Pid, Kind) ->
    Tag = case Kind of
        <<"acquire">> -> acquire;
        <<"confirm">> -> confirm;
        <<"disarm">> -> disarm
    end,
    {messages, Messages} = erlang:process_info(Pid, messages),
    length([M || M <- Messages, has_control(M, Tag)]).
has_control(Term, Tag) when is_tuple(Term), tuple_size(Term) > 0 ->
    element(1, Term) =:= Tag orelse
        lists:any(fun(Item) -> has_control(Item, Tag) end, tuple_to_list(Term));
has_control(_, _) -> false.
