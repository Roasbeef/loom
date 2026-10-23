%% Only the trusted satellite controller can reach this module. Authored
%% imports and native extension source files are refused by package vetting.
-module(ext_live_code).
-export([load/3, retire/1]).

load(Modules, Expected, Baseline) ->
    try
        true = length(Modules) > 0 andalso length(Modules) =< 16,
        true = lists:sort([Name || {Name, _, _} <- Modules]) =:= lists:sort(Expected),
        true = length(lists:usort(Expected)) =:= length(Expected),
        true = lists:sum([byte_size(Bytes) || {_, Bytes, _} <- Modules]) =< 2097152,
        Incoming = lists:append([atoms(Bytes) || {_, Bytes, _} <- Modules]),
        reserve_atoms(Baseline, Incoming),
        Prepared = lists:map(fun prepare/1, Modules),
        case code:atomic_load(Prepared) of
            ok -> {ok, nil};
            {error, _} -> {error, <<"inactive slot atomic loading refused">>}
        end
    catch
        _:_ -> {error, <<"invalid fixed-slot compiled artifact">>}
    end.

prepare({Name, Bytes, Digest}) when is_binary(Name), is_binary(Bytes), is_binary(Digest) ->
    Hex = binary:encode_hex(crypto:hash(sha256, Bytes), lowercase),
    true = Digest =:= <<"sha256-", Hex/binary>>,
    true = fixed_slot(Name),
    Info = beam_lib:info(Bytes),
    {module, Module} = lists:keyfind(module, 1, Info),
    true = atom_to_binary(Module, utf8) =:= Name,
    {Module, "immutable-live-artifact", Bytes}.

fixed_slot(<<"loom_live_a@", Tail/binary>>) -> byte_size(Tail) > 0;
fixed_slot(<<"loom_live_b@", Tail/binary>>) -> byte_size(Tail) > 0;
fixed_slot(_) -> false.

retire(Expected) ->
    try
        true = length(Expected) > 0 andalso length(Expected) =< 16,
        lists:foreach(fun(Name) ->
            true = fixed_slot(Name),
            Module = existing(Name),
            %% The inactive namespace has no admitted callers. Delete moves
            %% its current code to old, making soft_purge the reference proof.
            case Module of
                absent -> ok;
                _ -> _ = code:delete(Module), true = code:soft_purge(Module)
            end
        end, Expected),
        {ok, nil}
    catch
        _:_ -> {error, <<"inactive implementation still has live references">>}
    end.

existing(Name) ->
    try binary_to_existing_atom(Name, utf8)
    catch error:badarg -> absent end.

%% Reservation precedes every operation which might intern a BEAM atom. Failed
%% loads retain their reservation because VM atom creation cannot be undone.
reserve_atoms(Baseline, Incoming) ->
    Existing = case get(ext_live_code_atoms) of undefined -> Baseline; Names -> Names end,
    Reserved = lists:usort(Existing ++ Incoming),
    true = length(Reserved) =< 4096,
    true = lists:all(fun is_binary/1, Reserved),
    true = lists:sum([byte_size(Name) || Name <- Reserved]) =< 131072,
    put(ext_live_code_atoms, Reserved),
    ok.

atoms(<<"FOR1", Size:32, "BEAM", Chunks/binary>>) when Size =:= byte_size(Chunks) + 4 -> chunks(Chunks, []).
chunks(<<>>, Atoms) when Atoms =/= [] -> Atoms;
chunks(<<Name:4/binary, Size:32, Rest/binary>>, Atoms) ->
    Padding = (4 - Size rem 4) rem 4,
    <<Payload:Size/binary, _:Padding/binary, Tail/binary>> = Rest,
    case Name of
        <<"AtU8">> -> chunks(Tail, atom_table(Payload) ++ Atoms);
        <<"Atom">> -> chunks(Tail, atom_table(Payload) ++ Atoms);
        <<"LitT">> ->
            {ok, Bytes} = literal_bytes(Payload),
            {ok, Names} = 'ext@internal@literal_atoms':read(Bytes),
            chunks(Tail, Names ++ Atoms);
        _ -> chunks(Tail, Atoms)
    end.
atom_table(<<Count:32/signed, Rest/binary>>) when Count < 0, Count >= -8192 -> compact_names(Rest, -Count, []);
atom_table(<<Count:32, Rest/binary>>) when Count =< 8192 -> atom_names(Rest, Count, []).
compact_names(<<>>, 0, Acc) -> Acc;
compact_names(<<Size:4, 0:4, Name:Size/binary, Rest/binary>>, Count, Acc) when Count > 0 ->
    compact_names(Rest, Count-1, [Name|Acc]);
compact_names(<<High:3, 0:1, 1:1, 0:3, Low:8, Tail/binary>>, Count, Acc) when Count > 0 ->
    Size = High * 256 + Low,
    true = Size =< 1020,
    <<Name:Size/binary, Rest/binary>> = Tail,
    compact_names(Rest, Count-1, [Name|Acc]).
atom_names(<<>>, 0, Acc) -> Acc;
atom_names(<<Size:8, Name:Size/binary, Rest/binary>>, Count, Acc) when Count > 0 ->
    atom_names(Rest, Count - 1, [Name | Acc]).

%% Literal inflation cannot use binary_to_term: that would intern names before
%% the cumulative atom budget can reserve them. safeInflate bounds actual
%% output even when the table's declared expanded size lies.
literal_bytes(<<0:32, Bytes/binary>>) when byte_size(Bytes) =< 8388608 ->
    {ok, Bytes};
literal_bytes(<<Size:32, Compressed/binary>>) when Size > 0, Size =< 8388608 ->
    Z = zlib:open(),
    try
        zlib:inflateInit(Z),
        Bytes = literal_inflate(Z, Compressed, 0, []),
        true = byte_size(Bytes) =:= Size,
        {ok, Bytes}
    catch _:_ -> {error, <<"invalid or oversized BEAM literal compression">>}
    after zlib:close(Z) end;
literal_bytes(_) -> {error, <<"BEAM expanded literals exceed 8 MiB">>}.

literal_inflate(Z, Input, Written, Acc) ->
    {Status, Output} = zlib:safeInflate(Z, Input),
    Next = Written + iolist_size(Output),
    true = Next =< 8388608,
    case Status of
        continue -> literal_inflate(Z, <<>>, Next, [Acc, Output]);
        finished -> iolist_to_binary([Acc, Output])
    end.
