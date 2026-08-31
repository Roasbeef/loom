#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
%%
%% A real MCP server, as a real OS process, for the client package's
%% end-to-end (issue #106).
%%
%% `support/fake_mcp` is an in-process peer over `ChannelTransport`: it
%% proves the client actor's behaviour without an OS process anywhere.
%% This is the other half — a checked-in third-party server that the
%% harness spawns, hand-shakes with, lists and calls exactly as it would
%% a real one, over a real pipe. It is an OTP-29 escript with zero
%% dependencies (the `json` module ships in the stdlib) so that nothing
%% has to be built before the e2e can run.
%%
%% It speaks newline-delimited JSON-RPC 2.0 on stdio and it is
%% deliberately an *oracle* rather than a mock: `tools/call` answers with
%% `structuredContent` set to the `arguments` object it received,
%% verbatim. So a test that sends known values through the generated
%% façade, the cap channel, the router and this pipe can assert on the
%% bytes that came back — which is the whole wire-fidelity claim
%% `mcp/codegen` rests on (original tool and parameter names cross
%% untouched; the Gleam-side names are display artifacts).
%%
%% argv: an optional path to write this process's OS pid into, so a test
%% can prove that stopping the layer really took the child down. It is
%% written before the first reply, so a completed handshake means the
%% file is there.
%%
%% Three tools, each chosen for what it makes provable:
%%   echo_args     — one required string plus one optional string: the
%%                   wire-fidelity oracle, and the tier-1 typed façade.
%%   Create-Issue! — a hostile name, which mangles *and* digests, so the
%%                   generated surface and the wire name can be told
%%                   apart. It is also the one tool that answers
%%                   `isError: true`, so a program can be shown reading a
%%                   tool-level failure as `cap/mcp.ToolFailed` across the
%%                   real boundary — an in-band verdict from a settled
%%                   call, never a transport error.
%%   nested        — a required parameter whose schema is a nested
%%                   object: `mcp/schema` tier 2, a `report.Value`
%%                   argument. Its name is hostile too, so the generated
%%                   *label* and the *wire* name visibly differ in one
%%                   signature.

main(Args) ->
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    ok = record_pid(Args),
    loop().

record_pid([PidFile | _Rest]) ->
    file:write_file(PidFile, list_to_binary(os:getpid()));
record_pid([]) ->
    ok.

%% Exits cleanly when stdin closes, which is what `mcp/transport`'s
%% `close` does first when a client stops.
loop() ->
    case io:get_line(standard_io, "") of
        eof ->
            halt(0);
        {error, _Reason} ->
            halt(1);
        Line ->
            handle(Line),
            loop()
    end.

handle(Line) ->
    case string:trim(Line) of
        <<>> -> ok;
        Trimmed -> dispatch(decode(Trimmed))
    end.

decode(Bin) ->
    try json:decode(Bin) of
        Decoded -> {ok, Decoded}
    catch
        _Class:_Reason -> error
    end.

dispatch({ok, #{<<"method">> := Method} = Message}) ->
    Params = maps:get(<<"params">>, Message, #{}),
    %% No `id` is a notification: `notifications/initialized` and
    %% anything else arriving without one is swallowed, per JSON-RPC.
    case maps:find(<<"id">>, Message) of
        {ok, Id} -> respond(Id, Method, Params);
        error -> ok
    end;
dispatch(_Other) ->
    ok.

respond(Id, <<"initialize">>, _Params) ->
    reply(Id, initialize_result());
respond(Id, <<"tools/list">>, _Params) ->
    reply(Id, #{<<"tools">> => tools()});
respond(Id, <<"tools/call">>, Params) ->
    called(Id, Params);
respond(Id, <<"ping">>, _Params) ->
    reply(Id, #{});
respond(Id, Method, _Params) ->
    reply_error(Id, -32601, <<"no such method: ", Method/binary>>).

initialize_result() ->
    #{
        <<"protocolVersion">> => <<"2025-06-18">>,
        <<"capabilities">> => #{<<"tools">> => #{}},
        <<"serverInfo">> => #{
            <<"name">> => <<"loom-mcp-fixture">>,
            <<"version">> => <<"1">>
        }
    }.

tools() ->
    [
        #{
            <<"name">> => <<"echo_args">>,
            <<"description">> =>
                <<"Echoes the arguments it was called with, verbatim.">>,
            <<"inputSchema">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"message">> => #{
                        <<"type">> => <<"string">>,
                        <<"description">> => <<"the text to echo">>
                    },
                    <<"tag">> => #{
                        <<"type">> => <<"string">>,
                        <<"description">> => <<"an optional label">>
                    }
                },
                <<"required">> => [<<"message">>]
            }
        },
        #{
            <<"name">> => <<"Create-Issue!">>,
            <<"description">> =>
                <<"A tool whose name is no Gleam identifier.">>,
            <<"inputSchema">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"title">> => #{<<"type">> => <<"string">>}
                },
                <<"required">> => [<<"title">>]
            }
        },
        #{
            <<"name">> => <<"nested">>,
            <<"description">> =>
                <<"A tool whose required parameter is an object.">>,
            <<"inputSchema">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"Target-Repo">> => #{
                        <<"type">> => <<"object">>,
                        <<"properties">> => #{
                            <<"owner">> => #{<<"type">> => <<"string">>},
                            <<"repo">> => #{<<"type">> => <<"string">>}
                        },
                        <<"required">> => [<<"owner">>, <<"repo">>]
                    }
                },
                <<"required">> => [<<"Target-Repo">>]
            }
        }
    ].

%% The oracle. `structuredContent` is the received `arguments` object and
%% nothing else, so the test's assertion is on what actually crossed.
%% A tool name this server never listed is refused rather than echoed,
%% which is what makes the *tool* name load-bearing too: a façade that
%% sent a mangled name instead of the wire one would fail here rather
%% than pass with a plausible-looking echo.
called(Id, Params) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    case lists:any(fun(Tool) -> maps:get(<<"name">>, Tool) =:= Name end, tools()) of
        true ->
            reply(Id, result_for(Name, Arguments));
        false ->
            reply_error(Id, -32602, <<"no such tool: ", Name/binary>>)
    end.

%% The in-band failure leg. `isError` is a *tool* verdict on a call that
%% succeeded, not a transport or protocol error, and the whole of what
%% distinguishes them on the far side is that this one arrives as
%% `cap/mcp.ToolFailed` carrying the joined text.
result_for(<<"Create-Issue!">>, _Arguments) ->
    #{
        <<"content">> => [
            #{
                <<"type">> => <<"text">>,
                <<"text">> => <<"the issue tracker refused">>
            }
        ],
        <<"isError">> => true
    };
result_for(_Name, Arguments) ->
    #{
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"ok">>}
        ],
        <<"isError">> => false,
        <<"structuredContent">> => Arguments
    }.

reply(Id, Result) ->
    emit(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => Result
    }).

reply_error(Id, Code, Message) ->
    emit(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{<<"code">> => Code, <<"message">> => Message}
    }).

emit(Message) ->
    io:put_chars(standard_io, [json:encode(Message), $\n]).
