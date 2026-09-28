%% Lustre's render cache, for lane_memo_test. The server runtime builds the
%% cache from its first view with lustre/vdom/cache:from_node/1 and carries
%% it through every later render with lustre/vdom/diff:diff/3. Both modules
%% are internal to Lustre, so the test calls them from Erlang instead of
%% importing them.
-module(lane_memo_ffi).
-export([first/1, rerender/3]).

first(View) -> 'lustre@vdom@cache':from_node(View).

%% diff/3 returns {diff, Patch, Cache}; the test keeps the cache.
rerender(Cache, Old, New) -> element(3, 'lustre@vdom@diff':diff(Cache, Old, New)).
