%% Test-only shim for the telemetry package: builds `logger` events by
%% hand and runs them through the real formatter, so the handler's
%% treatment of foreign lines can be asserted without installing a
%% handler and racing the VM's own output. The Gleam-side contract lives
%% in `support/internal/ffi_format.gleam`.
-module(telemetry_test_ffi).

-export([format_report/2, format_string/2]).

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
