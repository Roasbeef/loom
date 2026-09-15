%% Only native Gun calls and typed message translation live here.
-module(tui_download_ffi).
-export([open/2, request/2, next/2, credit/2, close/1]).

open(Host, Port) ->
    try
        Name = binary_to_list(Host),
        Result = gun:open(Name, Port, #{
            supervise => false, retry => 0, protocols => [http],
            transport => tls, connect_timeout => 10000,
            domain_lookup_timeout => 10000, tls_handshake_timeout => 10000,
            http_opts => #{max_headers => 64, max_header_block_size => 32768},
            tls_opts => [
                {verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                {server_name_indication, Name},
                {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
            ]
        }),
        case Result of
            {ok, Pid} -> {ok, Pid};
            {error, _} -> {error, <<"cannot open TLS download connection">>}
        end
    catch _:_ -> {error, <<"cannot open verified TLS download">>}
    end.

request(Pid, Path) ->
    case gun:await_up(Pid, 15000) of
        {ok, http} ->
            {ok, gun:get(Pid, Path, [
                {<<"user-agent">>, <<"loom-updater">>},
                {<<"accept-encoding">>, <<"identity">>}
            ], #{flow => 1})};
        _ -> {error, <<"TLS download connection failed">>}
    end.

next(Pid, Stream) ->
    case gun:await(Pid, Stream, 15000) of
        {response, Fin, Status, Headers} ->
            {ok, {headers, completion(Fin), Status, Headers}};
        {data, Fin, Data} -> {ok, {data, completion(Fin), Data}};
        {inform, _, _} -> {ok, inform};
        {trailers, _} -> {ok, trailers};
        _ -> {error, <<"download failed or exceeded its idle deadline">>}
    end.

completion(fin) -> finished;
completion(nofin) -> more.

credit(Pid, Stream) ->
    gun:update_flow(Pid, Stream, 1), nil.

close(Pid) ->
    try gen_statem:stop(Pid, normal, 5000)
    catch exit:_ -> ok
    end,
    nil.
