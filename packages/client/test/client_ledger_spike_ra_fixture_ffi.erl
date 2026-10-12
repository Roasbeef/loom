%% Test-only scenario for the learner role of the membership ledger
%% (docs/design-notes/membership-ledger.md sections 11.3 and 16): a Ra member
%% added as a `non_voter` serves Khepri's own reads, writes through the leader,
%% stays a non-voter, and never counts toward the quorum.
%%
%% Each member is its own emulator, started with plain Erlang distribution on
%% loopback. The transport is not what is under test, and the TLS pairing is
%% proved by client_ledger_spike_fixture_ffi; Ra needs only visible nodes that
%% can reach each other, which this gives. The directory calls are the
%% production ones in client_khepri_ffi, so the reads and the membership view
%% are the ones the daemon would use. The one thing production cannot do yet is
%% join a non-voter, so that join is written here against Ra's public API, as
%% client_khepri_ffi writes the promotable join, and it is the part phase 3 of
%% the ledger would add there.
-module(client_ledger_spike_ra_fixture_ffi).
-export([scenario/1, child/2]).

-define(FIX, client_distribution_fixture_ffi).
-define(SPIKE, client_ledger_spike_fixture_ffi).
-define(KHEPRI, client_khepri_ffi).
-define(SYSTEM, loom_directory_ra).
-define(STORE, loom_directory).

%% Runs one named scenario and reports Ok or a description of what failed.
scenario(Name) ->
    Root = unicode:characters_to_binary(filename:absname(
        "build/ledger-spike-ra-"
            ++ integer_to_list(erlang:unique_integer([positive]))
            ++ "-" ++ integer_to_list(erlang:system_time(nanosecond)))),
    ok = file:make_dir(Root),
    try
        ok = run(Name, Root),
        {ok, nil}
    catch Class:Reason:Stack ->
        {error, unicode:characters_to_binary(
            io_lib:format("~p:~p~n~p", [Class, Reason, Stack]))}
    after
        file:del_dir_r(Root)
    end.

%% ---------------------------------------------------------------- scenarios

%% Two voters and a learner. The learner reads, writes through the leader,
%% stays a learner, and survives a restart. Then each kind of member is taken
%% down in turn: the learner's absence costs the voters nothing, and a voter's
%% absence leaves no quorum even though the caught-up learner is still up.
run(<<"non_voter">>, Root) ->
    Cookie = binary_to_list(?FIX:cookie("ra")),
    A = member(Root, "seed", Cookie),
    B = member(Root, "second", Cookie),
    L = member(Root, "learner", Cookie),
    NameA = name_of(A),
    NameB = name_of(B),
    NameL = name_of(L),
    with_member(A, fun(PortA) ->
        {ok, nil} = ?SPIKE:call(PortA, start_system),
        {ok, nil} = ?SPIKE:call(PortA, boot, 60000),
        {ok, nil} = ?SPIKE:call(PortA, {put, [spike, one], 1, 5000}),
        with_member(B, fun(PortB) ->
            {ok, nil} = ?SPIKE:call(PortB, start_system),
            ok = ?SPIKE:call(PortB, {join_voter, NameA}, 120000),
            #{NameA := voter, NameB := voter} = voters(PortA),

            %% The learner joins, serves the store, and its emulator ends. The
            %% emulator stops the store first rather than being killed: a member
            %% killed within a moment of joining was seen, in the spike, to come
            %% back without Ra's record of its server, which is a property of the
            %% directory store and not of a learner. The voters commit without it.
            with_member(L, fun(PortL) ->
                learner_serves_the_store(PortA, PortL, NameA, NameB, NameL),
                end_member(PortL, shutdown)
            end),
            ok = ?FIX:await_unregistered(NameL, 15000),
            {ok, nil} = ?SPIKE:call(PortA, {put, [spike, while_away], 3, 5000}),

            %% It restarts from its own disk, is still a learner, catches up,
            %% and then a voter ends too.
            with_member(L, fun(PortL2) ->
                learner_returns(PortA, PortL2, NameA, NameL),
                voter_goes_down(PortA, PortB, PortL2)
            end)
        end)
    end),
    ok.

%% ----------------------------------------------------------------- phases

%% The learner joins as a non-voter and catches up. Its own reads, local and
%% consistent, return the leader's data. A write through it reaches the leader.
%% Further traffic does not promote it, and Ra will not hand it leadership.
learner_serves_the_store(PortA, PortL, NameA, NameB, NameL) ->
    {ok, nil} = ?SPIKE:call(PortL, start_system),
    ok = ?SPIKE:call(PortL, {join_learner, NameA}, 120000),
    #{NameA := voter, NameB := voter, NameL := non_voter} = voters(PortA),
    #{NameA := voter, NameB := voter, NameL := non_voter} = voters(PortL),

    {ok, {some, 1}} = ?SPIKE:call(PortL, {read, [spike, one]}),
    {ok, {some, 1}} = ?SPIKE:call(PortL, {consistent, [spike, one]}),
    {ok, nil} = ?SPIKE:call(PortL, {put, [spike, from_learner], 2, 5000}),
    {ok, {some, 2}} = ?SPIKE:call(PortA, {consistent, [spike, from_learner]}),

    ok = ?SPIKE:call(PortA, {bulk, 300}, 60000),
    ok = ?SPIKE:call(PortL, {await_value, [spike, bulk, <<"300">>], 300, 30000}, 40000),
    #{NameL := non_voter} = voters(PortA),

    {error, non_voter} = ?SPIKE:call(PortA, {transfer, NameL}),
    ok.

%% The restarted learner is still a non-voter. A restarted emulator has no
%% connections, and Ra does not make them: the daemon's member actor links the
%% members, and the fixture does that one step by hand. Ra gives a learner
%% nothing else to do when it has been out of touch, since it does not stand for
%% election, and the leader sends it what it missed once it is reachable. The
%% learner then holds what was written while it was away.
learner_returns(PortA, PortL, NameA, NameL) ->
    {ok, nil} = ?SPIKE:call(PortL, start_system),
    true = ?SPIKE:call(PortL, {link, NameA}),
    {ok, nil} = ?SPIKE:call(PortL, boot, 60000),
    ok = ?SPIKE:call(PortL, {await_value, [spike, while_away], 3, 30000}, 40000),
    #{NameL := non_voter} = voters(PortA),
    #{NameL := non_voter} = voters(PortL),
    ok.

%% A voter's emulator ends. Of the two voters one is left, which is not a
%% majority, whatever the learner is doing, so a write times out. The learner
%% still serves what it has, and its consistent read and its write fail the way
%% a member without a quorum fails.
voter_goes_down(PortA, PortB, PortL) ->
    end_member(PortB, halt),
    {error, no_quorum} = ?SPIKE:call(PortA, {put, [spike, no_majority], 4, 3000}, 15000),
    {ok, {some, 3}} = ?SPIKE:call(PortL, {read, [spike, while_away]}),
    {error, no_quorum} = ?SPIKE:call(PortL, {consistent, [spike, while_away]}, 20000),
    {error, no_quorum} = ?SPIKE:call(PortL, {put, [spike, from_learner_alone], 5, 3000}, 15000),
    ok.

%% ----------------------------------------------------------------- driving

member(Root, Label, Cookie) ->
    Home = filename:join(Root, Label),
    ok = file:make_dir(Home),
    #{name => ?FIX:name(Label), home => Home, cookie => Cookie}.

name_of(#{name := Name}) -> Name.

%% Boots an emulator for the member and runs Fun with its port. The emulator is
%% asked to stop when Fun returns, unless Fun ended it.
with_member(#{name := Name, home := Home, cookie := Cookie}, Fun) ->
    Directory = filename:join(Home, "directory"),
    Aux = #{directory => ?FIX:bin(Directory), lifetime => 240000},
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    Encoded = binary_to_list(base64:encode(term_to_binary({#{}, Aux}))),
    Eval = lists:flatten(io_lib:format("~s:child(~p, ~p).", [?MODULE, Encoded, member])),
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout, {env, [{"HOME", ?FIX:str(Home)}]},
         {args, ["+S", "2", "-pa"] ++ Paths
             ++ ["-name", binary_to_list(Name), "-setcookie", Cookie,
                 "-noshell", "-eval", Eval]}]),
    try
        ok = ?FIX:await_ready(Port, <<>>),
        Result = Fun(Port),
        case erlang:port_info(Port, os_pid) of
            undefined -> ok;
            _ ->
                true = port_command(Port, <<"stop\n">>),
                ok = ?FIX:await_complete(Port, <<>>)
        end,
        Result
    after ?FIX:close_port(Port) end.

%% Ends the emulator and waits for it to be gone. `halt` is abrupt. `shutdown`
%% first stops the store and the Ra system, which closes the Ra directory.
end_member(Port, How) ->
    true = port_command(Port, rpc_line(How)),
    receive {Port, {exit_status, _}} -> ok after 15000 -> error(halt_timeout) end.

rpc_line(Request) ->
    iolist_to_binary(["rpc ", base64:encode(term_to_binary(Request)), "\n"]).

%% Ra's members as one member sees them, with whether each votes.
voters(Port) ->
    {ok, {Members, {some, _Leader}}} = ?SPIKE:call(Port, membership),
    maps:from_list(Members).

%% ---------------------------------------------------------------- children

child(Encoded, Role) ->
    ?FIX:child_for(fun role/3, Encoded, Role).

role(member, _Config, #{directory := Directory}) ->
    ?FIX:ready(),
    ?SPIKE:serve(fun(Request, State) -> handle(Request, Directory, State) end, #{}).

handle(start_system, Directory, State) ->
    ok = filelib:ensure_path(Directory),
    {?KHEPRI:start_system(Directory), State};
handle(boot, _Directory, State) ->
    {?KHEPRI:boot(30000), State};
handle({put, Path, Value, TimeoutMs}, _Directory, State) ->
    {?KHEPRI:put(Path, Value, TimeoutMs), State};
handle({read, Path}, _Directory, State) ->
    {?KHEPRI:read(Path, 5000), State};
handle({consistent, Path}, _Directory, State) ->
    {?KHEPRI:consistent(Path, 3000, 5000), State};
handle({link, NameBin}, _Directory, State) ->
    {net_kernel:connect_node(binary_to_atom(NameBin, utf8)), State};
handle(membership, _Directory, State) ->
    {?KHEPRI:membership(5000), State};
handle(halt, _Directory, _State) ->
    erlang:halt(0, [{flush, true}]);
handle(shutdown, _Directory, _State) ->
    _ = ?KHEPRI:stop_system(),
    erlang:halt(0, [{flush, true}]);
handle({bulk, Count}, _Directory, State) ->
    [{ok, nil} = ?KHEPRI:put([spike, bulk, integer_to_binary(Index)], Index, 5000)
     || Index <- lists:seq(1, Count)],
    {ok, State};
handle({await_value, Path, Value, WithinMs}, _Directory, State) ->
    Deadline = erlang:monotonic_time(millisecond) + WithinMs,
    {await_value(Path, Value, Deadline), State};
handle({transfer, NameBin}, _Directory, State) ->
    To = {?STORE, binary_to_atom(NameBin, utf8)},
    {ra:transfer_leadership({?STORE, node()}, To), State};
handle({join_voter, RemoteBin}, _Directory, State) ->
    {join_voter(binary_to_atom(RemoteBin, utf8)), State};
handle({join_learner, RemoteBin}, _Directory, State) ->
    {join_learner(binary_to_atom(RemoteBin, utf8)), State}.

%% Reads this member's own copy until it holds Value.
await_value(Path, Value, Deadline) ->
    case ?KHEPRI:read(Path, 2000) of
        {ok, {some, Value}} -> ok;
        Other ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {timeout, Other};
                false -> timer:sleep(100), await_value(Path, Value, Deadline)
            end
    end.

%% The production voter join, step for step: a promotable server, added through
%% a member that is already in, promoted by Ra once caught up, then recorded by
%% Khepri.
join_voter(Remote) ->
    {ok, UId} = ?KHEPRI:join_start(),
    done = until_done(fun() -> ?KHEPRI:join_remove(Remote, 5000) end),
    done = until_done(fun() -> ?KHEPRI:join_add(Remote, UId, 5000) end),
    done = until_done(fun() -> ?KHEPRI:join_promoted(Remote, 5000) end),
    {ok, nil} = ?KHEPRI:join_finish(30000),
    ok.

%% The same join for a learner. The server is configured and announced as a
%% `non_voter`, so Ra never promotes it, and there is no promotion to wait for:
%% the step before Khepri records the store is that the server has applied what
%% the leader had applied when the join began.
join_learner(Remote) ->
    _ = ?KHEPRI:forget_local(),
    UId = ra:new_uid(ra_lib:to_binary(?STORE)),
    Id = {?STORE, node()},
    ok = ra:start_server(?SYSTEM, server_config(Id, UId)),
    New = #{id => Id, uid => UId, membership => non_voter},
    done = until_done(fun() -> add_member(Remote, New) end),
    {ok, #{last_applied := Leader}, _} = ra:member_overview({?STORE, Remote}),
    done = until_done(fun() -> caught_up(Id, Leader) end),
    {ok, nil} = ?KHEPRI:join_finish(30000),
    ok.

add_member(Remote, New) ->
    case ra:add_member({?STORE, Remote}, New, 5000) of
        {ok, _, _} -> done;
        {error, already_member} -> done;
        {error, cluster_change_not_permitted} -> again;
        Other -> {failed, Other}
    end.

caught_up(Id, Index) ->
    case ra:member_overview(Id) of
        {ok, #{last_applied := Applied}, _} when Applied >= Index -> done;
        _ -> again
    end.

%% What client_khepri_ffi:server_config/2 builds for a promotable server, with
%% the membership this join announces. A Khepri upgrade must re-check both.
server_config(Id, UId) ->
    #{cluster_name => ?STORE, id => Id, uid => UId,
      friendly_name => "loom directory",
      log_init_args => #{uid => UId, min_snapshot_interval => 0},
      machine => {module, khepri_machine, #{store_id => ?STORE, member => Id}},
      membership => non_voter}.

until_done(Step) -> until_done(Step, erlang:monotonic_time(millisecond) + 90000).

until_done(Step, Deadline) ->
    case Step() of
        done -> done;
        {failed, Reason} -> error({failed, Reason});
        again ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(join_timeout);
                false -> timer:sleep(100), until_done(Step, Deadline)
            end
    end.
