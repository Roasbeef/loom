%% CPU and memory measurements of the terminal's tui:update/2.
%%
%% This module is diagnostic tooling, not part of the client. It drives the
%% built beams of one checkout, so two checkouts of different revisions can be
%% compared with the same driver; scripts/tui_perf.sh builds the command line.
%% The model it drives is built by packages/tui/dev/tui_perf_dev.gleam, which
%% the revisions under comparison must share, and the running jobs by
%% tui_perf_jobs_dev.gleam, which has to be written for each job API.
%%
%% Every scenario runs inside one spawned process, because the model's
%% subjects belong to the process that created them and update/2 reads their
%% mailboxes. Three counters are reported, and they answer different
%% questions:
%%
%% - Reductions, from process_info/2. Deterministic for one revision and
%%   input, so a difference of a few hundred is real. Collections are charged
%%   in reductions too, so allocation shows up here indirectly.
%% - Words allocated, from tprof's call_memory trace over every loaded
%%   function. Also deterministic, and it survives collections, which a heap
%%   size delta does not. Tracing is slow, so it is a separate pass from the
%%   timed one.
%% - Wall time. The only counter the machine's load moves; interleave
%%   revisions and compare medians.
%%
%% The presentation clock is pinned (tui_perf_dev reads it from the process
%% dictionary) and moved 50 ms per tick. Frame pacing, cache refreshes and
%% animation read that clock, so on a real clock one sample of an event can
%% include a transcript projection and the next not. The replay scenario is
%% the exception: it runs on the host clock, as the shipped loop does, and so
%% its reductions move with its wall time.
-module(tui_perf).
-export([main/1]).

-define(OP, <<"01a06bac-b337-71de-b737-9b0a7f9ffbe9">>).

%% TUI_PERF_MIN_HEAP sets the scenario process's minimum heap, in words. A
%% replay keeps every frame it draws until it returns, so a long one spends
%% most of its time collecting that list; a heap large enough to hold it
%% separates what the terminal costs from what the harness retains.
main([Label, Scenario | Args]) ->
    Parent = self(),
    Heap = case os:getenv("TUI_PERF_MIN_HEAP") of
               false -> [];
               Words -> [{min_heap_size, list_to_integer(Words)},
                         {min_bin_vheap_size, list_to_integer(Words)}]
           end,
    {Pid, Ref} = spawn_opt(
        fun() ->
            put(tui_perf_now, 1000000),
            Parent ! {self(), done, run(Scenario, Args, Label)}
        end,
        [monitor | Heap]
    ),
    receive
        {Pid, done, _} -> erlang:halt(0, [{flush, true}]);
        {'DOWN', Ref, process, Pid, Reason} ->
            io:format("FAILED ~p~n", [Reason]),
            erlang:halt(1, [{flush, true}])
    end.

%% --- scenarios --------------------------------------------------------------

%% One keypress, one idle tick, and a tick and a keypress with 64 frames
%% waiting, each applied to the same ready model, so every sample of one
%% event does the same work.
run("events", [], Label) ->
    {Inbox, M} = ready(),
    Nothing = fun() -> ok end,
    Fill = fun() -> drain_mailbox(), fill(Inbox, 64) end,
    Events = [{"key", Nothing, {key_press, <<"j">>}},
              {"tick0", Nothing, tick},
              {"tick64", Fill, tick},
              {"key64", Fill, {key_press, <<"j">>}}],
    _ = samples(20, Nothing, fun() -> tui:update(tick, M) end),
    [report(Label, Name, samples(200, Prepare, fun() -> tui:update(E, M) end))
     || {Name, Prepare, E} <- Events],
    trace_words(),
    [report_words(Label, Name, Prepare, fun() -> tui:update(E, M) end)
     || {Name, Prepare, E} <- Events],
    ok;

%% A burst of streamed frames, drained tick by tick, reported per frame.
run("burst", [SizeS], Label) ->
    Size = list_to_integer(SizeS),
    {Inbox, M0} = ready(),
    Start = get(tui_perf_now),
    fill(Inbox, Size),
    {Ticks, R, T} = burst(M0, 0, 0, 0),
    put(tui_perf_now, Start),
    trace_words(),
    fill(Inbox, Size),
    {_, W, _} = words(fun() -> burst(M0, 0, 0, 0) end),
    io:format("RESULT ~s burst~p ticks=~p reductions_per_frame=~.1f "
              "ns_per_frame=~.1f words_per_frame=~.1f~n",
              [Label, Size, Ticks, R / Size, T / Size, W / Size]);

%% How a frame's cost moves as one reply grows: the reply streams 64 frames
%% per tick up to N, and the tick that takes frames K-63..K is reported per
%% frame for each power of two K from 64 up. A second, traced pass repeats
%% the same ticks on the same pinned clock and reports their words, since
%% the trace would slow the timed pass. TUI_PERF_BATCH=1 streams one frame
%% per tick, as a replay does, so every frame pays for a projection.
run("growth", [SizeS], Label) ->
    Size = list_to_integer(SizeS),
    Batch = batch(),
    {Inbox, M0} = ready(),
    Start = get(tui_perf_now),
    Timed = growth(Inbox, M0, 1, Size, Batch, fun(F) -> sample(F) end, []),
    put(tui_perf_now, Start),
    trace_words(),
    Traced = growth(Inbox, M0, 1, Size, Batch, fun(F) -> words(F) end, []),
    [io:format("RESULT ~s growth frame=~p reductions_per_frame=~.1f "
               "ns_per_frame=~.1f words_per_frame=~.1f~n",
               [Label, K, R / Batch, T / Batch, W / Batch])
     || {{K, R, T}, {K, W, _}} <- lists:zip(Timed, Traced)],
    ok;

%% Where one tick's calls go, by function, after N frames of one reply have
%% already been drawn: the 64 frames that follow are the measured tick.
%% TUI_PERF_TYPE picks the tprof counter: call_count (the default),
%% call_time or call_memory.
run("profile_at", [SizeS], Label) ->
    Size = list_to_integer(SizeS),
    {Inbox, M0} = ready(),
    M1 = stream_drawn(Inbox, M0, 1, Size),
    Type = list_to_atom(os:getenv("TUI_PERF_TYPE", "call_count")),
    {ok, _} = tprof:start(#{type => Type}),
    _ = tprof:set_pattern('_', '_', '_'),
    advance(),
    [send(Inbox, delta(I)) || I <- lists:seq(Size + 1, Size + batch())],
    tprof:restart(),
    tprof:enable_trace(self()),
    _ = tui:update(tick, M1),
    tprof:disable_trace(self()),
    {Type, Rows} = tprof:collect(),
    Flat = lists:reverse(lists:keysort(3,
        [{io_lib:format("~s:~s/~p", [Mo, Fu, Ar]), C, V}
         || {Mo, Fu, Ar, PerPid} <- Rows, {_, C, V} <- PerPid])),
    io:format("PROFILE ~s ~s at=~p~n", [Label, Type, Size]),
    Top = list_to_integer(os:getenv("TUI_PERF_TOP", "30")),
    [io:format("  ~10w ~8w calls  ~s~n", [V, C, N])
     || {N, C, V} <- lists:sublist(Flat, Top)],
    ok;

%% A socket backlog left in the mailbox while zero or three jobs run: the
%% cost of every selective receive that scans the backlog and matches
%% nothing. The mailbox is topped back up to the backlog before each sample.
%% The posture is the replay's unless the last argument is `live`, which
%% measures a terminal that is not replaying.
run("backlog", [SizeS, JobsS], Label) ->
    run("backlog", [SizeS, JobsS, "replaying"], Label);
run("backlog", [SizeS, JobsS, Posture], Label) ->
    Size = list_to_integer(SizeS),
    {Inbox, M0} = ready(),
    M1 = case Posture of
             "live" -> tui_perf_dev:live(M0);
             "replaying" -> M0
         end,
    M = case JobsS of
            "3" -> tui_perf_jobs_dev:with_jobs(M1);
            "0" -> M1
        end,
    Fill = fun() ->
        {message_queue_len, Q} = process_info(self(), message_queue_len),
        fill(Inbox, Size - Q)
    end,
    Name = fun(E) ->
        io_lib:format("~s_backlog~p_jobs~s_~s", [E, Size, JobsS, Posture])
    end,
    report(Label, Name("key"), samples(40, Fill,
        fun() -> tui:update({key_press, <<"j">>}, M) end)),
    report(Label, Name("tick"), samples(40, Fill,
        fun() -> tui:update(tick, M) end));

%% A long streamed reply, then the frames that close it: what the process
%% holds, before and after a full collection, and the model's own size.
run("session", [SizeS], Label) ->
    Size = list_to_integer(SizeS),
    {Inbox, M0} = ready(),
    M1 = stream(Inbox, M0, 1, Size),
    census(Label, "streamed", M1),
    [send(Inbox, F) || F <- closing()],
    M2 = settle(M1),
    census(Label, "closed", M2);

%% The recording with its one reply delta replaced by N, replayed through the
%% virtual terminal on the host clock: every scripted frame is one update and
%% one draw. The witness is the retained record count and the failure lines,
%% since a replay whose frames were all refused also finishes.
run("replay", [SizeS], Label) ->
    Size = list_to_integer(SizeS),
    Path = synthesize(Size),
    {Inbox, M0} = tui_perf_dev:replay_model(),
    {ok, Moments} = 'tui@recording':decode_file(list_to_binary(Path)),
    Steps = 'tui@recording':to_steps(Moments),
    Script = 'tui@virtual_backend':script({terminal_size, 160, 48}, Steps, Inbox),
    {GcCount0, GcWords0, _} = erlang:statistics(garbage_collection),
    R0 = reds(),
    {T, {ok, {run, Final, Frames}}} =
        timer:tc(fun() -> tui:run_script(M0, Script) end),
    R1 = reds(),
    {GcCount1, GcWords1, _} = erlang:statistics(garbage_collection),
    case os:getenv("TUI_PERF_SIZES") of
        false -> ok;
        _ -> io:format("SIZES frames_words=~p final_words=~p memory=~p~n",
                       [erts_debug:size(Frames), erts_debug:size(Final),
                        element(2, process_info(self(), memory))])
    end,
    Rect = 'etui@geometry':rect_new(0, 0, 160, 48),
    Views = [element(1, timer:tc(fun() -> 'tui@render':view(Final, Rect) end))
             || _ <- lists:seq(1, 40)],
    {Records, Failures} = tui_perf_dev:witness(Final),
    io:format("RESULT ~s replay~p us=~p reductions=~p frames=~p "
              "view_us_median=~p records=~p failures=~p gcs=~p "
              "gc_words_reclaimed=~p~n",
              [Label, Size, T, R1 - R0, length(Frames),
               pct(lists:sort(Views), 0.5), Records, Failures,
               GcCount1 - GcCount0, GcWords1 - GcWords0]);

%% The committed recording replayed as it stands, then the memory the
%% process retains holding the final model: the census after a full
%% collection, with the drawn frames already dropped.
run("replay_census", [], Label) ->
    {Inbox, M0} = tui_perf_dev:replay_model(),
    Path = filename:join(recordings(), "gemini-flash-reply.jsonl"),
    {ok, Moments} = 'tui@recording':decode_file(list_to_binary(Path)),
    Steps = 'tui@recording':to_steps(Moments),
    Script = 'tui@virtual_backend':script({terminal_size, 160, 48}, Steps, Inbox),
    {ok, {run, Final, _}} = tui:run_script(M0, Script),
    census(Label, "replayed", Final);

%% Where a replay's calls go, by function (TUI_PERF_TYPE as for profile_at).
%% The trace slows the replay, and the replay paces frames on the host
%% clock, so the counts describe a slower run than the timed one.
run("replay_profile", [SizeS], Label) ->
    Size = list_to_integer(SizeS),
    Path = synthesize(Size),
    {Inbox, M0} = tui_perf_dev:replay_model(),
    {ok, Moments} = 'tui@recording':decode_file(list_to_binary(Path)),
    Steps = 'tui@recording':to_steps(Moments),
    Script = 'tui@virtual_backend':script({terminal_size, 160, 48}, Steps, Inbox),
    Type = list_to_atom(os:getenv("TUI_PERF_TYPE", "call_count")),
    {ok, _} = tprof:start(#{type => Type}),
    _ = tprof:set_pattern('_', '_', '_'),
    tprof:restart(),
    tprof:enable_trace(self()),
    {ok, _} = tui:run_script(M0, Script),
    tprof:disable_trace(self()),
    {Type, Rows} = tprof:collect(),
    Flat = lists:reverse(lists:keysort(3,
        [{io_lib:format("~s:~s/~p", [Mo, Fu, Ar]), C, V}
         || {Mo, Fu, Ar, PerPid} <- Rows, {_, C, V} <- PerPid])),
    io:format("PROFILE ~s ~s replay=~p~n", [Label, Type, Size]),
    Top = list_to_integer(os:getenv("TUI_PERF_TOP", "30")),
    [io:format("  ~10w ~8w calls  ~s~n", [V, C, N])
     || {N, C, V} <- lists:sublist(Flat, Top)],
    ok;

%% Where one event's words go, by function: tick or key, with 64 frames
%% waiting. Diff two revisions' outputs to attribute a change.
run("profile", [Kind], Label) ->
    {Inbox, M} = ready(),
    Fill = fun() -> drain_mailbox(), fill(Inbox, 64) end,
    Event = case Kind of "key" -> {key_press, <<"j">>}; "tick" -> tick end,
    Fill(),
    _ = tui:update(Event, M),
    trace_words(),
    Fill(),
    {_, Total, Rows} = words(fun() -> tui:update(Event, M) end),
    Flat = lists:reverse(lists:keysort(3,
        [{io_lib:format("~s:~s/~p", [Mo, Fu, Ar]), C, W}
         || {Mo, Fu, Ar, PerPid} <- Rows, {_, C, W} <- PerPid])),
    io:format("PROFILE ~s ~s total_words=~p~n", [Label, Kind, Total]),
    Top = list_to_integer(os:getenv("TUI_PERF_TOP", "30")),
    [io:format("  ~8w words ~6w calls  ~s~n", [W, C, N])
     || {N, C, W} <- lists:sublist(Flat, Top)],
    ok.

%% --- the model --------------------------------------------------------------

%% A model that has taken the recording's snapshots and is in the assistant
%% phase, with nothing left in its mailbox or its inbox buffer, and the clock
%% one tick past its last event.
ready() ->
    {Inbox, M0} = tui_perf_dev:bench_model(),
    M1 = tui:update({resize, 133, 40}, M0),
    [send(Inbox, F) || F <- preamble()],
    M2 = settle(M1),
    advance(),
    {Inbox, M2}.

%% Ticks until the mailbox has stayed empty for eight ticks, which also
%% empties whatever an inbox buffer held.
settle(M) -> settle(M, 8).
settle(M, 0) -> M;
settle(M, K) ->
    advance(),
    M2 = tui:update(tick, M),
    case process_info(self(), message_queue_len) of
        {message_queue_len, 0} -> settle(M2, K - 1);
        _ -> settle(M2, 8)
    end.

burst(M, Ticks, R, T) ->
    {message_queue_len, Q} = process_info(self(), message_queue_len),
    case Q =:= 0 andalso Ticks > 0 of

        %% Two more ticks take what an inbox buffer still holds.
        true ->
            {M2, R2, T2} = timed_tick(M, R, T),
            {_, R3, T3} = timed_tick(M2, R2, T2),
            {Ticks + 2, R3, T3};
        false ->
            {M2, R2, T2} = timed_tick(M, R, T),
            burst(M2, Ticks + 1, R2, T2)
    end.

timed_tick(M, R, T) ->
    advance(),
    R0 = reds(),
    T0 = erlang:monotonic_time(nanosecond),
    M2 = tui:update(tick, M),
    T1 = erlang:monotonic_time(nanosecond),
    {M2, R + reds() - R0, T + T1 - T0}.

stream(_Inbox, M, From, Size) when From > Size -> settle(M);
stream(Inbox, M, From, Size) ->
    advance(),
    To = min(Size, From + 63),
    [send(Inbox, delta(I)) || I <- lists:seq(From, To)],
    stream(Inbox, tui:update(tick, M), To + 1, Size).

%% Streams frames From..Size, 64 per tick, without settling, so the reply
%% stays open and every tick draws.
stream_drawn(_Inbox, M, From, Size) when From > Size -> M;
stream_drawn(Inbox, M, From, Size) ->
    advance(),
    To = min(Size, From + 63),
    [send(Inbox, delta(I)) || I <- lists:seq(From, To)],
    stream_drawn(Inbox, tui:update(tick, M), To + 1, Size).

%% The growth scenario's ticks of Batch frames, each measured by Measure,
%% which returns {Result, Counter, Other}. A tick whose last frame is a power
%% of two is recorded as {Frame, Counter, Other}.
growth(_Inbox, _M, From, Size, _Batch, _Measure, Acc) when From > Size ->
    lists:reverse(Acc);
growth(Inbox, M, From, Size, Batch, Measure, Acc) ->
    advance(),
    To = From + Batch - 1,
    [send(Inbox, delta(I)) || I <- lists:seq(From, To)],
    {M2, A, B} = Measure(fun() -> tui:update(tick, M) end),
    Acc2 = case To band (To - 1) of
               0 -> [{To, A, B} | Acc];
               _ -> Acc
           end,
    growth(Inbox, M2, To + 1, Size, Batch, Measure, Acc2).

%% Frames per tick for growth and profile_at: 64, what update_tick drains,
%% unless TUI_PERF_BATCH says otherwise.
batch() -> list_to_integer(os:getenv("TUI_PERF_BATCH", "64")).

%% Moves the pinned presentation clock on by one 50 ms tick.
advance() -> put(tui_perf_now, get(tui_perf_now) + 50).

%% --- frames -----------------------------------------------------------------

recordings() ->
    filename:join(os:getenv("TUI_PERF_TUI"), "test/recordings").

gemini() ->
    File = filename:join(recordings(), "gemini-flash-reply.jsonl"),
    {ok, Bin} = file:read_file(File),
    [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>].

%% The frames before the reply streams: the snapshots, the user's entry and
%% the operation's transitions up to the assistant phase.
preamble() ->
    {Before, _} = lists:splitwith(fun(L) -> not is_delta(L) end, gemini()),
    frames(Before).

%% The frames that close the reply: its entry, usage and the done phases.
closing() ->
    {_, [_Delta | After]} =
        lists:splitwith(fun(L) -> not is_delta(L) end, gemini()),
    frames(After).

frames(Lines) ->
    [message(M) || M <- [json:decode(L) || L <- Lines], is_frame(M)].

is_delta(Line) -> binary:match(Line, <<"stream_delta">>) =/= nomatch.

is_frame(#{<<"t">> := <<"incoming">>}) -> true;
is_frame(#{<<"t">> := <<"connected">>}) -> true;
is_frame(_) -> false.

message(#{<<"t">> := <<"connected">>}) -> connected;
message(#{<<"t">> := <<"incoming">>, <<"text">> := T}) -> {incoming, T}.

%% One streamed word of the reply, a line break every twelfth. The reply is
%% one long paragraph, which is the worst case for the live tail: a block
%% that never closes is parsed on every frame. TUI_PERF_SHAPE=paragraphs
%% makes every break a blank line instead, so the reply is many short
%% paragraphs, which is how most answers are written. TUI_PERF_SHAPE=markdown
%% writes half the words as bold, code or a link, and opens a new paragraph
%% as a list item every 48 words, so the Markdown parser does real work on
%% every frame and the live tail cannot take its plain-text checkpoint.
delta_text(N) ->
    Shape = os:getenv("TUI_PERF_SHAPE"),
    Break = case {N rem 12, N rem 48, Shape} of
                {11, 47, "markdown"} -> "\n\n- ";
                {11, _, "paragraphs"} -> "\n\n";
                {11, _, _} -> "\n";
                _ -> ""
            end,
    I = integer_to_list(N),
    Word = case {Shape, N rem 6} of
               {"markdown", 1} -> ["**word", I, "**"];
               {"markdown", 3} -> ["`word", I, "`"];
               {"markdown", 5} -> ["[word", I, "](https://x.test/", I, ")"];
               _ -> ["word", I]
           end,
    iolist_to_binary(json:encode(#{
        <<"v">> => 1, <<"event">> => <<"stream_delta">>,
        <<"body">> => #{<<"strand">> => <<"main">>, <<"op">> => ?OP,
                        <<"ephemeral">> => true, <<"kind">> => <<"text">>,
                        <<"text">> => iolist_to_binary([Word, " ", Break])}})).

delta(N) -> {incoming, delta_text(N)}.

fill(Inbox, Count) -> [send(Inbox, delta(I)) || I <- lists:seq(1, Count)].

%% A gleam_erlang subject is {subject, Owner, Tag}; its messages are
%% {Tag, Message}.
send({subject, Pid, Tag}, Message) -> Pid ! {Tag, Message}.

drain_mailbox() -> receive _ -> drain_mailbox() after 0 -> ok end.

%% Writes the recording with its delta replaced by Size deltas, one
%% millisecond apart, under the checkout's build directory.
synthesize(Size) ->
    Out = filename:join([os:getenv("TUI_PERF_TUI"), "build", "tui_perf",
                         "replay" ++ integer_to_list(Size) ++ ".jsonl"]),
    Lines = lists:flatmap(
        fun(L) ->
            case is_delta(L) of
                false -> [L];
                true ->
                    #{<<"at">> := At} = json:decode(L),
                    [json:encode(#{<<"at">> => At + I, <<"t">> => <<"incoming">>,
                                   <<"text">> => delta_text(I)})
                     || I <- lists:seq(0, Size - 1)]
            end
        end, gemini()),
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, lists:join(<<"\n">>, Lines) ++ [<<"\n">>]),
    Out.

%% --- measurement ------------------------------------------------------------

reds() -> element(2, process_info(self(), reductions)).

%% One sample of F after a full collection: {Result, Reductions, Nanoseconds}.
sample(F) ->
    erlang:garbage_collect(),
    R0 = reds(),
    T0 = erlang:monotonic_time(nanosecond),
    Res = F(),
    T1 = erlang:monotonic_time(nanosecond),
    R1 = reds(),
    {Res, R1 - R0, T1 - T0}.

samples(N, Prepare, F) ->
    [begin Prepare(), {_, R, T} = sample(F), {R, T} end
     || _ <- lists:seq(1, N)].

%% Starts a call_memory trace over every function loaded so far. Every
%% scenario has already run the events it measures, so the modules they
%% need are loaded.
trace_words() ->
    {ok, _} = tprof:start(#{type => call_memory}),
    _ = tprof:set_pattern('_', '_', '_'),
    ok.

%% Words F allocates in this process: {Result, Total, PerFunctionRows}.
words(F) ->
    tprof:restart(),
    tprof:enable_trace(self()),
    Res = F(),
    tprof:disable_trace(self()),
    {call_memory, Rows} = tprof:collect(),
    tprof:restart(),
    {Res, lists:sum([W || {_, _, _, PerPid} <- Rows, {_, _, W} <- PerPid]), Rows}.

pct(Sorted, P) ->
    Len = length(Sorted),
    lists:nth(max(1, min(Len, round(P * Len + 0.5))), Sorted).

report(Label, Name, Samples) ->
    [begin
         S = lists:sort([element(I, X) || X <- Samples]),
         io:format("RESULT ~s ~s ~s median=~p p10=~p p90=~p n=~p~n",
                   [Label, Name, Metric, pct(S, 0.5), pct(S, 0.1),
                    pct(S, 0.9), length(S)])
     end || {I, Metric} <- [{1, "reductions"}, {2, "ns"}]],
    ok.

%% Three traced samples; the first can differ while the trace warms.
report_words(Label, Name, Prepare, F) ->
    Ws = [begin Prepare(), element(2, words(F)) end || _ <- lists:seq(1, 3)],
    io:format("RESULT ~s ~s words ~w~n", [Label, Name, Ws]).

census(Label, Stage, Model) ->
    Info = fun() ->
        [{memory, Mem}, {total_heap_size, THS}, {heap_size, HS},
         {message_queue_len, Q}] =
            process_info(self(), [memory, total_heap_size, heap_size,
                                  message_queue_len]),
        {Mem, THS, HS, Q}
    end,
    {Mem0, THS0, HS0, Q0} = Info(),
    erlang:garbage_collect(),
    {Mem1, THS1, HS1, Q1} = Info(),
    %% Refc binary bytes the process references after the collection, each
    %% binary counted once: what stream_bounds_test holds to its ceiling.
    {binary, Bins} = process_info(self(), binary),
    io:format("RESULT ~s ~s memory=~p total_heap=~p heap=~p mq=~p "
              "gc_memory=~p gc_total_heap=~p gc_heap=~p gc_mq=~p "
              "model_size=~p model_flat=~p gc_binary_bytes=~p~n",
              [Label, Stage, Mem0, THS0, HS0, Q0, Mem1, THS1, HS1, Q1,
               erts_debug:size(Model), erts_debug:flat_size(Model),
               lists:sum([S || {_, S, _} <- lists:ukeysort(1, Bins)])]).
