#!/usr/bin/env escript
%%! +S 1 +SDcpu 1 +SDio 1
-mode(compile).
main([Input,Output]) ->
 {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Input,[abstract_code]),
 Changed=[rewrite(F)||F<-Forms],
 {ok,_,Bin}=compile:forms(Changed,[binary,debug_info]),
 ok=file:write_file(Output,Bin).
rewrite({function,A,pictures,3,[{clause,B,[S,{var,C,'Ref'},I],G,[Drawn,{'case',D,E,Cases}]}]}) ->
 Bind={match,0,{var,0,'Ref'},{call,0,{remote,0,{atom,0,'session_view@transcript_image'},{atom,0,ref}},[{var,0,'Key'}]}},
 Prefix=lists:sublist(Cases,length(Cases)-1),
 {clause,CA,CP,CG,Body}=lists:last(Cases),
 {function,A,pictures,3,[{clause,B,[S,{var,C,'Key'},I],G,[Drawn,{'case',D,E,Prefix++[{clause,CA,CP,CG,[Bind|Body]}]}]}]};
rewrite({call,A,{atom,B,pictures},[Session,{call,_,{remote,_,{atom,_,'session_view@transcript_image'},{atom,_,ref}},[Key]},Images]}) ->
 {call,A,{atom,B,pictures},[rewrite(Session),rewrite(Key),rewrite(Images)]};
rewrite(T) when is_tuple(T) -> list_to_tuple([rewrite(X)||X<-tuple_to_list(T)]);
rewrite(L) when is_list(L) -> [rewrite(X)||X<-L];
rewrite(X) -> X.
