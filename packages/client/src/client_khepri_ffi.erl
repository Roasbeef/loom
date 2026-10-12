%% Khepri and Ra primitives for the session directory, reached only through
%% client/internal/ffi_khepri.gleam (protocol-change/083, ADR-020). Neither
%% gleam_stdlib, gleam_erlang, gleam_otp nor weft has a replicated store, so
%% the directory has no pure alternative to these calls.
%%
%% Every function normalizes Khepri's and Ra's shapes to the ones the Gleam
%% side declares, catches exceptions at the boundary, and builds no atom from
%% input: the Ra system, the store and the path roots are literals, and node
%% atoms come from the distribution membership made at boot.
%%
%% The join is written against Ra's public API because Khepri's own join adds a
%% voter. It builds the Ra server configuration Khepri builds for itself
%% (khepri_cluster:complete_ra_server_config/1 in khepri 0.19.3) and then
%% restarts the server through khepri:start/2 so Khepri records the store. It
%% joins either as a voter, which Ra adds as `promotable` and promotes once the
%% server has caught up, or as a learner, which Ra adds as `non_voter` and never
%% promotes (protocol-change/086, phase 3). A Khepri upgrade must re-check
%% server_config/3 against that function.
-module(client_khepri_ffi).
-export([start_system/1, stop_system/0, boot/1, restart/1, sync_server_record/0,
         forget_local/0,
         join_start/1, join_remove/2, join_add/4, join_promoted/2,
         join_caught_up/2, join_finish/1, remove_member/2,
         read/2, consistent/3, create/3, swap/4, delete_if/3, put/3,
         membership/1, membership_through/2, applied_index/0, snapshot_index/0,
         store_running_on/2]).
-include_lib("khepri/include/khepri.hrl").

-define(SYSTEM, loom_directory_ra).
-define(STORE, loom_directory).

%% ---------------------------------------------------------------- lifecycle

%% Starts the applications and the Ra system rooted at Dir. A system already
%% running is success, because a daemon starts it once and a test may start it
%% again with the same directory.
start_system(Dir) ->
    try
        {ok, _} = application:ensure_all_started(khepri),
        _ = logger:set_application_level(ra, warning),
        _ = logger:set_application_level(khepri, warning),
        _ = logger:set_application_level(aten, warning),
        Path = unicode:characters_to_list(Dir),
        Default = ra_system:default_config(),
        Config = Default#{name => ?SYSTEM, data_dir => Path,
                          wal_data_dir => Path,
                          names => ra_system:derive_names(?SYSTEM)},
        case ra_system:start(Config) of
            {ok, _} -> {ok, nil};
            {error, {already_started, _}} -> {ok, nil};
            Other -> {error, describe(Other)}
        end
    catch Class:Reason -> {error, describe({Class, Reason})}
    end.

%% Stops the store and the Ra system. Used by the bootstrap command before it
%% exits and by tests between cases.
stop_system() ->
    _ = safe(fun() -> khepri:stop(?STORE) end),
    _ = safe(fun() -> ra_system:stop(?SYSTEM) end),
    nil.

%% Starts (or restarts) the store. A server Ra already knows is restarted with
%% its membership; a server it does not know is created as a one-member cluster
%% and elected, which is what bootstrap wants and what a joined store never sees.
boot(TimeoutMs) ->
    try khepri:start(?SYSTEM, store_config(), TimeoutMs) of
        {ok, ?STORE} -> {ok, nil};
        Other -> {error, describe(Other)}
    catch Class:Reason -> {error, describe({Class, Reason})}
    end.

%% Starts a store this member has joined before, and refuses to create one.
%% Khepri's start answers a server Ra does not know by creating a fresh
%% one-member store and electing it, which is `boot` for a bootstrap and a
%% second, silent cluster for a member that was already in one: its voters would
%% be itself alone. Ra's directory is where `ra:restart_server/2` looks the
%% server up, and `ra_directory:uid_of/2` is the same lookup without the
%% start, so the refusal is made before Khepri's start can create anything. Ra
%% offers no other call that says whether it knows a server. A Ra upgrade must
%% re-check this against `khepri_cluster:ensure_server_started_locked/3`.
restart(TimeoutMs) ->
    case safe(fun() -> ra_directory:uid_of(?SYSTEM, ?STORE) end) of
        undefined -> {error, no_server_record};
        {'EXIT', Why} -> {error, {could_not_start, describe(Why)}};
        _UId ->
            case boot(TimeoutMs) of
                {ok, nil} -> {ok, nil};
                {error, Reason} -> {error, {could_not_start, Reason}}
            end
    end.

%% Writes Ra's record of this member's server to disk. Ra adds a server to its
%% directory table (`names.dets`) when the server starts, and the table reaches
%% the disk on a timer of 500 ms, not when the server is registered. A process
%% killed in between restarts without the record, and Khepri then creates a new
%% store for it (see `restart/1`). Ra syncs everything else a restart needs (the
%% server's configuration, its log and its term and vote) before it relies on it.
sync_server_record() ->
    try
        {ok, Table} = ra_system:lookup_name(?SYSTEM, directory_rev),
        ok = dets:sync(Table),
        {ok, nil}
    catch Class:Why -> {error, describe({Class, Why})}
    end.

%% The non-voter join, one primitive per Ra call. client/directory/store
%% sequences them and owns the retries and the deadline (weft/poll); each call
%% here makes its request once and says whether it was taken, should be asked
%% again (`again`), or was refused for good (`{failed, Reason}`).

%% Starts a fresh local server with the membership the join asks for, after
%% deleting any server left from an earlier attempt, and returns its new UId.
join_start(Joining) ->
    _ = forget_local(),
    try
        UId = ra:new_uid(ra_lib:to_binary(?STORE)),
        ok = ra:start_server(?SYSTEM, server_config({?STORE, node()}, UId,
                                                    membership_of(Joining))),
        {ok, UId}
    catch Class:Why -> _ = forget_local(), {error, describe({Class, Why})}
    end.

%% Asks the cluster, through the member on Remote, to forget this member's old
%% identity. Not being a member is the same as being forgotten.
join_remove(Remote, TimeoutMs) ->
    case safe(fun() -> ra:remove_member({?STORE, Remote}, {?STORE, node()}, TimeoutMs) end) of
        {ok, _, _} -> done;
        {error, not_member} -> done;
        {error, cluster_change_not_permitted} -> again;
        Other -> {failed, describe({remove_member, Other})}
    end.

%% Asks the cluster to add this member, under UId, with the membership the join
%% asks for. The server was started with the same membership: a member whose
%% configuration disagrees with the cluster's record of it takes the cluster's
%% word only when the UIds match, so the UId is what ties the two together.
join_add(Remote, UId, Joining, TimeoutMs) ->
    New = #{id => {?STORE, node()}, uid => UId, membership => membership_of(Joining)},
    case safe(fun() -> ra:add_member({?STORE, Remote}, New, TimeoutMs) end) of
        {ok, _, _} -> done;
        {error, already_member} -> done;
        {error, cluster_change_not_permitted} -> again;
        Other -> {failed, describe({add_member, Other})}
    end.

%% Whether Ra has promoted this member to a voter. Ra promotes a promotable
%% member once its match index reaches the leader's index at the time it was
%% added, and the promotion is read from the cluster, not from the joining
%% server, which learns it only through the log. An unanswered question is
%% asked again.
join_promoted(Remote, TimeoutMs) ->
    Id = {?STORE, node()},
    case safe(fun() -> ra:members_info({?STORE, Remote}, TimeoutMs) end) of
        {ok, Info, _Leader} ->
            case maps:get(Id, Info, undefined) of
                #{voter_status := #{membership := voter}} -> done;
                _ -> again
            end;
        _ -> again
    end.

%% Whether this member has joined and caught up. A learner is never promoted, so
%% this stands in for the promotion a voter waits for: the join must not report
%% a member joined, and so not serve reads, before it holds the directory. Three
%% things must hold at once. The server has heard from the leader, since until
%% then it knows no cluster. Its own configuration lists itself, which is the
%% membership change that added it reaching its log. And it has applied what the
%% cluster had committed when asked. The commit index is the member's on Remote
%% at the time of the call, and not a number fixed when the join began, which
%% keeps the step free of state. A directory written to without pause would keep
%% the learner behind for ever; the directory takes a handful of writes per
%% session.
join_caught_up(Remote, TimeoutMs) ->
    Id = {?STORE, node()},
    Own = safe(fun() -> ra:member_overview(Id) end),
    There = safe(fun() -> ra:member_overview({?STORE, Remote}, TimeoutMs) end),
    case {Own, There} of
        {{ok, #{leader_id := Leader, cluster := Cluster, last_applied := Applied}, _},
         {ok, #{last_applied := Theirs}, _}}
          when Leader =/= undefined, Applied >= Theirs ->
            case maps:is_key(Id, Cluster) of
                true -> done;
                false -> again
            end;
        _ -> again
    end.

%% Removes the member on Node from the cluster, through this member's own
%% server, which is the leader when the reconciler calls it. Ra returns once the
%% change is appended, not committed, and refuses another change until it is, so
%% a second call before then answers `again`. Not being a member is the same as
%% having been removed. The name is looked up as an existing atom and never
%% made into one, so ledger text cannot grow the atom table.
remove_member(Name, TimeoutMs) ->
    try binary_to_existing_atom(Name, utf8) of
        Node ->
            case safe(fun() -> ra:remove_member({?STORE, node()}, {?STORE, Node}, TimeoutMs) end) of
                {ok, _, _} -> done;
                {error, not_member} -> done;
                {error, cluster_change_not_permitted} -> again;
                {timeout, _} -> again;
                Other -> {failed, describe({remove_member, Other})}
            end
    catch error:badarg -> done
    end.

%% Restarts the joined server through Khepri, so Khepri records the store.
join_finish(TimeoutMs) ->
    try
        ok = ra:stop_server(?SYSTEM, {?STORE, node()}),
        case khepri:start(?SYSTEM, store_config(), TimeoutMs) of
            {ok, ?STORE} -> {ok, nil};
            Other -> {error, describe(Other)}
        end
    catch Class:Why -> {error, describe({Class, Why})}
    end.

%% Deletes this member's local server and its data, for a store that is not
%% joined. Nothing is lost that the cluster does not hold.
forget_local() ->
    _ = safe(fun() -> khepri:stop(?STORE) end),
    _ = safe(fun() -> ra:force_delete_server(?SYSTEM, {?STORE, node()}) end),
    nil.

store_config() ->
    #{cluster_name => ?STORE, friendly_name => "loom directory"}.

%% The Ra membership a join asks for: a voter is added as promotable, which Ra
%% promotes once it has caught up, and a learner as non_voter, which it never
%% promotes and never counts toward a majority.
membership_of(as_voter) -> promotable;
membership_of(as_learner) -> non_voter.

server_config(Id, UId, Membership) ->
    #{cluster_name => ?STORE, id => Id, uid => UId,
      friendly_name => "loom directory",
      log_init_args => #{uid => UId, min_snapshot_interval => 0},
      machine => {module, khepri_machine, #{store_id => ?STORE, member => Id}},
      membership => Membership}.

%% ---------------------------------------------------------------- reads

%% The member's own copy, without waiting for any other member.
read(Path, TimeoutMs) ->
    found(safe(fun() -> khepri:get(?STORE, Path, #{favor => low_latency,
                                                    timeout => TimeoutMs}) end)).

%% Waits for this member's copy to hold everything the leader has committed,
%% then reads it. The caller bounds the whole call, because the fence does not
%% honour its timeout when the majority is gone.
consistent(Path, FenceMs, TimeoutMs) ->
    case safe(fun() -> khepri:fence(?STORE, FenceMs) end) of
        ok -> read(Path, TimeoutMs);
        {error, timeout} -> {error, no_quorum};
        {timeout, _} -> {error, no_quorum};
        _ -> {error, not_running}
    end.

found({ok, Data}) -> {ok, {some, Data}};
found({error, {khepri, node_not_found, _}}) -> {ok, none};
found({error, timeout}) -> {error, no_quorum};
found({timeout, _}) -> {error, no_quorum};
found(_) -> {error, not_running}.

%% ---------------------------------------------------------------- writes

create(Path, Value, TimeoutMs) ->
    written(safe(fun() -> khepri:create(?STORE, Path, Value, #{timeout => TimeoutMs}) end)).

swap(Path, Expected, Value, TimeoutMs) ->
    written(safe(fun() -> khepri:compare_and_swap(?STORE, Path, Expected, Value,
                                                  #{timeout => TimeoutMs}) end)).

put(Path, Value, TimeoutMs) ->
    written(safe(fun() -> khepri:put(?STORE, Path, Value, #{timeout => TimeoutMs}) end)).

%% Deletes the node at Path only if its payload is exactly Expected. Khepri
%% answers a condition that matched nothing with an empty set of deleted
%% nodes, which says nothing about why, so the answer is followed by a read of
%% what the node holds now.
delete_if(Path, Expected, TimeoutMs) ->
    {Prefix, [Last]} = lists:split(length(Path) - 1, Path),
    Pattern = Prefix ++ [#if_all{conditions = [Last,
                                  #if_data_matches{pattern = Expected}]}],
    case safe(fun() -> khepri_adv:delete(?STORE, Pattern, #{timeout => TimeoutMs}) end) of
        {ok, Deleted} when map_size(Deleted) > 0 -> {ok, nil};
        {ok, _} ->
            case read(Path, TimeoutMs) of
                {ok, Now} -> {error, {mismatch, Now}};
                {error, Failure} -> {error, Failure}
            end;
        Other -> written(Other)
    end.

written(ok) -> {ok, nil};
written({error, {khepri, mismatching_node, #{node_props := #{data := Data}}}}) ->
    {error, {mismatch, {some, Data}}};
written({error, {khepri, mismatching_node, _}}) -> {error, {mismatch, none}};
written({error, {khepri, node_not_found, _}}) -> {error, {mismatch, none}};
written({error, timeout}) -> {error, no_quorum};
written({timeout, _}) -> {error, no_quorum};
written({error, noproc}) -> {error, not_running};
written({error, {khepri, not_a_khepri_store, _}}) -> {error, not_running};
written({'EXIT', _}) -> {error, not_running};
written(Other) -> {error, {unexpected, describe(Other)}}.

%% ---------------------------------------------------------------- membership

%% Ra's members, each with whether it votes, the leader, and the members the
%% leader reports as reachable, as seen through this member's server.
membership(TimeoutMs) ->
    membership_through(node(), TimeoutMs).

%% The same question asked of the server on Node. `ra:members_info/2` is a
%% leader call: a server that is not the leader forwards it to the leader it
%% knows, and the answer is the leader's own list of the cluster, so a member
%% asks it of a peer to learn what the cluster holds when its own server cannot
%% say, as after the leader removed it. The leader reports each member's
%% `status`, and `normal` is the only status that means its log is being
%% replicated now; a follower's answer to a question it was not forwarded
%% carries no status, so the third element is empty there. The members list
%% every server in the leader's configuration, committed or not.
membership_through(Node, TimeoutMs) ->
    case safe(fun() -> ra:members_info({?STORE, Node}, TimeoutMs) end) of
        {ok, Info, {_, LeaderNode}} ->
            {ok, {members_of(Info), {some, atom_to_binary(LeaderNode, utf8)},
                  up_of(Info)}};
        {ok, Info, _} ->
            {ok, {members_of(Info), none, up_of(Info)}};
        {timeout, _} -> {error, no_quorum};
        {error, timeout} -> {error, no_quorum};
        _ -> {error, not_running}
    end.

members_of(Info) ->
    lists:sort([{atom_to_binary(N, utf8), voter_of(V)}
                || {{_, N}, V} <- maps:to_list(Info)]).

up_of(Info) ->
    lists:sort([atom_to_binary(N, utf8)
                || {{_, N}, #{status := normal}} <- maps:to_list(Info)]).

voter_of(#{voter_status := #{membership := voter}}) -> voter;
voter_of(#{voter_status := #{membership := promotable}}) -> promoting;
voter_of(#{voter_status := _}) -> non_voter;
voter_of(_) -> voter.

%% The log index of this member's latest snapshot, or 0 when it has none or
%% is not running.
snapshot_index() ->
    case safe(fun() -> ra:member_overview({?STORE, node()}) end) of
        {ok, #{log := #{snapshot_index := Index}}, _} when is_integer(Index) ->
            Index;
        _ -> 0
    end.

%% Whether a store answers on Node: its Ra server for the directory store
%% replies to a membership question within the timeout. Bootstrap asks every
%% configured member, so that a second bootstrap never starts a second cluster.
store_running_on(Node, TimeoutMs) ->
    case safe(fun() -> ra:members({?STORE, Node}, TimeoutMs) end) of
        {ok, _, _} -> true;
        _ -> false
    end.

%% The last log index this member has applied, or 0 when it is not running.
applied_index() ->
    case safe(fun() -> ra:member_overview({?STORE, node()}) end) of
        {ok, #{last_applied := Index}, _} when is_integer(Index) -> Index;
        _ -> 0
    end.

%% Runs Fun and turns an exception into a value the callers match, so no
%% exception crosses into Gleam.
safe(Fun) ->
    try Fun() catch Class:Reason -> {'EXIT', {Class, Reason}} end.

describe(Term) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Term])).
