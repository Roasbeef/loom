%% Fixed reference/native contract and performance proof in a disposable VM.
%% Timing is untraced; allocation traces only operation roots, never descendants.
%% Heap words are cumulative allocation, not reachable bytes, footprint or RSS.
-module(platform_json_replay).
-export([main/2, portable_parse/1, native_parse/1, portable_encode/1, native_encode/1]).

portable_parse(B) -> platform_json_baseline:parse(B).
native_parse(B) -> json_codec:parse(B).
portable_encode(V) -> platform_json_baseline:to_string(V).
native_encode(V) -> json_codec:to_string(V).

main(Directory, Mode) ->
    try run(Directory, Mode), halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n", [C,R,S]), halt(1) end.

run(Directory, Mode) ->
    nonode@nohost = node(),
    CoreForms=forms(filename:join(Directory,"core@json.beam")),
    Normalize=fun(Fs)->[erl_parse:map_anno(fun(_)->0 end,F)
        || F={function,_,_,_,_}<-Fs] end,
    true=Normalize(CoreForms)=:=Normalize(forms(code:which('core@json'))),
    load(CoreForms,#{'core@json'=>platform_json_baseline}, []),
    lists:foreach(fun(File)->
        {ok,Binary}=file:read_file(filename:join(Directory,File)),
        io:format("BASELINE file=~s sha256=~s~n",[File,
            binary:encode_hex(crypto:hash(sha256,Binary),lowercase)])
    end,["core@json.beam","storage@sqlite.beam","storage@internal@register_cache.beam"]),
    %% An unchanged control substitutes only the measured candidate, after the
    %% real native implementation has passed compatibility and call witnesses.
    load(forms(code:which(json_decode_perf)),
        #{json_decode_perf=>platform_json_corpus,
          json_decode_baseline=>platform_json_baseline,'core@json'=>json_codec}, [export_all]),
    platform_json_corpus:compare_results(),
    platform_json_corpus:compare_ownership(),
    load(forms(code:which(json_whitespace_replay)),
        #{json_whitespace_replay=>platform_json_whitespace}, [export_all]),
    Inputs = platform_json_whitespace:corpus() ++ edge_inputs(),
    lists:foreach(fun(B) -> Expected=portable_parse(B), Expected=native_parse(B) end,Inputs),
    Values = encoding_values(),
    lists:foreach(fun(V) -> Expected=portable_encode(V), Expected=native_encode(V) end, Values),
    io:format("EXACT additional_inputs=~p encoded_values=~p inputs_sha256=~s values_sha256=~s~n",
        [length(Inputs),length(Values),hash(Inputs),hash(Values)]),
    %% Encoding must remain exactly the reference operation, not a different
    %% implementation hidden behind equivalent fixture outputs. Binary-builder
    %% heap words vary slightly with GC history even for unchanged code.
    [{function,_,to_string,1,[{clause,_,[{var,_,Argument}],[],
        [{call,_,{remote,_,{atom,_,'core@json'},{atom,_,to_string}},
          [{var,_,Argument}]}]}]}]=
        [F || F={function,_,to_string,1,_}<-forms(code:which(json_codec))],
    io:format("ENCODER_SELECTION reference_only exact_function_body~n"),
    native_witness(),
    mutants(),
    io:format("VM otp=~s erts=~s schedulers=~p word_bytes=~p mode=~s~n",
        [erlang:system_info(otp_release),erlang:system_info(version),
         erlang:system_info(schedulers_online),erlang:system_info(wordsize),Mode]),
    Measurements = lists:flatmap(fun({Name,Input}) ->
        {ok,V}=portable_parse(Input),
        [measure(Name,decode,Input,Mode),measure(Name,encode,V,Mode)]
    end,fixtures()),
    storage(Directory,Mode),
    %% Each decode fixture must materially reduce allocation. The unchanged
    %% encoder is guarded structurally above. No-op exits no_improvement.
    Decodes=[{B,C} || {decode,B,C}<-Measurements],
    true = lists:all(fun({B,C}) -> C =< B end,Decodes),
    case lists:all(fun({B,C}) -> C*100 =< B*90 end,Decodes) of
        true -> io:format("IMPROVEMENT codec allocation guards passed~n");
        false -> error(no_improvement)
    end.

forms(Path) ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,F}}]}}=beam_lib:chunks(Path,[abstract_code]), F.
load(F,Map,Options) ->
    Rewritten=rewrite(F,Map),
    [{attribute,_,module,Name}]=[A || A={attribute,_,module,_}<-Rewritten],
    {ok,Name,B}=compile:forms(Rewritten,[binary|Options]),
    {module,Name}=code:load_binary(Name,"isolated platform JSON replay",B).
rewrite({attribute,L,module,A},M)->{attribute,L,module,maps:get(A,M,A)};
rewrite({atom,L,A},M)->{atom,L,maps:get(A,M,A)};
rewrite(T,M) when is_tuple(T)->list_to_tuple([rewrite(X,M)||X<-tuple_to_list(T)]);
rewrite(L,M) when is_list(L)->[rewrite(X,M)||X<-L];
rewrite(X,_)->X.
hash(X)->binary:encode_hex(crypto:hash(sha256,term_to_binary(X)),lowercase).

edge_inputs() ->
    Numbers=[<<"0">>,<<"-0">>,<<"0.0">>,<<"-0.0">>,<<"1e300">>,<<"1e-300">>,
        <<"1e309">>,<<"1e-999">>,<<"1e+2">>,<<"1E-2">>,<<"01">>,<<"1.">>,<<"+1">>,
        <<"NaN">>,<<"Infinity">>,list_to_binary(lists:duplicate(400,$9))],
    Numbers ++ [<<"[",B/binary,"]">> || B<-Numbers] ++
        [<<"{\"a\":1,\"\\u0061\":2}">>,<<"[true,false,null]">>,
         <<"{\"z\":1,\"a\":2}">>,<<"null ?">>] ++
        [<<(binary:copy(<<"[">>,N))/binary,"0",(binary:copy(<<"]">>,N))/binary>>
         || N<-[255,256,257]].

encoding_values() ->
    Unicode=unicode:characters_to_binary([16#e9,16#4e2d,16#1f600,16#2028,16#2029]),
    Strings=[<<>>,<<"ordinary">>,Unicode,<<"\\u001B">>,<<"\"\\/\n\t\r\b\f">>] ++
        [<<I>> || I<-lists:seq(0,31)],
    Scalars=[null,{bool,true},{bool,false},{int,0},{int,-123456789},
        {int,1 bsl 300},{float,0.0},{float,-0.0},{float,1.0e300},{float,1.0e-300}] ++
        [{string,S} || S<-Strings],
    Scalars ++ [{object,[{S,V},{<<"same">>,null},{<<"same">>,{int,2}}]}
        || S<-Strings,V<-Scalars] ++ [{array,Scalars},{object,[]},{array,[]}].

native_witness() ->
    {module,_}=code:ensure_loaded(json),
    {module,_}=code:ensure_loaded('core@json'),
    Roots=[{json,decode,3},{'core@json',parse,1}],
    Count=fun(Input) ->
        [erlang:trace_pattern(MFA,true,[call_count]) || MFA<-Roots],
        Result=json_codec:parse(Input),
        Counts=[begin {call_count,N}=erlang:trace_info(MFA,call_count),N end || MFA<-Roots],
        [erlang:trace_pattern(MFA,false,[call_count]) || MFA<-Roots],
        {Result,Counts}
    end,
    {{ok,_},[1,0]}=Count(<<"{\"x\":[true,2,\"text\"]}">>),
    {{error,_},[1,1]}=Count(<<"{\"x\":1,\"x\":2}">>),
    io:format("NATIVE_WITNESS valid=otp_only invalid=otp_then_reference~n").

%% Rewrite only isolated ASTs. A kill requires a returned semantic difference;
%% a mutant exception or compilation failure cannot masquerade as a witness.
mutants() ->
    F=forms(code:which(json_codec_ffi)),
    Specs=[{duplicate,<<"{\"a\":1,\"a\":2}">>},
        {depth,<<(binary:copy(<<"[">>,257))/binary,"0",
                 (binary:copy(<<"]">>,257))/binary>>},
        {trailing,<<"null ?">>},
        {boolean,<<"[true,false]">>}],
    lists:foreach(fun({Name,Input})->
        Alias=list_to_atom("platform_json_mutant_"++atom_to_list(Name)),
        Changed=mutate(F,Name),
        true=Changed=/=F,
        load(Changed,#{json_codec_ffi=>Alias},[]),
        Expected=portable_parse(Input),
        Actual=Alias:parse(Input,256),
        true=Expected=/=Actual,
        io:format("MUTANT killed=~s~n",[Name])
    end,Specs).
mutate({call,L,{atom,_,is_map_key},_},duplicate)->{atom,L,false};
mutate({op,L,'<',_Depth,Maximum},depth)->{op,L,'<',{integer,L,0},Maximum};
mutate({bin,L,[]},trailing)->{var,L,'_IgnoredRest'};
mutate({function,L,boolean_value,1,_},boolean)->
    {function,L,boolean_value,1,[{clause,L,[{var,L,'Value'}],[],[{var,L,'Value'}]}]};
mutate(T,M) when is_tuple(T)->list_to_tuple([mutate(X,M)||X<-tuple_to_list(T)]);
mutate(L,M) when is_list(L)->[mutate(X,M)||X<-L];
mutate(X,_)->X.

fixtures() ->
    Small=platform_json_whitespace:fixtures(),
    Large=[{list_to_atom(N),portable_encode(V)} || {N,V}<-platform_json_corpus:fixtures(),
        lists:member(N,["escaped","transcript"])],
    %% Very small scalar encoders are correctness coverage, not this optimization's target.
    [{N,B} || {N,B}<-Small++Large].

measure(Name,Operation,Input,Mode) ->
    Base=case Operation of decode->portable_parse;encode->portable_encode end,
    Candidate=case {Operation,Mode} of
        {_,"--noop"}->Base;{decode,_}->native_parse;{encode,_}->native_encode end,
    N=case size_of(Input)>1000 of true->50;false->10000 end,
    Rows=[begin
        Order=case Round rem 2 of 1->[{baseline,Base},{candidate,Candidate}];
            0->[{candidate,Candidate},{baseline,Base}] end,
        [begin
            repeat(5,fun()->?MODULE:F(Input) end),
            {reductions,R0}=process_info(self(),reductions),
            {Us,_}=timer:tc(fun()->repeat(N,fun()->?MODULE:F(Input) end) end),
            {reductions,R1}=process_info(self(),reductions),
            io:format("TIME name=~s op=~s backend=~s round=~p calls=~p us=~p reductions=~p~n",
                [Name,Operation,Label,Round,N,Us,R1-R0])
         end || {Label,F}<-Order]
    end || Round<-lists:seq(1,8)],
    true=length(Rows)=:=8,
    Alloc=[begin
        Order=case Round rem 2 of 1->[{baseline,Base},{candidate,Candidate}];
            0->[{candidate,Candidate},{baseline,Base}] end,
        maps:from_list([{Label,allocation(?MODULE,F,[Input],N,self())} || {Label,F}<-Order])
    end || Round<-lists:seq(1,4)],
    B=median([maps:get(baseline,A)||A<-Alloc]),
    C=median([maps:get(candidate,A)||A<-Alloc]),
    io:format("ALLOC name=~s op=~s calls=~p baseline=~p candidate=~p~n",[Name,Operation,N,B,C]),
    {Operation,B,C}.
size_of(B) when is_binary(B)->byte_size(B);
size_of(V)->byte_size(portable_encode(V)).
median(Xs)->
    Sorted=lists:sort(Xs), N=length(Sorted),
    (lists:nth(N div 2,Sorted)+lists:nth(N div 2+1,Sorted))/2.
repeat(0,_)->ok;
repeat(N,F)->F(),repeat(N-1,F).
allocation(M,F,Args,N,Pid)->
    allocation_run(M,F,length(Args),fun()->repeat(N,fun()->apply(M,F,Args) end) end,Pid).
allocation_run(M,F,A,Run,Pid)->
    {ok,P}=tprof:start(#{type=>call_memory,session=>platform_json_replay}),
    try
        tprof:set_pattern(P,M,F,A),
        tprof:enable_trace(P,Pid,#{set_on_spawn=>false}),
        Run(),tprof:pause(P),
        #{all:={_,Words,_}}=tprof:inspect(tprof:collect(P),total,{measurement,descending}),Words
    after tprof:stop(P) end.

%% Two real SQLite actors use identically compiled saved/current modules.
%% The saved SQLite module must also select its saved cache helper, otherwise
%% both actors would accidentally use the newly optimized parser on misses.
storage(Directory,Mode)->
    load(forms(filename:join(Directory,"storage@internal@register_cache.beam")),
        #{'storage@internal@register_cache'=>platform_json_cache_baseline},[]),
    load(forms(filename:join(Directory,"storage@sqlite.beam")),
        #{'storage@sqlite'=>platform_json_store_baseline,
          'storage@internal@register_cache'=>platform_json_cache_baseline},[]),
    CandidateForms=case Mode of
        "--noop"->forms(filename:join(Directory,"storage@sqlite.beam"));
        _->forms(code:which('storage@sqlite')) end,
    load(forms(code:which('storage@internal@register_cache')),
        #{'storage@internal@register_cache'=>platform_json_cache_candidate},[]),
    Cache=case Mode of "--noop"->platform_json_cache_baseline;_->platform_json_cache_candidate end,
    load(CandidateForms,#{'storage@sqlite'=>platform_json_store_candidate,
        'storage@internal@register_cache'=>Cache},[]),
    lists:foreach(fun({Name,V,Rows,N})->
        Results=[begin
            Order=case R rem 2 of 1->[baseline,candidate];0->[candidate,baseline] end,
            maps:from_list([{Label,storage_trial(Label,Name,V,Rows,N,R)} || Label<-Order])
        end || R<-lists:seq(1,4)],
        B=median([maps:get(baseline,X)||X<-Results]),
        C=median([maps:get(candidate,X)||X<-Results]),
        %% Bypass has no cache hits; warm cached reads are a negative control.
        case {Name,Mode} of
            {bypass,"--expect-improved"}->true=C*100=<B*90;
            _->ok
        end
    end,[{cached,{array,lists:duplicate(32,{object,[{<<"k">>,{string,<<"payload">>}}]})},8,200},
          {bypass,{array,lists:duplicate(140000,null)},1,12}]).

storage_trial(Label,Name,V,Rows,N,Round)->
    M=case Label of baseline->platform_json_store_baseline;candidate->platform_json_store_candidate end,
    Dir=os:getenv("PLATFORM_JSON_FIXTURE_DIRECTORY"),
    Path=list_to_binary(filename:join(Dir,"fixture-"++integer_to_list(erlang:unique_integer([positive]))++".db")),
    %% The launcher supplies a fresh exclusive directory for each run.
    {ok,Store}=M:open(M:config(Path,<<"fixture">>),'core@clock':fixed(1000)),
    Keys=[integer_to_binary(I)||I<-lists:seq(1,Rows)],
    Values=[{object,[{<<"slot">>,{int,I}},{<<"payload">>,V}]}||I<-lists:seq(1,Rows)],
    Writes=[{set_register,fact_custom,K,{register_value,Value}}||{K,Value}<-lists:zip(Keys,Values)],
    {ok,_}='storage@storage':commit(Store,{tx,Writes,[]}),
    {ok,Pid}='gleam@erlang@process':subject_owner(element(2,Store)),
    Run=fun()->lists:foreach(fun({K,Value})->
        {ok,{some,{register,{register_value,Value},_}}}='storage@storage':get_register(Store,fact_custom,K)
    end,lists:zip(Keys,Values)) end,
    {ColdUs,_}=timer:tc(Run),
    repeat(2,Run),
    {reductions,R0}=process_info(Pid,reductions),
    {Us,_}=timer:tc(fun()->repeat(N,Run) end),
    {reductions,R1}=process_info(Pid,reductions),
    W=allocation_run(M,handle_open,2,fun()->repeat(N,Run) end,Pid),
    {ok,nil}='storage@storage':close(Store),
    {ok,nil}=M:retire_closed(element(2,Store)),
    [file:delete(<<Path/binary,S/binary>>)||S<-[<<>>,<<"-wal">>,<<"-shm">>]],
    io:format("STORAGE name=~s backend=~s round=~p calls=~p cold_us=~p us=~p reductions=~p words=~p~n",
        [Name,Label,Round,N*Rows,ColdUs,Us,R1-R0,W]), W.
