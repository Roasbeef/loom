#!/usr/bin/env escript
% This fixture measures descriptions only; none of its effect closures run.
% Run after building client, with the repository and output directory as arguments.
main([Root, Output]) ->
  Build = Root ++ "/packages/client/build/dev/erlang",
  code:add_paths(filelib:wildcard(Build ++ "/*/ebin")),
  Noop = fun(_) -> nil end,
  Agency = {agency, Noop, Noop, Noop, Noop, Noop, Noop, Noop, 30000, []},
  History = {history, Noop, Noop, Noop},
  Memory = {memory, Noop},
  Schedules = {schedules, Noop, Noop, Noop},
  Context = {context, Noop},
  Jobs = setelement(9, tools@job:unavailable(), 30000),
  FullImports = codemode@vet@policy:allowed_imports(codemode@vet@policy:allow(codemode@vet@policy:default(), <<"cap/notes">>)),
  EffectImports = codemode@vet@policy:allowed_imports(codemode@vet@policy:allow(codemode@vet@policy:workspace_effects(), <<"cap/notes">>)),
  FullCaps = client@codemode:seam_caps(workspace_seam) ++ [<<"notes.put">>, <<"notes.get">>, <<"notes.list">>, <<"notes.read">>] ++ [<<"peer.roster">>, <<"peer.send">>],
  ChildCaps = [<<"strand.spawn">>, <<"strand.wait">>, <<"strand.send">>, <<"strand.note">>, <<"strand.notes">>, <<"strand.roster">>],
  EffectCaps = FullCaps -- ChildCaps,
  Work = {seam_offer, workspace_seam, FullImports, FullCaps, []},
  Orch = {seam_offer, orchestration_seam, FullImports, FullCaps, []},
  Effect = {seam_offer, workspace_seam, EffectImports, EffectCaps, []},
  Profiles = [{"workspace-effects", {seams, Effect, []}, EffectImports},
              {"orchestration-full", {seams, Orch, []}, FullImports},
              {"both-full", {seams, Work, [Orch]}, FullImports}],
  lists:foreach(fun({Label, Seams, _Imports}) ->
    Mode = {code_mode, Noop, {some, {background, Noop, Noop}}, Seams, 300000, 900000},
    Contrib = client@contributions:built_in({some, Agency}, {some, Mode}, {some, History}, {some, Memory}, {some, Schedules}, {some, Context}, {some, Jobs}),
    {ok, Registry} = client@contributions:registry(Contrib),
    Tools = lists:sort(fun(A,B) -> element(2,A) =< element(2,B) end, tools@tool:registered(Registry)),
    Specs = [{tool_spec, element(2,T), element(3,T), element(5,T)} || T <- Tools],
    Req = {provider_request, nil, none, [], Specs, none},
    Resolved = {resolved_model, <<"fixture">>, <<"fixture">>, thinking_off, 200000, 4096},
    Wire = provider@adapter@anthropic:build_request(<<"https://example.invalid">>, <<>>, Resolved, Req),
    file:write_file(Output ++ "/loom-tools-" ++ Label ++ "-request.json", element(5, Wire)),
    Description = tools@codemode:description(Mode),
    io:format("~s: ~p tools; description ~p bytes~n", [Label,length(Tools),byte_size(Description)])
  end, Profiles).
