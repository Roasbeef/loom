#!/usr/bin/env escript
%%! +S 1 +SDcpu 1 +SDio 1
-mode(compile).
main([Build,Root]) ->
 lists:foreach(fun code:add_patha/1,filelib:wildcard(filename:join([Build,"*","ebin"]))),
 Blob=Root++"/state/workspaces/domain/blobs",
 Path=Blob++"/b",
 ok=filelib:ensure_dir(Path),ok=file:write_file(Path,<<"fixture">>),
 Base='broker@policy':workspace_default(list_to_binary(Root)),
 Ancestor=list_to_binary(Root++"/state/workspaces"),
 Masked=setelement(4,Base,[Ancestor]),
 Exempted='tools@fs':exempting_blob_root(Masked,list_to_binary(Blob)),
 Reads=setelement(3,Exempted,[list_to_binary(Blob)|element(3,Exempted)]),
 Verdict='tools@fs':resolve_readable('tools@fs':real_filesystem(),list_to_binary(Root),Reads,list_to_binary(Path)),
 case Verdict of {error,{protected_path,_,Ancestor}}->io:format("ancestor_mask_survives_blob_exemption=true native_read=protected_path~n");_->erlang:error({unexpected_verdict,Verdict}) end.
