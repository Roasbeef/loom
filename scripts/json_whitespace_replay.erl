%% Only this disposable VM loads the aliases and deliberate semantic mutants.
%% Both parsers use identical compilation options and the same immutable inputs.
-module(json_whitespace_replay).
-export([main/1]).

main([Baseline, Check]) ->
    try run(Baseline, Check), halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n",[C,R,S]), halt(1) end.

run(Baseline, Check) ->
    nonode@nohost = node(),
    Base = forms(Baseline),
    Candidate = forms(code:which('core@json')),
    true = lists:sort([{N,A} || {function,_,N,A,_} <- Base]) =:=
        lists:sort([{N,A} || {function,_,N,A,_} <- Candidate]),
    %% A no-op control legitimately has no changed functions.
    NormalizedBase = [erl_parse:map_anno(fun(_)->0 end,F) || F={function,_,_,_,_} <- Base],
    Changed = [N || {function,_,N,_,_}=F <- Candidate,
        not lists:member(erl_parse:map_anno(fun(_)->0 end,F), NormalizedBase)],
    true = lists:all(fun(N) -> N =:= skip_whitespace end, Changed),
    load(Base, whitespace_baseline),
    load(Candidate, whitespace_candidate),
    %% Reuse the existing raw UTF-8/truncation/depth/duplicate corpus. Exporting
    %% this fixture's private oracle never exports a production parser helper.
    Harness = rewrite(forms(code:which(json_decode_perf)),
        #{json_decode_perf=>whitespace_corpus, json_decode_baseline=>whitespace_baseline,
          'core@json'=>whitespace_candidate}),
    compile_load(Harness, whitespace_corpus, [binary,export_all]),
    whitespace_corpus:compare_results(),
    whitespace_corpus:compare_ownership(),
    Inputs = corpus(),
    lists:foreach(fun(Input) ->
        Expected = whitespace_baseline:parse(Input),
        Expected = whitespace_candidate:parse(Input),
        Expected = 'core@json':parse(Input)
    end, Inputs),
    io:format("WHITESPACE_EQUIVALENCE cases=~p sha256=~s~n",[length(Inputs),
        binary:encode_hex(crypto:hash(sha256,term_to_binary(Inputs)),lowercase)]),
    mutants(Candidate, Inputs),
    io:format("VM otp=~s erts=~s schedulers=~p word_bytes=~p baseline_sha256=~s~n",
        [erlang:system_info(otp_release),erlang:system_info(version),
         erlang:system_info(schedulers_online),erlang:system_info(wordsize),
         binary:encode_hex(crypto:hash(sha256,element(2,file:read_file(Baseline))),lowercase)]),
    lists:foreach(fun({Name, Input}) -> measure(Name, Input, Check) end, fixtures()).

forms(Path) ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Path,[abstract_code]),
    Forms.

load(Forms, Name) ->
    compile_load(rewrite(Forms, #{'core@json'=>Name}), Name, [binary]).

compile_load(Forms, Name, Options) ->
    {ok,Name,Binary}=compile:forms(Forms,Options),
    {module,Name}=code:load_binary(Name,"isolated whitespace replay",Binary).

rewrite({attribute,L,module,A}, M) -> {attribute,L,module,maps:get(A,M,A)};
rewrite({atom,L,A}, M) -> {atom,L,maps:get(A,M,A)};
rewrite(T,M) when is_tuple(T) -> list_to_tuple([rewrite(X,M) || X <- tuple_to_list(T)]);
rewrite(L,M) when is_list(L) -> [rewrite(X,M) || X <- L];
rewrite(X,_) -> X.

%% Exercise each legal byte and every one-byte substitute at document, array,
%% object, colon, comma and closing-token boundaries. Invalid UTF-8 is deliberate
%% input below Gleam's String type, and complete refusals are compared too.
corpus() ->
    Gaps = [<<>>,<<32>>,<<9>>,<<10>>,<<13>>,<<32,9,10,13>>,
        binary:copy(<<32,9,10,13>>,256)] ++ [<<B>> || B <- lists:seq(0,255)],
    lists:flatmap(fun(G) ->
        [<<G/binary,"null",G/binary>>, <<"[",G/binary,"1",G/binary,"]">>,
         <<"{",G/binary,"\"k\"",G/binary,":",G/binary,"1",G/binary,"}">>,
         <<"[1,",G/binary,"true]">>, <<"{\"k\":1,",G/binary,"\"v\":2}">>,
         <<G/binary>>, <<G/binary,"?">>, <<"[\"",195,169,"\",",G/binary,"?]">>,
         <<"null",G/binary,"?">>, <<"\"",G/binary,"\"">>]
    end,Gaps).

mutants(Forms, Inputs) ->
    {function,L,skip_whitespace,A,[{clause,CL,Args,Guards,[{'case',CaseL,Subject,Clauses}]}]} =
        lists:keyfind(skip_whitespace,3,[F || F={function,_,_,_,_} <- Forms]),
    %% Literal alternatives lower to one Erlang clause per permitted byte.
    [Space,Tab,LF,CR,Fallback] = Clauses,
    VT = replace_byte(Space,32,11),
    WrongOffset = rewrite_integer({function,L,skip_whitespace,A,
        [{clause,CL,Args,Guards,[{'case',CaseL,Subject,Clauses}]}]},1,0),
    Variants = [{omitted_tab, {function,L,skip_whitespace,A,[{clause,CL,Args,Guards,
                    [{'case',CaseL,Subject,[Space,LF,CR,Fallback]}]}]}},
                {accepted_vertical_tab,{function,L,skip_whitespace,A,[{clause,CL,Args,Guards,
                    [{'case',CaseL,Subject,[VT,Space,Tab,LF,CR,Fallback]}]}]}},
                {wrong_source_offset,WrongOffset}],
    lists:foreach(fun({Name, Function}) ->
        Mutated = [case F of {function,_,skip_whitespace,_,_} -> Function; _ -> F end || F <- Forms],
        load(Mutated, whitespace_mutant),
        Witnesses = [I || I <- Inputs,
            whitespace_baseline:parse(I) =/= whitespace_mutant:parse(I)],
        true = Witnesses =/= [],
        %% Parsing an exception would abort, rather than count as a killed mutant.
        io:format("MUTANT name=~s rejected=~p witness_hex=~s~n",[Name,length(Witnesses),
            binary:encode_hex(hd(Witnesses),lowercase)]),
        true=code:delete(whitespace_mutant),
        _=code:purge(whitespace_mutant)
    end, Variants).

replace_byte({integer,L,Old},Old,New) -> {integer,L,New};
replace_byte(T,O,N) when is_tuple(T) -> list_to_tuple([replace_byte(X,O,N) || X <- tuple_to_list(T)]);
replace_byte(L,O,N) when is_list(L) -> [replace_byte(X,O,N) || X <- L];
replace_byte(X,_,_) -> X.

rewrite_integer(T,Old,New) -> replace_byte(T,Old,New).

fixtures() ->
    Register = <<"{\"kind\":\"json\",\"payload\":{\"model\":{\"provider\":\"acme\",\"modelId\":\"fixture\"},\"thinkingLevel\":\"off\",\"activeToolNames\":[\"bash\",\"fs_read\",\"code_mode\"]}}">>,
    Delta = <<"{\"v\":2,\"event\":\"stream_delta\",\"body\":{\"strand\":\"main\",\"op\":\"fixture-operation\",\"kind\":\"text\",\"text\":\"hello world\"}}">>,
    Array = <<"[1,true,null,\"text\",{\"k\":2},3,4,5,6,7,8,9]">>,
    Pretty = <<32,9,10,13,"[",32,9,"1,",10,13,"true,",32,9,"null",10,13,"]",32,9,10,13>>,
    Long = <<"{\"text\":\"",(binary:copy(<<"ordinary text ">>,8192))/binary,"\"}">>,
    [{register,Register},{delta,Delta},{array,Array},{whitespace,Pretty},{long_text,Long}].

measure(Name,Input,Check) ->
    Expected=whitespace_baseline:parse(Input),
    Expected=whitespace_candidate:parse(Input),
    N=case Name of long_text->100; _->20000 end,
    lists:foreach(fun(Round) ->
        Order=case Round rem 2 of 1->[whitespace_baseline,whitespace_candidate];
                                  0->[whitespace_candidate,whitespace_baseline] end,
        lists:foreach(fun(M) ->
            repeat(10,fun()->M:parse(Input) end),
            {reductions,R0}=process_info(self(),reductions),{C0,_}=statistics(runtime),
            {Us,_}=timer:tc(fun()->repeat(N,fun()->M:parse(Input) end) end),
            {C1,_}=statistics(runtime),{reductions,R1}=process_info(self(),reductions),
            record({Name,M,reductions},R1-R0),
            io:format("TIME shape=~s module=~s round=~p calls=~p us=~p cpu_ms=~p reductions=~p~n",
                [Name,M,Round,N,Us,C1-C0,R1-R0])
        end,Order)
    end,lists:seq(1,8)),
    lists:foreach(fun(Round) ->
        Order=case Round rem 2 of 1->[whitespace_baseline,whitespace_candidate];
                                  0->[whitespace_candidate,whitespace_baseline] end,
        lists:foreach(fun(M) ->
            {ok,P}=tprof:start(#{type=>call_memory,session=>json_whitespace_replay}),
            Words=try
                tprof:set_pattern(P,M,parse,1),
                tprof:enable_trace(P,self(),#{set_on_spawn=>false}),
                repeat(N,fun()->M:parse(Input) end),tprof:pause(P),
                #{all:={_,W,_}}=tprof:inspect(tprof:collect(P),total,{measurement,descending}),W
            after tprof:stop(P) end,
            record({Name,M,words},Words),
            io:format("ALLOCATION shape=~s module=~s round=~p calls=~p words=~p~n",[Name,M,Round,N,Words])
        end,Order)
    end,lists:seq(1,4)),
    B=median(get({Name,whitespace_baseline,words})),
    C=median(get({Name,whitespace_candidate,words})),
    BR=median(get({Name,whitespace_baseline,reductions})),
    CR=median(get({Name,whitespace_candidate,reductions})),
    case Check of
        "--expect-improved" when Name =/= long_text ->
            case C*100 =< B*97 andalso CR*100 =< BR*102 of
                true->ok;false->error({no_improvement,Name,B,C,BR,CR}) end;
        "--expect-improved" -> true = C =< B;
        "report" -> ok
    end,
    io:format("MEDIAN shape=~s baseline_words=~p candidate_words=~p baseline_reductions=~p candidate_reductions=~p~n",[Name,B,C,BR,CR]).

record(Key,Value) -> put(Key,[Value|case get(Key) of undefined->[];Vs->Vs end]).
median(Vs) -> S=lists:sort(Vs),N=length(S),(lists:nth(N div 2,S)+lists:nth(N div 2+1,S))/2.
repeat(0,_) -> ok;
repeat(N,F) -> F(),repeat(N-1,F).
