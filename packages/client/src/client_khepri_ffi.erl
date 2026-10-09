%% Khepri and Ra primitives for the session directory, reached only through
%% client/internal/ffi_khepri.gleam (protocol-change/080, ADR-019). Neither
%% gleam_stdlib, gleam_erlang, gleam_otp nor weft has a replicated store, so
%% the directory has no pure alternative to these calls.
%%
%% Every function normalizes Khepri's and Ra's shapes to the ones the Gleam
%% side declares, catches exceptions at the boundary, and builds no atom from
%% input: the Ra system, the store and the path roots are literals, and node
%% atoms come from the distribution membership made at boot.
%%
%% The non-voter join is written against Ra's public API because Khepri's own
%% join adds a voter. It builds the Ra server configuration Khepri builds for
%% itself (khepri_cluster:complete_ra_server_config/1 in khepri 0.19.3) and then
%% restarts the server through khepri:start/2 so Khepri records the store. A
%% Khepri upgrade must re-check server_config/2 against that function.
-module(client_khepri_ffi).
-export([start_system/1, stop_system/0, boot/1, forget_local/0,
         join_start/0, join_remove/2, join_add/3, join_promoted/2,
         join_finish/1,
         read/2, consistent/3, create/3, swap/4, delete_if/3, put/3,
         membership/1, applied_index/0, snapshot_index/0,
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

%% The non-voter join, one primitive per Ra call. client/directory/store
%% sequences them and owns the retries and the deadline (weft/poll); each call
%% here makes its request once and says whether it was taken, should be asked
%% again (`again`), or was refused for good (`{failed, Reason}`).

%% Starts a fresh local server as a promotable non-voter, after deleting any
%% server left from an earlier attempt, and returns its new UId.
join_start() ->
    _ = forget_local(),
    try
        UId = ra:new_uid(ra_lib:to_binary(?STORE)),
        ok = ra:start_server(?SYSTEM, server_config({?STORE, node()}, UId)),
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

%% Asks the cluster to add this member, under UId, as a promotable non-voter.
join_add(Remote, UId, TimeoutMs) ->
    New = #{id => {?STORE, node()}, uid => UId, membership => promotable},
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

%% Restarts the promoted server through Khepri, so Khepri records the store.
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

server_config(Id, UId) ->
    #{cluster_name => ?STORE, id => Id, uid => UId,
      friendly_name => "loom directory",
      log_init_args => #{uid => UId, min_snapshot_interval => 0},
      machine => {module, khepri_machine, #{store_id => ?STORE, member => Id}},
      membership => promotable}.

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

%% Ra's members, each with whether it votes, and the leader, as seen through
%% this member's server.
membership(TimeoutMs) ->
    case safe(fun() -> ra:members_info({?STORE, node()}, TimeoutMs) end) of
        {ok, Info, {_, LeaderNode}} ->
            Members = [{atom_to_binary(N, utf8), voter_of(V)}
                       || {{_, N}, V} <- maps:to_list(Info)],
            {ok, {lists:sort(Members), {some, atom_to_binary(LeaderNode, utf8)}}};
        {ok, Info, _} ->
            Members = [{atom_to_binary(N, utf8), voter_of(V)}
                       || {{_, N}, V} <- maps:to_list(Info)],
            {ok, {lists:sort(Members), none}};
        {timeout, _} -> {error, no_quorum};
        {error, timeout} -> {error, no_quorum};
        _ -> {error, not_running}
    end.

voter_of(#{voter_status := #{membership := voter}}) -> voter;
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
