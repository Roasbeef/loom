%% SQLite handles never leave this satellite-local bridge. Fixed schema loading
%% precedes installation of the native read-only authorizer; model SQL is passed
%% only to readonly_query and is never interpolated into trusted inserts.
-module(loom_cap_lsp_sql).
-export([query/6]).

query(Documents, Symbols, Targets, References, Sql, Params) ->
    try
        ok = esqlite3:sandbox_heap_limit(),
        {ok, Db} = esqlite3:open(":memory:"),
        try
            seed(Db, Documents, Symbols, Targets, References),
            Limits = #{rows => 500, bytes => 1048576, milliseconds => 2000,
                       operations => 1000000, columns => 32},
            case esqlite3:readonly_query(Db, Sql, [parameter(P) || P <- Params],
                    [<<"documents">>, <<"symbols">>, <<"targets">>, <<"references">>], Limits) of
                {ok, {Columns, Rows}} ->
                    {ok, {Columns, [[cell(C) || C <- R] || R <- Rows]}};
                {error, {Kind, Message}} -> {error, {atom_to_binary(Kind), Message}}
            end
        after
            esqlite3:close(Db)
        end
    catch
        error:{badmatch, {error, {Kind0, Message0}}} when is_atom(Kind0), is_binary(Message0) ->
            {error, {atom_to_binary(Kind0), Message0}};
        _Class:_Reason -> {error, {<<"sqlite_failed">>, <<"the private observation database could not be prepared">>}}
    end.

seed(Db, Documents, Symbols, Targets, References) ->
    ok = esqlite3:exec(Db, "CREATE TABLE documents(path TEXT PRIMARY KEY,digest TEXT NOT NULL,version INTEGER);"
        "CREATE TABLE symbols(id INTEGER PRIMARY KEY,parent_id INTEGER,name TEXT NOT NULL,kind TEXT NOT NULL,detail TEXT,path TEXT NOT NULL,line INTEGER NOT NULL,column INTEGER NOT NULL,text TEXT NOT NULL,anchor TEXT NOT NULL);"
        "CREATE TABLE targets(id INTEGER PRIMARY KEY,symbol TEXT NOT NULL,asked_path TEXT NOT NULL,asked_line INTEGER,path TEXT NOT NULL,line INTEGER NOT NULL,column INTEGER NOT NULL,text TEXT NOT NULL,anchor TEXT NOT NULL);"
        "CREATE TABLE \"references\"(target_id INTEGER NOT NULL,path TEXT NOT NULL,line INTEGER NOT NULL,column INTEGER NOT NULL,text TEXT NOT NULL,anchor TEXT NOT NULL);"
        "BEGIN;"),
    insert(Db, "INSERT INTO documents VALUES(?,?,?)", Documents),
    insert(Db, "INSERT INTO symbols VALUES(?,?,?,?,?,?,?,?,?,?)", Symbols),
    insert(Db, "INSERT INTO targets VALUES(?,?,?,?,?,?,?,?,?)", Targets),
    insert(Db, "INSERT INTO \"references\" VALUES(?,?,?,?,?,?)", References),
    ok = esqlite3:exec(Db, "COMMIT;").

insert(_Db, _Sql, []) -> ok;
insert(Db, Sql, Rows) ->
    {ok, Statement} = esqlite3:prepare(Db, Sql),
    try
        lists:foreach(fun(Row) ->
            ok = esqlite3:bind(Statement, [parameter(P) || P <- Row]),
            '$done' = esqlite3:step(Statement),
            ok = esqlite3:reset(Statement)
        end, Rows)
    after
        esqlite3:finalize(Statement)
    end.

parameter(null) -> null;
parameter({integer, N}) -> N;
parameter({real, N}) -> N;
parameter({text, S}) -> S.

cell(null) -> null;
cell({integer, N}) -> {integer, N};
cell({real, N}) -> {real, N};
cell({text, S}) -> {text, S}.
