%% Count expensive leaf construction while exercising Lustre's real cache.
%% A private trace session observes this test process alone and is always
%% stopped, including when the rendering callback raises an exception.
-module(render_memo_ffi).
-export([counted/1]).

counted(Run) ->
    {module, 'web_view@completion'} = code:ensure_loaded('web_view@completion'),
    {module, 'session_view@markdown'} = code:ensure_loaded('session_view@markdown'),
    {ok, Session} = tprof:start(#{type => call_memory, session => render_memo_test}),
    try
        tprof:set_pattern(Session, 'web_view@completion', table, 0),
        tprof:set_pattern(Session, 'session_view@markdown', parse, 1),
        tprof:enable_trace(Session, self(), #{set_on_spawn => false}),
        Value = Run(),
        tprof:pause(Session),
        {call_memory, Rows} = tprof:collect(Session),
        {Value, calls('web_view@completion', table, Rows),
                calls('session_view@markdown', parse, Rows)}
    after
        tprof:stop(Session)
    end.

calls(Module, Function, Rows) ->
    lists:sum([Count || {M, F, _, PerPid} <- Rows,
                        M =:= Module, F =:= Function,
                        {Pid, Count, _} <- PerPid, Pid =:= self()]).
