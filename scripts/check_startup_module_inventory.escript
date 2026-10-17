#!/usr/bin/env escript
%%! +S 1:1
%% Manual verification of a built server release's optional startup inventory.
%% Usage: escript scripts/check_startup_module_inventory.escript build/release/loom
%% Requires OTP 29+. Reads the inventory from the supplied artifact, checks
%% native initialization statically, then exercises cold and repeated batches.
%% Does not start Loom, alter the release, or join the automatically run tests.
-mode(compile).

main([Release]) ->
    true = list_to_integer(erlang:system_info(otp_release)) >= 29,
    Root = filename:absname(Release),
    Paths = filelib:wildcard(filename:join([Root, "lib", "*", "ebin"])),
    true = Paths =/= [],
    ok = code:add_paths(Paths),
    Startup = artifact(Root, 'client@startup'),
    {module, 'client@startup'} = code:load_abs(filename:rootname(Startup)),
    Modules = 'client@startup':modules(),
    25 = length(Modules),
    25 = length(lists:usort(Modules)),
    Beams = [{Module, artifact(Root, Module)} || Module <- Modules],
    Reports = [inspect(Module, Path) || {Module, Path} <- Beams],
    [] = [R || R = {_, OnLoad, Nif} <- Reports, OnLoad orelse Nif],

    %% Inspect but never load the NIF-bearing positive control. A checker that
    %% misses native initialization must fail even when the inventory is clean.
    {esqlite3_nif, true, true} =
        inspect(esqlite3_nif, artifact(Root, esqlite3_nif)),
    ok = code:ensure_modules_loaded(Modules),
    ok = code:ensure_modules_loaded(Modules),
    [] = [{M, code:which(M), Path} || {M, Path} <- Beams,
                                     code:which(M) =/= Path],
    io:format("Verified 25 unique release modules: no on_load/load_nif; "
              "NIF positive control detected; both native batches succeeded.~n");
main(_) ->
    io:format(standard_error,
              "Usage: escript scripts/check_startup_module_inventory.escript "
              "SERVER_RELEASE_ROOT (OTP 29+)~n", []),
    halt(2).

artifact(Root, Module) ->
    Pattern = filename:join([Root, "lib", "*", "ebin",
                             atom_to_list(Module) ++ ".beam"]),
    case filelib:wildcard(Pattern) of
        [Path] -> Path;
        Found -> error({expected_one_release_beam, Module, Found})
    end.

inspect(Module, Path) ->
    {beam_file, Module, _Exports, Attributes, _Info, Code} = beam_disasm:file(Path),
    {ok, {Module, [{imports, Imports}]}} = beam_lib:chunks(Path, [imports]),
    OnLoad = proplists:is_defined(on_load, Attributes) orelse
        lists:any(fun({function, _, _, _, Instructions}) ->
            lists:member(on_load, Instructions)
        end, Code),
    {Module, OnLoad, lists:member({erlang, load_nif, 2}, Imports)}.
