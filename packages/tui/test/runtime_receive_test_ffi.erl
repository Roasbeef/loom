%% Test access to a provisional attachment's inboxes.
%%
%% The attachment test in `runtime_receive_test` has to play the worker's
%% part: publish `Prepared` with a stand-in socket, deliver a transfer on the
%% frames inbox, and relay the task's outcome. The status that holds those
%% subjects is opaque and `Prepared` is private to `tui/attachment`, and the
%% only public way to fill them is a real daemon. So these two functions read
%% the subjects out of the status and build the message, in the record shapes
%% `tui/attachment` and `tui/buffered` compile to. A change to either shape
%% breaks this module, and the test with it, which is the intent. The module
%% lives in the test tree so `src` keeps its FFI budget.
-module(runtime_receive_test_ffi).

-export([attempt_subjects/1, prepared/6]).

%% `Opening(Run(cancel, outcomes, trace), prepared, frames, candidate)`, each
%% inbox a `buffered.Inbox(subject, held)`.
attempt_subjects({opening, {run, _Cancel, {inbox, Outcomes, _}, _Trace},
                  {inbox, Prepared, _}, {inbox, Frames, _}, _Candidate}) ->
    {Prepared, Frames, Outcomes}.

%% `Prepared(socket, expected, workspace, name, key, acknowledgement)`.
prepared(Socket, Expected, Workspace, Name, Key, Ack) ->
    {prepared, Socket, Expected, Workspace, Name, Key, Ack}.
