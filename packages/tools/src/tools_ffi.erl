%% Erlang shims for the tools package. One flat module per package
%% (house FFI rule); every function here is re-exported to Gleam only
%% through src/tools/internal/ffi_*.gleam.
-module(tools_ffi).

-export([sha256/1]).

%% crypto:hash/2 with the algorithm atom fixed on the Erlang side, so no
%% atom is constructed from Gleam. Used for content-addressing blob
%% overflow files, where collision resistance matters and no pure Gleam
%% alternative exists at acceptable cost.
sha256(Bytes) ->
    crypto:hash(sha256, Bytes).
