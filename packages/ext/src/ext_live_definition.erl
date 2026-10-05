%% Only already-loaded fixed-slot modules are callable through this bridge.
-module(ext_live_definition).
-export([definition/1, change/1, migrate/3]).
definition(Name) ->
    try
        Definition = apply(existing(Name), definition, []),
        true = valid_definition(Definition),
        {ok, Definition}
    catch _:_ -> {error, <<"compiled live definition is invalid">>} end.
change({change, Definition, Version, Migration, Restore} = Change)
  when is_binary(Version), is_binary(Migration) ->
    case valid_definition(Definition) andalso valid_restore(Restore) of
        true -> {ok, Change};
        false -> {error, <<"invalid native change metadata">>}
    end;
change(_) -> {error, <<"invalid native change metadata">>}.
migrate(Name, From, State) ->
    try apply(existing(Name), migrate, [From, State]) of
        {ok, Result} when is_binary(Result) -> {ok, Result};
        {error, Reason} when is_binary(Reason) -> {error, Reason};
        _ -> {error, <<"compiled migration returned an invalid result">>}
    catch _:_ -> {error, <<"compiled migration crashed">>} end.
existing(<<"loom_live_a@", Tail/binary>> = Name) when byte_size(Tail) > 0 -> binary_to_existing_atom(Name, utf8);
existing(<<"loom_live_b@", Tail/binary>> = Name) when byte_size(Tail) > 0 -> binary_to_existing_atom(Name, utf8).
valid_definition({definition, Initial, Handler}) -> is_binary(Initial) andalso is_function(Handler, 2);
valid_definition(_) -> false.
valid_restore(none) -> true;
valid_restore({some, Text}) -> is_binary(Text);
valid_restore(_) -> false.
