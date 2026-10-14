-module(host_process_identity_test).

-include_lib("eunit/include/eunit.hrl").

%% These tests change the VM-wide environment, so scripts/serial-tests keeps
%% their whole module apart from other port launches. Each scope restores the
%% operator's original values even if an assertion raises.
process_identity_survives_timezone_change_test() ->
    with_environment([{"TZ", "UTC0"}, {"LC_ALL", "C"}], fun() ->
        Pid = host_bootstrap_ffi:current_process_id(),
        {ok, Fence} = 'host@endpoint':observe(Pid),
        {ok, Identity} = host_bootstrap_ffi:process_identity(Pid),
        with_endpoint(fun(Paths) ->
            Record = {ready, Fence, <<"127.0.0.1">>, 4242, <<"epoch">>, none},
            ?assertEqual({ok, nil}, 'host@endpoint':write(Paths, Record)),
            with_environment([{"TZ", "EST5EDT"}, {"LC_ALL", "en_US.UTF-8"}], fun() ->
                ?assertEqual({ok, Identity}, host_bootstrap_ffi:process_identity(Pid)),
                ?assertEqual({ok, true}, 'host@endpoint':is_present(Fence)),
                ?assertEqual({ok, {occupied, Record}}, 'host@endpoint':availability(Paths)),
                ?assertEqual({ok, {some, Record}}, 'host@endpoint':load(Paths)),
                ?assertEqual("EST5EDT", os:getenv("TZ")),
                ?assertEqual("en_US.UTF-8", os:getenv("LC_ALL"))
            end)
        end)
    end).

%% A legacy marker has no timezone metadata. Matching observations still let
%% the updater capture and retire that daemon; a mismatching live PID cannot
%% authorize a launch or overwrite the record, even if it was really reused.
legacy_darwin_birth_test_() ->
    case os:type() of
        {unix, darwin} -> [fun legacy_darwin_birth/0];
        _ -> []
    end.

legacy_darwin_birth() ->
    with_environment([{"TZ", "UTC0"}, {"LC_ALL", "C"}], fun() ->
        Pid = host_bootstrap_ffi:current_process_id(),
        {ok, {fence, Pid, _, At}} = 'host@endpoint':observe(Pid),
        {ok, {process_present, Birth}} = host_bootstrap_ffi:legacy_darwin_process_identity(Pid),
        Fence = {fence, Pid, Birth, At},
        ?assertEqual({ok, true}, 'host@endpoint':is_present(Fence)),
        with_endpoint(fun(Paths) ->
            Record = {starting, Fence},
            ?assertEqual({ok, nil}, 'host@endpoint':write(Paths, Record)),
            with_environment([{"TZ", "EST5EDT"}], fun() ->
                {ok, {process_present, Other}} = host_bootstrap_ffi:legacy_darwin_process_identity(Pid),
                ?assertNotEqual(Birth, Other),
                ?assertMatch({error, _}, 'host@endpoint':is_present(Fence)),
                ?assertMatch({error, _}, 'host@endpoint':availability(Paths)),
                {ok, Own} = 'host@endpoint':observe(Pid),
                ?assertMatch({error, _}, 'host@endpoint':claim(Paths, Own)),
                ?assertEqual({ok, {some, Record}}, 'host@endpoint':load(Paths))
            end)
        end)
    end).

canonical_birth_mismatch_still_proves_pid_reuse_test() ->
    {ok, {fence, Pid, Birth, At}} = 'host@endpoint':observe(host_bootstrap_ffi:current_process_id()),
    Former = {fence, Pid, <<Birth/binary, "-different">>, At},
    ?assertEqual({ok, false}, 'host@endpoint':is_present(Former)).

with_environment(Values, Body) ->
    Previous = [{Name, os:getenv(Name)} || {Name, _} <- Values],
    try
        [os:putenv(Name, Value) || {Name, Value} <- Values],
        Body()
    after
        [case Value of
             false -> os:unsetenv(Name);
             _ -> os:putenv(Name, Value)
         end || {Name, Value} <- Previous]
    end.

with_endpoint(Body) ->
    Directory = filename:join("build", "timezone-endpoint-" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Paths} = 'host@endpoint':paths(unicode:characters_to_binary(Directory)),
    try Body(Paths)
    after
        {ok, nil} = simplifile:delete(element(2, Paths))
    end.
