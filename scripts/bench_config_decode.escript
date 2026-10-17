#!/usr/bin/env escript
%%! +S 1:1
%% Parser-only comparison, separate from release startup and session readiness.
%% Use the frozen/current release's runtime on PATH and its lib as ERL_LIBS:
%% ERL_LIBS=/release/lib scripts/bench_config_decode.escript legacy CONFIG [21|51]
%% Run shared against a release exporting the document readers. No providers,
%% secret commands or profile selection run here. Output never includes values.
-mode(compile).
-export([main/1]).

main([Mode, Path]) -> main([Mode, Path, "21"]);
main([Mode, Path, Count]) when Count =:= "21"; Count =:= "51" ->
    try run(mode(Mode), Path, list_to_integer(Count))
    catch _:_ ->
        io:put_chars(standard_error,
            "bench-config-decode: input decode, release API or runtime unavailable\n"),
        erlang:halt(1)
    end;
main(_) ->
    io:put_chars(standard_error,
        "usage: bench_config_decode.escript legacy|shared CONFIG [21|51]\n"
        "Use the selected release runtime on PATH and its lib as ERL_LIBS.\n"),
    erlang:halt(2).

mode("legacy") -> legacy;
mode("shared") -> shared;
mode(_) -> erlang:error(invalid_mode).

run(Mode, Path, Count) ->
    1 = erlang:system_info(schedulers_online),
    Libraries = os:getenv("ERL_LIBS"),
    true = is_list(Libraries) andalso Libraries =/= [],
    {ok, _} = application:ensure_all_started(crypto),
    {ok, Text} = file:read_file(Path),
    Expected = fingerprint(values(decode(Mode, Text))),
    warm(4, Mode, Text),
    Samples = [sample(Mode, Text, Expected) || _ <- lists:seq(1, Count)],
    Sorted = lists:sort(Samples),
    Report = #{
        mode => atom_to_binary(Mode), config_path => unicode:characters_to_binary(filename:absname(Path)),
        config_sha256 => digest(Text), config_bytes => byte_size(Text),
        decoded_sha256 => Expected, warmups => 5, samples => Count,
        minimum_us => hd(Sorted), median_us => lists:nth((Count + 1) div 2, Sorted),
        p95_us => lists:nth((95 * Count + 99) div 100, Sorted), raw_samples_us => Samples,
        schedulers_online => 1, otp_release => unicode:characters_to_binary(erlang:system_info(otp_release)),
        erl_libs => unicode:characters_to_binary(Libraries),
        catalog_beam => unicode:characters_to_binary(code:which('client@catalog'))
    },
    io:put_chars([json:encode(Report), "\n"]).

%% All validation and fingerprinting remain outside the timer. A changed result
%% is a failed sample rather than a successful timing of a different decoder.
sample(Mode, Text, Expected) ->
    {Microseconds, Results} = timer:tc(fun() -> decode(Mode, Text) end),
    Expected = fingerprint(values(Results)),
    Microseconds.

warm(0, _, _) -> ok;
warm(Count, Mode, Text) ->
    _ = values(decode(Mode, Text)),
    warm(Count - 1, Mode, Text).

values([]) -> [];
values([{ok, Value} | Rest]) -> [Value | values(Rest)];
values(_) -> erlang:error(configuration_refused).

fingerprint(Values) -> digest(term_to_binary(Values, [deterministic])).
digest(Bytes) -> binary:encode_hex(crypto:hash(sha256, Bytes), lowercase).

%% These are exactly the eleven standalone decoders load_config used, in its
%% original order. Profile/model choice and secret execution are outside scope.
decode(legacy, Text) ->
    ['client@catalog':parse(Text),
     'client@rules':parse(Text),
     'client@schedule':parse(Text),
     'client@schedule':parse_policy(Text),
     'client@jobs':parse_policy(Text),
     'client@retryconf':parse_policy(Text),
     'client@memory_config':parse(Text),
     'client@catalog':parse_tools(Text),
     'client@secrets':parse(Text),
     'client@catalog':parse_workspace(Text),
     'client@catalog':parse_advisor(Text)];
decode(shared, Text) ->
    {ok, {Catalog, Document}} = 'client@catalog':parse_with_document(Text),
    [{ok, Catalog},
     'client@rules':from_document(Document),
     'client@schedule':from_document(Document),
     'client@schedule':policy_from_document(Document),
     'client@jobs':policy_from_document(Document),
     'client@retryconf':policy_from_document(Document),
     'client@memory_config':from_document(Document),
     'client@catalog':tools_from_document(Document),
     'client@secrets':from_document(Document),
     'client@catalog':workspace_from_document(Document),
     'client@catalog':advisor_from_document(Document)].
