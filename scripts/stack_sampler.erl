%% Wall-clock stack sampling of a running Loom node, taken from outside it.
%%
%% Diagnostic tooling, not part of the server or the client, in the same
%% family as mem_report.erl. A release carries no OTP `tools` application, so
%% eprof and fprof are unavailable inside it; this module needs nothing but
%% the kernel. It connects to a node started with --profile, loads itself
%% onto that node, and samples every process's current stack at a fixed
%% interval while the operation under study runs.
%%
%% Only processes that are running, runnable or collecting garbage are
%% counted, so a sample is CPU work, not a process parked in receive. The
%% report has three tables: the frame on top of each busy stack (where the
%% time is spent), every distinct frame on a busy stack (what the time is
%% spent under), and the initial call of each busy process (who spends it).
%% The busy fraction says how much of the window any process was working,
%% which separates a slow computation from a slow wait.
%%
%% Usage, from a host OTP of the release's own version:
%%   erl -name s@127.0.0.1 -noshell -pa <dir> -run stack_sampler main \
%%       <node> <cookie-file> <window-ms> [interval-ms] [top-n]
-module(stack_sampler).
-export([main/1, sample/2, calls/2]).

main(["calls", NodeStr, CookieFile, MillisStr, ModulesStr]) ->
    Node = attach(NodeStr, CookieFile),
    Millis = list_to_integer(MillisStr),
    Modules = [list_to_atom(M) || M <- string:split(ModulesStr, ",", all)],
    Rows = rpc:call(Node, ?MODULE, calls, [Millis, Modules], Millis + 60000),
    io:format("~n== own time by function (call_time), top 50~n"),
    io:format("  ~10s ~9s  ~s~n", ["own ms", "calls", "function"]),
    [io:format("  ~10.1f ~9b  ~s~n", [Us / 1000, N, format(MFA)])
     || {MFA, N, Us} <- lists:sublist(Rows, 50)],
    erlang:halt(0, [{flush, true}]);
main([NodeStr, CookieFile, MillisStr | Rest]) ->
    Node = attach(NodeStr, CookieFile),
    {Interval, Top} = case Rest of
        [] -> {2, 30};
        [I] -> {list_to_integer(I), 30};
        [I, T | _] -> {list_to_integer(I), list_to_integer(T)}
    end,
    Millis = list_to_integer(MillisStr),
    {Samples, Busy, Tops, Under, Owners} =
        rpc:call(Node, ?MODULE, sample, [Millis, Interval], Millis + 30000),
    io:format("samples ~p, busy ~p (~.1f%)~n",
              [Samples, Busy, 100 * Busy / max(Samples, 1)]),
    report("top of busy stack", Tops, Top),
    report("anywhere on busy stack", Under, Top),
    report("busy process initial call", Owners, Top),
    erlang:halt(0, [{flush, true}]).

%% Connects to the node and loads this module onto it, so the sampling loop
%% runs beside the processes it watches rather than over distribution.
attach(NodeStr, CookieFile) ->
    Node = list_to_atom(NodeStr),
    {ok, CookieText} = file:read_file(CookieFile),
    Cookie = list_to_atom(string:trim(binary_to_list(CookieText))),
    erlang:set_cookie(Node, Cookie),
    true = connect(Node, 300),
    {Module, Binary, File} = code:get_object_code(?MODULE),
    {module, Module} = rpc:call(Node, code, load_binary, [Module, File, Binary]),
    Node.

%% A launcher names its node before the emulator behind it has booted, so
%% the first attempts can find nothing listening yet.
connect(_Node, 0) -> false;
connect(Node, Tries) ->
    case net_kernel:connect_node(Node) of
        true -> true;
        _ -> timer:sleep(10), connect(Node, Tries - 1)
    end.

report(Title, Counts, Top) ->
    Sorted = lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(Counts))), Top),
    io:format("~n== ~s~n", [Title]),
    [io:format("  ~7b  ~s~n", [N, format(K)]) || {K, N} <- Sorted],
    ok.

format({M, F, A}) -> io_lib:format("~p:~p/~p", [M, F, A]);
format(Other) -> io_lib:format("~p", [Other]).

%% Runs on the target node. The sampler's own process is excluded so the
%% walk does not count itself.
sample(Millis, Interval) ->
    Deadline = erlang:monotonic_time(millisecond) + Millis,
    loop(Deadline, Interval, {0, 0, #{}, #{}, #{}}).

loop(Deadline, Interval, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Acc;
        false ->
            Next = take(Acc),
            timer:sleep(Interval),
            loop(Deadline, Interval, Next)
    end.

take({Samples, Busy, Tops, Under, Owners}) ->
    Self = self(),
    Stacks = [S || P <- erlang:processes(), P =/= Self, S <- [busy_stack(P)], S =/= none],
    {Tops1, Under1, Owners1} = lists:foldl(fun count/2, {Tops, Under, Owners}, Stacks),
    Busy1 = case Stacks of [] -> Busy; _ -> Busy + 1 end,
    {Samples + 1, Busy1, Tops1, Under1, Owners1}.

busy_stack(Pid) ->
    case erlang:process_info(Pid, [status, current_stacktrace, initial_call, dictionary]) of
        [{status, Status}, {current_stacktrace, Stack}, {initial_call, Initial}, {dictionary, Dict}]
          when Status =:= running; Status =:= runnable; Status =:= garbage_collecting ->
            Owner = case lists:keyfind('$initial_call', 1, Dict) of
                {_, Proc} -> Proc;
                false -> Initial
            end,
            {[mfa(F) || F <- Stack], Owner};
        _ -> none
    end.

mfa({M, F, A, _}) when is_integer(A) -> {M, F, A};
mfa({M, F, Args, _}) when is_list(Args) -> {M, F, length(Args)}.

count({[], Owner}, {Tops, Under, Owners}) ->
    {Tops, Under, bump(Owner, Owners)};
count({[First | _] = Stack, Owner}, {Tops, Under, Owners}) ->
    Distinct = lists:usort(Stack),
    {bump(First, Tops), lists:foldl(fun bump/2, Under, Distinct), bump(Owner, Owners)}.

bump(Key, Map) -> maps:update_with(Key, fun(N) -> N + 1 end, 1, Map).

%% Runs on the target node: call_time on every function of `Modules` for
%% every process, the same BIFs eprof is built on, for `Millis`. Own time
%% excludes time spent in other traced functions, so a module list that
%% covers a call path splits the path's time between its steps.
calls(Millis, Modules) ->
    [code:ensure_loaded(M) || M <- Modules],
    Patterns = [{M, '_', '_'} || M <- Modules],
    [erlang:trace_pattern(P, true, [local, call_time]) || P <- Patterns],
    erlang:trace(all, true, [call]),
    timer:sleep(Millis),
    erlang:trace(all, false, [call]),
    Rows = [{{M, F, A}, Count, Us}
            || M <- Modules, {F, A} <- M:module_info(functions),
               {call_time, Times} <- [erlang:trace_info({M, F, A}, call_time)],
               is_list(Times),
               {Count, Us} <- [lists:foldl(fun({_, C, S, U}, {C0, U0}) -> {C0 + C, U0 + S * 1000000 + U} end, {0, 0}, Times)],
               Count > 0],
    [erlang:trace_pattern(P, false, [local, call_time]) || P <- Patterns],
    lists:reverse(lists:keysort(3, Rows)).
