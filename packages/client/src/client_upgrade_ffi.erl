%% Only native Gun calls and typed message translation live here.
-module(client_upgrade_ffi).
-export([open/2, request/2, next/2, credit/2, close/1, fixed_name/0, load/3, module_matches/2, handler/1, migrate/2, suspend/2, change/5, resume/2, pristine/0, deliver_signals/1, version/1]).

open(Host, Port) ->
    try
        Name = binary_to_list(Host),
        Result = gun:open(Name, Port, #{
            supervise => false, retry => 0, protocols => [http],
            transport => tls, connect_timeout => 10000,
            domain_lookup_timeout => 10000, tls_handshake_timeout => 10000,
            http_opts => #{max_headers => 64, max_header_block_size => 32768},
            tls_opts => [
                {verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                {server_name_indication, Name},
                {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
            ]
        }),
        case Result of
            {ok, Pid} -> {ok, Pid};
            {error, _} -> {error, <<"cannot open TLS download connection">>}
        end
    catch _:_ -> {error, <<"cannot open verified TLS download">>}
    end.

request(Pid, Path) ->
    case gun:await_up(Pid, 15000) of
        {ok, http} ->
            {ok, gun:get(Pid, Path, [
                {<<"user-agent">>, <<"loom-reviewed-component">>},
                {<<"accept-encoding">>, <<"identity">>}
            ], #{flow => 1})};
        _ -> {error, <<"TLS download connection failed">>}
    end.

next(Pid, Stream) ->
    case gun:await(Pid, Stream, 15000) of
        {response, Fin, Status, Headers} ->
            {ok, {headers, completion(Fin), Status, Headers}};
        {data, Fin, Data} -> {ok, {data, completion(Fin), Data}};
        {inform, _, _} -> {ok, inform};
        {trailers, _} -> {ok, trailers};
        _ -> {error, <<"download failed or exceeded its idle deadline">>}
    end.

completion(fin) -> finished;
completion(nofin) -> more.

credit(Pid, Stream) ->
    gun:update_flow(Pid, Stream, 1), nil.

close(Pid) ->
    try gen_statem:stop(Pid, normal, 5000)
    catch exit:_ -> ok
    end,
    nil.


%% The only implementation and registry atoms are fixed for the VM lifetime.
fixed_name() -> loom_reviewed_scratch_slots.
module(builtin) -> 'client@scratch';
module(slot_a) -> loom_scratch_a;
module(slot_b) -> loom_scratch_b.
module_matches(Module, Slot) -> Module =:= module(Slot).

%% The slot owner excludes live users before loading. There is no forced purge.
load(Slot, Bytes, _Version) when Slot =:= slot_a; Slot =:= slot_b ->
    try
        true = is_binary(Bytes) andalso byte_size(Bytes) =< 1048576,
        Module = module(Slot),
        Info = beam_lib:info(Bytes),
        {module, Module} = lists:keyfind(module, 1, Info),
        {ok, {Module, Chunks}} = beam_lib:chunks(Bytes, [exports, attributes]),
        {exports, Exports} = lists:keyfind(exports, 1, Chunks),
        {attributes, Attributes} = lists:keyfind(attributes, 1, Chunks),
        false = lists:keymember(on_load, 1, Attributes),
        true = lists:sort(Exports) =:= lists:sort(
            [{handle, 2}, {migrate, 1}, {version, 0},
             {module_info, 0}, {module_info, 1}]),
        true = code:soft_purge(Module),
        case code:atomic_load([{Module, "reviewed-scratch-release", Bytes}]) of
            ok -> {ok, nil};
            {error, _} -> {error, <<"inactive reviewed slot atomic loading refused">>}
        end
    catch _:_ -> {error, <<"invalid reviewed fixed-slot artifact or live old code">>}
    end;
load(_, _, _) -> {error, <<"the builtin component cannot be overwritten">>}.

%% Reviewed modules share this concrete typed ABI; no erased state is cast.
handler(slot_a) -> fun loom_scratch_a:handle/2;
handler(slot_b) -> fun loom_scratch_b:handle/2.
migrate(slot_a, State) -> loom_scratch_a:migrate(State);
migrate(slot_b, State) -> loom_scratch_b:migrate(State).
suspend(Pid, Timeout) -> sys_call(fun() -> sys:suspend(Pid, Timeout) end).
resume(Pid, Timeout) -> sys_call(fun() -> sys:resume(Pid, Timeout) end).
change(Pid, Slot, OldVersion, Token, Timeout) ->
    sys_call(fun() -> sys:change_code(Pid, module(Slot), OldVersion, Token, Timeout) end).
sys_call(Call) ->
    try Call() of
        ok -> {ok, nil};
        {error, Reason} when is_binary(Reason) -> {error, Reason};
        _ -> {error, <<"component system operation refused">>}
    catch _:_ -> {error, <<"component operation exceeded its deadline or target exited">>}
    end.

pristine() ->
    case code:is_loaded(loom_scratch_a) =:= false andalso code:is_loaded(loom_scratch_b) =:= false of
        true -> {ok, nil};
        false -> {error, <<"reviewed slot authority was lost while implementation code remains loaded">>}
    end.
deliver_signals(Pid) when node(Pid) =:= node() ->
    erlang:process_info(Pid, current_function) =/= undefined;
deliver_signals(_) -> false.

version(Slot) -> (module(Slot)):version().
