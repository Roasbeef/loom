%% The event handlers a rendered view registers, for page_events_test.
%% Lustre's server runtime looks a browser's event up by the key
%% `path ++ "\n" ++ name` in the handler table lustre/vdom/cache builds from
%% the view. Those modules are internal to Lustre, so the test reads the
%% table from Erlang instead of importing them.
-module(page_events_ffi).
-export([handlers/1]).

%% The keys of the handler table of `View`'s render cache, sorted.
handlers(View) ->
    Cache = 'lustre@vdom@cache':from_node(View),
    Events = 'lustre@vdom@cache':events(Cache),
    lists:sort(maps:keys(element(2, Events))).
