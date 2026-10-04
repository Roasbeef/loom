%% Test-only shim for the telemetry package: builds `logger` events by
%% hand and runs them through the real formatter, so the handler's
%% treatment of foreign lines can be asserted without installing a
%% handler and racing the VM's own output. The Gleam-side contract lives
%% in `support/internal/ffi_format.gleam`.
-module(telemetry_test_ffi).

-export([format_report/2, format_string/2, owner_label/0]).

%% A loom-authored event: the message is a report carrying the already
%% rendered JSON line under the `loom` key.
format_report(Level, Json) ->
    Event = #{level => Level, msg => {report, #{loom => Json}}, meta => #{}},
    unicode:characters_to_binary(telemetry_ffi:format(Event, #{})).

%% A foreign event: what OTP's own reports and third-party libraries
%% produce. The formatter has no field types to reason about here.
format_string(Level, Text) ->
    Event = #{level => Level, msg => {string, Text}, meta => meta()},
    unicode:characters_to_binary(telemetry_ffi:format(Event, #{})).

%% `logger` merges the calling process's metadata into the event before
%% any handler sees it; a synthetic event has to do the same or the
%% formatter is tested against a shape it never receives.
meta() ->
    case logger:get_process_metadata() of
        undefined -> #{};
        Map -> Map
    end.

%% What the calling process's label says, as the Gleam side's
%% `Option(#(List(#(String, String)), String))`. Only a label of the
%% frozen `{pickglass_owner, 1, Path, Role}` shape counts: anything else,
%% or no label at all, is `none`, which is how the inspector reads it.
owner_label() ->
    case process_info(self(), label) of
        {label, {pickglass_owner, 1, Path, Role}} -> {some, {Path, Role}};
        _ -> none
    end.
