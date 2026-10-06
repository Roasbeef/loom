%% The built stylesheet's text, for stylesheet_test. gleam_stdlib has no file
%% read and web_view takes no file dependency, so the test reads the one
%% priv file it asserts about from Erlang. Returns {ok, Text} or {error, nil}.
-module(stylesheet_ffi).
-export([read/1]).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, nil}
    end.
