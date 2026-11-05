%% Fixed production polling calls against real memory/SQLite writers. Baseline
%% aliases and private exports exist only in this disposable, non-distributed VM.
-module(strand_poll_replay).
-export([main/1, get_register/3]).
-include("runtime@api_Runtime.hrl").
-include("runtime@supervisor_SessionTree.hrl").
-include("session@session_Session.hrl").
-include("storage@storage_Storage.hrl").

main([Baseline,Check]) ->
    try run(Baseline,Check), halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n",[C,R,S]), halt(1) end.

run(Baseline,Check) ->
    nonode@nohost=node(),
    OriginalRuntime=forms(filename:join(Baseline,"runtime@strand_runtime.beam")),
    CurrentRuntime=forms(code:which('runtime@strand_runtime')),
    %% Gleam's inferred type-variable names can change across builds. Compare
    %% every executable function AST, not BEAM bytes containing those specs.
    true=([F || F={function,_,_,_,_} <- OriginalRuntime]
        =:= [F || F={function,_,_,_,_} <- CurrentRuntime]),
    BaselineCodec = forms(filename:join(Baseline,"machine@codec.beam")),
    load(BaselineCodec,'machine@codec',strand_poll_codec_baseline,#{}),
    load(forms(code:which('machine@codec')),'machine@codec',strand_poll_codec_candidate,#{}),
    Runtime = forms(code:which('runtime@strand_runtime')),
    %% Baseline and candidate share the exact runtime logic. Only its codec
    %% module references differ, so neither side substitutes a model of polling.
    load(Runtime,'runtime@strand_runtime',strand_poll_baseline,
        #{'machine@codec'=>strand_poll_codec_baseline}),
    load(Runtime,'runtime@strand_runtime',strand_poll_candidate,
        #{'machine@codec'=>strand_poll_codec_candidate}),
    load(Runtime,'runtime@strand_runtime',strand_poll_reply_baseline,
        #{'machine@codec'=>strand_poll_codec_baseline,'runtime@writer'=>strand_poll_replay}),
    load(Runtime,'runtime@strand_runtime',strand_poll_reply_candidate,
        #{'machine@codec'=>strand_poll_codec_candidate,'runtime@writer'=>strand_poll_replay}),
    prepare_mutants(BaselineCodec,Runtime),
    io:format("VM otp=~s erts=~s word_bytes=~p schedulers=~p~n",
        [erlang:system_info(otp_release),erlang:system_info(version),
         erlang:system_info(wordsize),erlang:system_info(schedulers_online)]),
    lists:foreach(fun(Backend) ->
        lists:foreach(fun(Shape) -> fixture(Backend,Shape) end,[assistant,summary])
    end,[memory,sqlite]),
    case Check of
        "report" -> ok;
        "--expect-improved" -> check_improved()
    end.

forms(Path) ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}} =
        beam_lib:chunks(Path,[abstract_code]), Forms.

load(Forms,Old,New,Redirects) ->
    M = maps:put(Old,New,Redirects),
    Renamed = rewrite(Forms,M),
    Options=case Old of 'runtime@strand_runtime'->[binary,export_all]; _->[binary] end,
    {ok,New,Bin} = compile:forms(Renamed,Options),
    {module,New} = code:load_binary(New,"isolated poll replay",Bin).

rewrite({atom,L,A},M) -> {atom,L,maps:get(A,M,A)};
rewrite({attribute,L,module,A},M) -> {attribute,L,module,maps:get(A,M,A)};
rewrite(T,M) when is_tuple(T) -> list_to_tuple([rewrite(X,M) || X <- tuple_to_list(T)]);
rewrite(L,M) when is_list(L) -> [rewrite(X,M) || X <- L];
rewrite(X,_) -> X.

fixture(Backend,Shape) ->
    {Session,Retire} = open(Backend),
    try 'support@held_operation':run(Session,Shape,200,fun(Held) ->
        measure(Held,Backend,Shape)
    end)
    after {ok,nil}=Retire() end.

open(memory) ->
    {ok,{Session,Retire}} = 'session@session':open_memory_owned('core@clock':fixed(1000)),
    {Session,Retire};
open(sqlite) ->
    Path = filename:join(os:getenv("STRAND_POLL_RUN_DIR"),
        integer_to_list(erlang:unique_integer([positive])) ++ ".db"),
    ok=filelib:ensure_dir(Path),
    {ok,{Session,Retire}} = 'session@session':open_sqlite_owned(
        list_to_binary(Path),<<"poll-replay">>,600000,'core@clock':fixed(1000)),
    {Session,Retire}.

measure({held,Runtime,_}=Held,Backend,Shape) ->
    {answered,nil}='support@held_operation':wait_for_reads(Held,3),
    {ok,Subject}='runtime@supervisor':strand_subject(Runtime#runtime.tree,<<"main">>),
    {ok,Driver}='gleam@erlang@process':subject_owner(Subject),
    %% Suspension is confined to this synthetic fixture. It removes background
    %% timer polls while both versions replay an identical fixed number of calls.
    ok=sys:suspend(Driver),
    try
        State=sys:get_state(Driver),
        22=tuple_size(State),
        {some,Wait}=element(22,State),
        {ok,true}=strand_poll_baseline:poll_wait_unchanged(State,Wait),
        {ok,true}=strand_poll_candidate:poll_wait_unchanged(State,Wait),
        Inputs=register_inputs(State,Wait),
        semantic_replay(State,Wait,Inputs,Backend,Shape),
        pure_decoders(Inputs,Backend,Shape),
        lists:foreach(fun(Round) ->
            Modules=case Round rem 2 of
                1 -> [strand_poll_baseline,strand_poll_candidate];
                0 -> [strand_poll_candidate,strand_poll_baseline]
            end,
            lists:foreach(fun(M) -> trial(M,State,Wait,Backend,Shape,Round) end,Modules)
        end,lists:seq(1,8)),
        lists:foreach(fun(Round) ->
            Modules=case Round rem 2 of
                1 -> [strand_poll_baseline,strand_poll_candidate];
                0 -> [strand_poll_candidate,strand_poll_baseline]
            end,
            lists:foreach(fun(M) -> allocation(M,State,Wait,Backend,Shape,Round) end,Modules)
        end,lists:seq(1,4))
    after ok=sys:resume(Driver) end,
    nil.

trial(M,State,Wait,Backend,Shape,Round) ->
    Run=fun() -> {ok,true}=M:poll_wait_unchanged(State,Wait) end,
    repeat(30,Run),
    {Cpu0,_}=statistics(runtime),
    {Red0,_}=statistics(reductions),
    {Us,_}=timer:tc(fun() -> repeat(1000,Run) end),
    {Cpu1,_}=statistics(runtime),
    {Red1,_}=statistics(reductions),
    record({cpu,Backend,Shape,M},#{reductions=>Red1-Red0,us=>Us,cpu_ms=>Cpu1-Cpu0}),
    io:format("RESULT backend=~s shape=~s module=~s round=~p calls=1000 us=~p cpu_ms=~p reductions=~p~n",
        [Backend,Shape,M,Round,Us,Cpu1-Cpu0,Red1-Red0]).

allocation(M,State,Wait,Backend,Shape,Round) ->
    {ok,P}=tprof:start(#{type=>call_memory,session=>strand_poll_replay}),
    Words=try
        tprof:set_pattern(P,M,poll_wait_unchanged,2),
        tprof:enable_trace(P,self(),#{set_on_spawn=>false}),
        repeat(1000,fun() -> {ok,true}=M:poll_wait_unchanged(State,Wait) end),
        tprof:pause(P),
        #{all:={_,W,_}}=tprof:inspect(tprof:collect(P),total,{measurement,descending}),W
    after tprof:stop(P) end,
    record({words,Backend,Shape,M},Words),
    io:format("ALLOCATION backend=~s shape=~s module=~s round=~p calls=1000 words=~p bytes=~p~n",
        [Backend,Shape,M,Round,Words,Words*erlang:system_info(wordsize)]).

repeat(0,_) -> ok;
repeat(N,F) -> F(),repeat(N-1,F).

%% These values come from the actual writer before reply injection is used.
%% The timing path below still uses the real writer and storage actors.
register_inputs(State,Wait) ->
    Address=element(3,State),Strand=element(4,State),
    Op='core@ids':op_id_to_string(element(2,Wait)),
    [{Ns,Key,'runtime@writer':get_register(Address,Ns,Key)} ||
        {Ns,Key} <- [{strand_state,Strand},{op_state,Op},
                    {strand_config,Strand},{strand_leaf,Strand}]].

semantic_replay(State,Wait,Inputs,Backend,Shape) ->
    %% Each reply variation keeps its observed sequence, including malformed
    %% payloads. Comparing complete refusals catches a sequence-only shortcut.
    Cases=[Inputs]++lists:append([reply_variants(Inputs,I) || I <- lists:seq(1,4)]),
    Outcomes=[begin
        A=replay(strand_poll_reply_baseline,State,Wait,C),
        A=replay(strand_poll_reply_candidate,State,Wait,C),A
    end || C <- Cases],
    check_mutants(State,Wait,Cases,Outcomes,Backend,Shape),
    {{ok,true},ExpectedReads}=hd(Outcomes),
    ExpectedReads=[{Ns,Key} || {Ns,Key,_} <- Inputs],
    Digest=binary:encode_hex(crypto:hash(sha256,term_to_binary({Cases,Outcomes}))),
    io:format("EQUIVALENCE backend=~s shape=~s cases=~p digest=~s~n",
        [Backend,Shape,length(Cases),Digest]).

replay(M,State,Wait,Inputs) ->
    put(replay_address,element(3,State)),put(replay_replies,Inputs),put(replay_reads,[]),
    Result=M:poll_wait_unchanged(State,Wait),
    true=case Result of {ok,B} when is_boolean(B)->true; {error,S} when is_binary(S)->true; _->false end,
    {Result,lists:reverse(get(replay_reads))}.

get_register(Address,Ns,Key) ->
    Address=get(replay_address),
    put(replay_reads,[{Ns,Key}|get(replay_reads)]),
    [{_,_,Reply}]=[R || {N,K,_}=R <- get(replay_replies),N=:=Ns,K=:=Key],Reply.

reply_variants(Inputs,I) ->
    {Ns,Key,{ok,{some,{register,{register_value,Value},Seq}}}}=lists:nth(I,Inputs),
    Payloads=[replace_at(Inputs,I,{Ns,Key,{ok,{some,{register,{register_value,V},Seq}}}})
        || V <- variants(Value,2)],
    Missing=replace_at(Inputs,I,{Ns,Key,{ok,none}}),
    Unavailable=replace_at(Inputs,I,{Ns,Key,{error,unavailable}}),
    Moved=replace_at(Inputs,I,{Ns,Key,{ok,{some,{register,{register_value,Value},Seq+1}}}}),
    [Missing,Unavailable,Moved|Payloads].

replace_at(List,I,New) ->
    {Before,[_|After]}=lists:split(I-1,List),Before++[New|After].

variants(Value,Depth) ->
    Scalars=[null,{bool,true},{int,7},{float,1.5},{string,<<"junk">>},{array,[]},{object,[]}],
    case Value of
        {object,Fields} ->
            Changed=lists:append([begin
                {K,V}=lists:nth(I,Fields),
                Replacements=case Depth>0 of true->variants(V,Depth-1);false->Scalars end,
                [{object,replace_at(Fields,I,{K,X})} || X <- Replacements]
            end || I <- lists:seq(1,length(Fields))]),
            Duplicates=lists:append([[{object,[{K,null}|Fields]},
                {object,Fields++[{K,null}]}] || {K,_} <- Fields]),
            Missing=[{object,[P || {K,_}=P <- Fields,K=/=Key]} || {Key,_} <- Fields],
            [Value,{object,lists:reverse(Fields)},
                {object,[{<<"unknown">>,{array,[null]}}|Fields]}|Scalars++Changed++Duplicates++Missing];
        {array,Values} -> [Value,{array,lists:reverse(Values)}|Scalars];
        _ -> [Value|Scalars]
    end.

pure_decoders(Inputs,Backend,Shape) ->
    Decoders=[decode_strand_state,decode_state,decode_configuration],
    Values=[{F,V} || {F,{_,_,{ok,{some,{register,{register_value,V},_}}}}} <-
        lists:zip(Decoders,lists:sublist(Inputs,3))],
    CodecCases=[{F,X} || {F,V} <- Values,X <- variants(V,2)],
    CodecAnswers=[begin
        Expected=apply(strand_poll_codec_baseline,F,[V]),
        Expected=apply(strand_poll_codec_candidate,F,[V]),
        Expected=apply('machine@codec',F,[V]),Expected
    end || {F,V} <- CodecCases],
    CodecDigest=binary:encode_hex(crypto:hash(sha256,term_to_binary({CodecCases,CodecAnswers}))),
    io:format("CODEC_EQ backend=~s shape=~s cases=~p digest=~s~n",
        [Backend,Shape,length(CodecCases),CodecDigest]),
    lists:foreach(fun(Round) ->
        Modules=case Round rem 2 of 1->[strand_poll_codec_baseline,strand_poll_codec_candidate];
            0->[strand_poll_codec_candidate,strand_poll_codec_baseline] end,
        lists:foreach(fun(M) ->
            Run=fun()->lists:foreach(fun({F,V})->{ok,_}=apply(M,F,[V]) end,Values) end,
            repeat(100,Run),{Cpu0,_}=statistics(runtime),{Red0,_}=statistics(reductions),
            {Us,_}=timer:tc(fun()->repeat(10000,Run) end),
            {Cpu1,_}=statistics(runtime),{Red1,_}=statistics(reductions),
            io:format("DECODERS backend=~s shape=~s module=~s round=~p calls=30000 us=~p cpu_ms=~p reductions=~p~n",
                [Backend,Shape,M,Round,Us,Cpu1-Cpu0,Red1-Red0])
        end,Modules)
    end,lists:seq(1,8)).

%% Semantic mutants are compiled into new names in this fixture VM only.
%% A mutant is killed by a changed complete answer/read trace, never merely by
%% a compiler error, timeout or crashing test harness.
prepare_mutants(Codec,Runtime) ->
    Mutations=[
        {strand_poll_codec_last,strand_poll_reply_last,
         "get(Fields,Name) -> case lists:keyfind(Name,1,lists:reverse(Fields)) of false -> {error,nil}; {_,V} -> {ok,V} end."},
        {strand_poll_codec_first,strand_poll_reply_first,
         "get([{Name,V}|_],Name) -> {ok,V}; get(_,_) -> {error,nil}."},
        {strand_poll_codec_missing,strand_poll_reply_missing,
         "get(Fields,Name) -> case lists:keyfind(Name,1,Fields) of false -> {ok,null}; {_,V} -> {ok,V} end."}],
    lists:foreach(fun({C,R,Text}) ->
        load(replace_function(Codec,get,2,Text),'machine@codec',C,#{}),
        load(Runtime,'runtime@strand_runtime',R,
            #{'machine@codec'=>C,'runtime@writer'=>strand_poll_replay})
    end,Mutations),
    Shortcut=replace_function(Runtime,poll_wait_unchanged,2,
        "poll_wait_unchanged(_State,_Wait) -> {ok,true}."),
    load(Shortcut,'runtime@strand_runtime',strand_poll_reply_unchecked,
        #{'runtime@writer'=>strand_poll_replay}),
    put(replay_mutants,[R || {_,R,_} <- Mutations]++[strand_poll_reply_unchecked]).

replace_function(Forms,Name,Arity,Text) ->
    {ok,Tokens,_}=erl_scan:string(Text),
    {ok,Replacement}=erl_parse:parse_form(Tokens),
    [case F of {function,_,Name,Arity,_}->Replacement; _->F end || F <- Forms].

check_mutants(State,Wait,Cases,Expected,Backend,Shape) ->
    lists:foreach(fun(M) ->
        Different=[I || {C,E,I} <- lists:zip3(Cases,Expected,lists:seq(1,length(Cases))),
            replay(M,State,Wait,C)=/=E],
        case Different of
            [] -> erlang:error({mutant_survived,M,Backend,Shape});
            [First|_] -> io:format("MUTANT backend=~s shape=~s module=~s first_changed_case=~p~n",
                [Backend,Shape,M,First])
        end
    end,get(replay_mutants)).

record(Key,Value) ->
    Previous=case get(Key) of undefined->[]; L->L end,
    put(Key,[Value|Previous]),ok.

median(List) ->
    Sorted=lists:sort(List),N=length(Sorted),
    case N rem 2 of
        1 -> lists:nth((N+1) div 2,Sorted);
        0 -> (lists:nth(N div 2,Sorted)+lists:nth(N div 2+1,Sorted))/2
    end.

check_improved() ->
    lists:foreach(fun({Backend,Shape}) ->
        A=median([maps:get(reductions,R) || R <- get({cpu,Backend,Shape,strand_poll_baseline})]),
        B=median([maps:get(reductions,R) || R <- get({cpu,Backend,Shape,strand_poll_candidate})]),
        WA=median(get({words,Backend,Shape,strand_poll_baseline})),
        WB=median(get({words,Backend,Shape,strand_poll_candidate})),
        %% Work and allocation guards avoid turning host timing noise into a
        %% test deadline. Both must improve in every real backend/held shape.
        case B<A*0.98 andalso WB<WA*0.99 of
            true -> io:format("GUARD backend=~s shape=~s reductions_before=~p reductions_after=~p words_before=~p words_after=~p passed~n",
                [Backend,Shape,A,B,WA,WB]);
            false -> erlang:error({no_improvement,Backend,Shape,A,B,WA,WB})
        end
    end,[{B,S} || B <- [memory,sqlite],S <- [assistant,summary]]).
