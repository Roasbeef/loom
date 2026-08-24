%% Erlang shims for the tools package. One flat module per package
%% (house FFI rule); every function here is re-exported to Gleam only
%% through src/tools/internal/ffi_*.gleam.
-module(tools_ffi).

-export([sha256/1, read_link/1]).

%% crypto:hash/2 with the algorithm atom fixed on the Erlang side, so no
%% atom is constructed from Gleam. Used for content-addressing blob
%% overflow files, where collision resistance matters and no pure Gleam
%% alternative exists at acceptable cost.
sha256(Bytes) ->
    crypto:hash(sha256, Bytes).

%% file:read_link_all/1 (lstat semantics: inspects the path itself,
%% never following a final symlink), normalized to the shapes of
%% tools/tool.LinkStatus: einval means the path exists and is not a
%% symlink; enoent/enotdir mean nothing exists there; anything else is
%% reported by name. Used by workspace containment (tools/fs) to
%% resolve symlinks before checking a path against the root — no pure
%% alternative exists because symlink targets live only in the real
%% filesystem.
read_link(Path) ->
    case file:read_link_all(Path) of
        {ok, Target} ->
            {ok, {link_target, unicode:characters_to_binary(Target)}};
        {error, einval} ->
            {ok, not_a_link};
        {error, enoent} ->
            {ok, link_missing};
        {error, enotdir} ->
            {ok, link_missing};
        {error, Reason} ->
            {error, atom_to_binary(Reason, utf8)}
    end.
