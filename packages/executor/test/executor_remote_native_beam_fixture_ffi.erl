%% Fixed test administration preserves actual opaque handles between two OS VMs.
%% No term is evaluated and no production service gains a replacement door.
-module(executor_remote_native_beam_fixture_ffi).
-export([publish/2, read/1, alias/3, journal_alias/2, forward_journal/2]).

publish(Path, Value = {case_state, _, _, _, _}) ->
    Bytes = term_to_binary(Value),
    case byte_size(Bytes) =< 65536 of
        true ->
            Temporary = <<Path/binary, ".part">>,
            case file:write_file(Temporary, Bytes, [binary]) of
                ok -> case file:rename(Temporary, Path) of
                    ok -> {ok, nil};
                    _ -> {error, nil}
                end;
                _ -> {error, nil}
            end;
        false -> {error, nil}
    end.

read(Path) ->
    %% Loading this fixed schema admits only its already compiled constructor
    %% atoms before safe decoding; the input cannot choose a module to load.
    lists:foreach(fun(Module) -> {module, Module} = code:ensure_loaded(Module) end,
        ['core@ids', 'executor@remote@identity', 'executor@remote@wire',
         'executor@remote@service', 'executor@remote@journal',
         'broker@executor', 'broker@exec', 'broker@policy', 'telemetry@log',
         'weft@actor', 'gleam@erlang@process']),
    case file:read_file(Path) of
        {ok, Bytes} when byte_size(Bytes) =< 65536 ->
            try binary_to_term(Bytes, [safe]) of
                Value = {case_state, _, _, _, _} -> {ok, Value};
                _ -> {error, nil}
            catch _:_ -> {error, nil} end;
        _ -> {error, nil}
    end.

%% Both local PIDs belong to this fixed executor VM. The original config stays
%% exact; only a test actor's reply door substitutes for the private Exchange.
alias({service, Config, _, Original}, Subject, Pid)
  when is_pid(Original), is_pid(Pid), node(Original) =:= node(), node(Pid) =:= node() ->
    {service, Config, Subject, Pid}.

%% The real SQLite owner is never reopened or replaced. The local public
%% observer calls its fixed forwarding subject because journal.exchange/2 is
%% intentionally local; every response still comes from the original actor.
journal_alias({journal, _, Scope}, Subject = {subject, Pid, _})
  when node(Pid) =:= node() -> {journal, Subject, Scope}.

forward_journal({journal, {subject, Pid, Tag}, _}, Message)
  when element(1, Message) =:= inspect;
       element(1, Message) =:= read_payload;
       element(1, Message) =:= release ->
    Pid ! {Tag, Message}, nil.
