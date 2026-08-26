%% Erlang shim for the telemetry package. The Gleam-side contract and
%% the confinement comments live in `telemetry/internal/ffi_logger.gleam`
%% (spec §0.2: FFI is confined to internal ffi modules; this file is the
%% one flat per-package shim those externals bind to).
%%
%% Everything here is a thin adaptation of OTP `logger`. The only real
%% logic is `format/2`, which is the handler's formatter, and it
%% deliberately delegates its one judgement call — is this text a
%% secret? — back to the Gleam side, so the redaction rules have exactly
%% one implementation and it is the tested one.
-module(telemetry_ffi).

-export([
    install/1,
    set_primary_level/1,
    emit/2,
    stamp/4,
    stamped/0,
    format/2
]).

%% logger:update_handler_config/3 + logger:set_primary_config/2 — put
%% the JSON formatter on the default handler and open the primary level
%% far enough for it. OTP ships no JSON handler of its own, so "JSON
%% handler" here means the stock `default` handler with this module as
%% its formatter: same supervision, same overload protection, our line
%% shape. Idempotent, so a second boot in one VM (tests) is harmless.
install(Level) ->
    _ = logger:update_handler_config(default, formatter, {?MODULE, #{}}),
    set_primary_level(Level).

%% logger:set_primary_config/2 — the primary level gates every handler,
%% so it must be at least as permissive as what we intend to emit.
set_primary_level(Level) ->
    _ = logger:set_primary_config(level, Level),
    nil.

%% logger:log/3 — the message is a report carrying one already-rendered
%% JSON line under `loom`. Passing the finished line (rather than a map
%% for the formatter to encode) is what keeps rendering, and therefore
%% redaction, in the pure Gleam module that the tests can reach.
emit(Level, Json) ->
    _ = logger:log(Level, #{loom => Json}, #{}),
    nil.

%% logger:set_process_metadata/1 — stamps the correlation context onto
%% *this* process, for the benefit of log lines the harness did not
%% author. A `none` slot is one that is not known; the formatter
%% omits those. Merges rather than replaces, so a library's own
%% metadata on the same process survives.
stamp(Session, Strand, Op, Step) ->
    Existing =
        case logger:get_process_metadata() of
            undefined -> #{};
            Map -> Map
        end,
    Context = slots([
        {loom_session, Session},
        {loom_strand, Strand},
        {loom_op, Op},
        {loom_step, Step}
    ]),
    _ = logger:set_process_metadata(maps:merge(Existing, Context)),
    nil.

%% Gleam `Option(String)` is `{some, Binary} | none`; a `none` slot
%% contributes no metadata key at all, so an unknown slot is absent
%% rather than holding a placeholder.
slots(Pairs) ->
    lists:foldl(
        fun
            ({_Key, none}, Acc) -> Acc;
            ({Key, {some, Value}}, Acc) -> Acc#{Key => Value}
        end,
        #{},
        Pairs
    ).

%% logger:get_process_metadata/0 — reads back what `stamp/4` wrote, as
%% the four-tuple the Gleam side declared. A process that never stamped
%% answers with four `none`s rather than failing.
stamped() ->
    Map =
        case logger:get_process_metadata() of
            undefined -> #{};
            Existing -> Existing
        end,
    {
        slot(loom_session, Map),
        slot(loom_strand, Map),
        slot(loom_op, Map),
        slot(loom_step, Map)
    }.

slot(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> none;
        Value -> {some, Value}
    end.

%% The handler's formatter. Two cases, and the difference between them
%% is how much is known about the text.
%%
%% A loom-authored event arrives as `{report, #{loom => Line}}`: the
%% line was rendered by `telemetry@record:render/1`, which applied both
%% redaction rules with the field types in hand, so it is emitted
%% verbatim. Re-scrubbing it here would be worse than useless — it would
%% redact the identifiers `Ident` deliberately exempted.
%%
%% Anything else is foreign: an OTP crash report, a third-party library,
%% a `gen_server` termination. There are no field types to reason about,
%% so the whole rendered text is scrubbed, and the result is wrapped in
%% the same one-line JSON envelope with whatever context this process
%% stamped.
format(#{msg := {report, #{loom := Line}}}, _Config) ->
    [Line, $\n];
format(#{level := Level, msg := Msg} = Event, _Config) ->
    Meta = maps:get(meta, Event, #{}),
    %% A formatter that raises is removed by `logger`, taking every
    %% later line with it — so a foreign message this cannot render
    %% degrades to a fixed, obviously-truncated line instead. The
    %% catch-all is deliberate: nothing is known about the term, and
    %% losing one line beats losing the handler.
    try
        Scrubbed = telemetry@field:scrub_text(text_of(Msg)),
        Object = maps:merge(
            #{
                <<"level">> => atom_to_binary(Level, utf8),
                <<"event">> => <<"erlang">>,
                <<"msg">> => Scrubbed
            },
            context_of(Meta)
        ),
        [json:encode(Object), $\n]
    catch
        _Class:_Reason ->
            [
                <<"{\"level\":\"error\",\"event\":\"erlang\",",
                    "\"msg\":\"unformattable log event\"}">>,
                $\n
            ]
    end.

%% The three message shapes `logger` delivers, flattened to one line.
%% Embedded newlines are turned into spaces: one event per line is what
%% makes the stream greppable, and a crash report is many lines.
text_of({string, String}) ->
    one_line(String);
text_of({report, Report}) ->
    one_line(io_lib:format("~0p", [Report]));
text_of({Format, Args}) when is_list(Format) ->
    one_line(io_lib:format(Format, Args));
text_of(Other) ->
    one_line(io_lib:format("~0p", [Other])).

one_line(Chardata) ->
    Binary = unicode:characters_to_binary(Chardata),
    binary:replace(Binary, [<<"\n">>, <<"\r">>], <<" ">>, [global]).

%% The correlation slots this process stamped, as JSON object members.
%% An unstamped slot contributes no member, matching the Gleam renderer:
%% an unknown slot is absent, never null.
context_of(Meta) ->
    Slots = [
        {<<"session">>, loom_session},
        {<<"strand">>, loom_strand},
        {<<"op">>, loom_op},
        {<<"step">>, loom_step}
    ],
    lists:foldl(
        fun({Name, Key}, Acc) ->
            case maps:get(Key, Meta, undefined) of
                undefined -> Acc;
                Value -> Acc#{Name => Value}
            end
        end,
        #{},
        Slots
    ).
