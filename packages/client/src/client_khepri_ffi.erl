%% Khepri and Ra primitives for the session directory, reached only through
%% client/internal/ffi_khepri.gleam (protocol-change/079, ADR-019). Neither
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
%% Khepri upgrade must re-check join/2 against that function.
-module(client_khepri_ffi).
-export([start_system/1, stop_system/0, boot/1, join/2, forget_local/0,
         read/2, consistent/3, create/3, swap/4, delete_if/3, put/3,
         membership/1, applied_index/0]).
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

%% Joins the cluster through the member on Remote as a promotable non-voter,
%% after asking the cluster to forget this member's old identity, and waits for
%% Ra to promote it. On success the server is restarted through Khepri. On any
%% failure the local server is deleted again, so the next attempt starts clean.
join(Remote, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Id = {?STORE, node()},
    RemoteId = {?STORE, Remote},
    _ = forget_local(),
    try
        UId = ra:new_uid(ra_lib:to_binary(?STORE)),
        ok = ra:start_server(?SYSTEM, server_config(Id, UId)),
        case join_steps(RemoteId, Id, UId, Deadline) of
            ok ->
                ok = ra:stop_server(?SYSTEM, Id),
                case khepri:start(?SYSTEM, store_config(), remaining(Deadline)) of
                    {ok, ?STORE} -> {ok, nil};
                    Other -> _ = forget_local(), {error, describe(Other)}
                end;
            {error, Reason} -> _ = forget_local(), {error, Reason}
        end
    catch Class:Why -> _ = forget_local(), {error, describe({Class, Why})}
    end.

join_steps(RemoteId, Id, UId, Deadline) ->
    case ra:remove_member(RemoteId, Id, remaining(Deadline)) of
        {ok, _, _} -> add_promotable(RemoteId, Id, UId, Deadline);
        {error, not_member} -> add_promotable(RemoteId, Id, UId, Deadline);
        {error, cluster_change_not_permitted} ->
            again(Deadline, fun() -> join_steps(RemoteId, Id, UId, Deadline) end);
        Other -> {error, describe({remove_member, Other})}
    end.

add_promotable(RemoteId, Id, UId, Deadline) ->
    New = #{id => Id, uid => UId, membership => promotable},
    case ra:add_member(RemoteId, New, remaining(Deadline)) of
        {ok, _, _} -> promoted(RemoteId, Id, Deadline);
        {error, already_member} -> promoted(RemoteId, Id, Deadline);
        {error, cluster_change_not_permitted} ->
            again(Deadline, fun() -> add_promotable(RemoteId, Id, UId, Deadline) end);
        Other -> {error, describe({add_member, Other})}
    end.

%% Ra promotes a promotable member once its match index reaches the leader's
%% index at the time it was added. The promotion is read from the cluster, not
%% from the joining server, which learns it only through the log.
promoted(RemoteId, Id, Deadline) ->
    case safe(fun() -> ra:members_info(RemoteId, remaining(Deadline)) end) of
        {ok, Info, _Leader} ->
            case maps:get(Id, Info, undefined) of
                #{voter_status := #{membership := voter}} -> ok;
                _ -> again(Deadline, fun() -> promoted(RemoteId, Id, Deadline) end)
            end;
        _ -> again(Deadline, fun() -> promoted(RemoteId, Id, Deadline) end)
    end.

again(Deadline, Next) ->
    case remaining(Deadline) > 50 of
        true -> timer:sleep(50), Next();
        false -> {error, <<"the join did not finish in time">>}
    end.

remaining(Deadline) ->
    max(1, Deadline - erlang:monotonic_time(millisecond)).

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
written(_) -> {error, no_quorum}.

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
