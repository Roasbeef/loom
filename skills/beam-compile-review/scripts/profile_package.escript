#!/usr/bin/env escript
%% Rank the modules of a built Gleam package by erlc CPU time, and find the
%% functions inside one module that cost the most.
%%
%% Gleam 1.19 writes each module as Erlang abstract forms
%% (`build/<mode>/erlang/<package>/_gleam_artefacts/<module>.abstr`) and no
%% longer leaves a `.erl` file, so `profile_module.py` has nothing to read for
%% a Gleam module. This script compiles the forms itself with `compile:forms`
%% and measures the VM's CPU time, which is steady on a loaded host where wall
%% time is not. It reads existing build output, writes nothing, and never
%% replaces a BEAM file.
%%
%%   profile_package.escript modules ARTEFACTS_DIR [all]
%%       CPU milliseconds per module, largest first. Test modules are skipped
%%       unless `all` is given.
%%
%%   profile_package.escript sizes FILE.abstr
%%       Pretty-printed size of each function, largest first. A function much
%%       larger than its Gleam source is a record update or a nested `case`
%%       that the Gleam compiler expanded.
%%
%%   profile_package.escript ablate FILE.abstr N
%%       CPU milliseconds saved when each of the N largest functions has its
%%       body replaced by `erlang:error(stub)`. It locates cost and is not a
%%       behavior-preserving change; each figure is the median of three runs.

main(["modules", Dir]) -> modules(Dir, false);
main(["modules", Dir, "all"]) -> modules(Dir, true);
main(["sizes", File]) -> sizes(File);
main(["ablate", File, N]) -> ablate(File, list_to_integer(N));
main(_) ->
    io:format("usage: profile_package.escript modules|sizes|ablate ...~n"),
    halt(2).

modules(Dir, All) ->
    Files = filelib:wildcard(filename:join(Dir, "*.abstr")),
    Selected = [F || F <- Files, All orelse not is_test(F)],
    Rows = [{filename:basename(F, ".abstr"), cpu(forms(F))} || F <- Selected],
    Total = lists:sum([T || {_, T} <- Rows]),
    io:format("total_cpu_ms ~p modules ~p~n", [Total, length(Rows)]),
    [io:format("~8w ~s~n", [T, N]) || {N, T} <- top(15, Rows)].

sizes(File) ->
    [io:format("~8w ~p/~p~n", [S, N, A]) || {S, N, A} <- top(20, function_sizes(forms(File)))].

ablate(File, Count) ->
    Forms = forms(File),
    Largest = top(Count, function_sizes(Forms)),
    Base = median([cpu(Forms) || _ <- [1, 2, 3]]),
    io:format("baseline ~p ms~n", [Base]),
    [begin
         Saved = Base - median([cpu(stub(Forms, N, A)) || _ <- [1, 2, 3]]),
         io:format("~p/~p: size ~w, saved ~w ms~n", [N, A, S, Saved]),
         ok
     end || {S, N, A} <- Largest].

%% The modules a test run compiles beside the package's own.
is_test(File) ->
    Base = filename:basename(File, ".abstr"),
    lists:suffix("_test", Base).

forms(File) ->
    {ok, Bin} = file:read_file(File),
    binary_to_term(Bin).

function_sizes(Forms) ->
    [{length(lists:flatten(erl_pp:form(F))), N, A} || {function, _, N, A, _} = F <- Forms].

top(N, Rows) ->
    lists:sublist(lists:reverse(lists:sort(fun cmp/2, Rows)), N).

cmp({A, _, _}, {B, _, _}) -> A =< B;
cmp({_, A}, {_, B}) -> A =< B.

median(L) -> lists:nth(2, lists:sort(L)).

cpu(Forms) ->
    erlang:statistics(runtime),
    {ok, _, _} = compile:forms(Forms, [binary, return_errors, nowarn_unused_vars, nowarn_unused_function]),
    {_, Ms} = erlang:statistics(runtime),
    Ms.

stub(Forms, Name, Arity) ->
    [case F of
         {function, L, Name, Arity, _} ->
             Vars = [{var, L, list_to_atom("_V" ++ integer_to_list(I))} || I <- lists:seq(1, Arity)],
             Call = {call, L, {remote, L, {atom, L, erlang}, {atom, L, error}}, [{atom, L, stub}]},
             {function, L, Name, Arity, [{clause, L, Vars, [], [Call]}]};
         _ ->
             F
     end || F <- Forms].
