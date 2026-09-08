#!/usr/bin/env bash
# Regenerate the parrot-generated SQL modules (ADR-004).
#
# Workflow per docs/deps-eval.md: load the hand-written DDL into a
# throwaway SQLite file, point parrot at it, commit the generated
# module. Parrot invokes a pinned, checksum-verified sqlc binary which
# it downloads to <package>/build/.parrot/sqlc on first run; offline
# environments can pre-provision the binary at that exact path (version
# pinned in parrot's source; `sqlc version` must match) and the download
# step becomes a no-op.
#
# Requirements: gleam, python3, sqlite3 (parrot shells out to `sqlite3 <db>
# .schema` to pull the schema).
#
# Currently generated surfaces:
#   packages/events — sql/schema.sql (DDL, hand-written)
#                     src/events/sql/search.sql (named queries)
#                     -> src/events/sql.gleam   (generated, committed)
#   packages/storage — separate sql/schema.sql and sql/session.sql schemas,
#                     and src/storage/sql/*.sql named queries
#                     -> src/storage/sql.gleam, sql_schema.gleam and
#                        session_schema.gleam and catalogue_names_schema.gleam.
#                        Catalogue v2 names have a separate migration schema;
#                        runtime catalogue creation never embeds session tables.
#
# Known parrot 2.3.0 constraints (discovered by the WP-K pilot; keep in
# mind when editing the .sql files):
#   * Queries must be ASCII. A multi-byte character anywhere in a query
#     file shifts parrot's byte-offset slicing and silently corrupts
#     every later query's generated SQL text.
#   * FTS5: `CREATE VIRTUAL TABLE ... USING fts5` parses, but sqlc
#     rejects the table-valued `tbl MATCH ?` form ("column does not
#     exist"); use the column-qualified `tbl.col MATCH ?` instead.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null || {
  echo "gen-sql: sqlite3 CLI is required (parrot dumps the schema with it)" >&2
  exit 1
}

gen_package() {
  local pkg="$1"
  echo "==> $pkg"
  local tmpdb
  tmpdb="$(mktemp -t loom-gen-sql-XXXXXX.db)"
  trap 'rm -f "$tmpdb"' RETURN
  sqlite3 "$tmpdb" < "packages/$pkg/sql/schema.sql"
  if [[ "$pkg" == storage ]]; then
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_names.sql
    sqlite3 "$tmpdb" < packages/storage/sql/session.sql
  fi
  (cd "packages/$pkg" && gleam run --module parrot -- --sqlite "$tmpdb")
}

gen_package events
gen_package storage
python3 scripts/embed-sql-schema.py packages/storage/sql/schema.sql \
  packages/storage/src/storage/sql_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/session.sql \
  packages/storage/src/storage/session_schema.gleam
gleam format packages/storage/src/storage/sql_schema.gleam
gleam format packages/storage/src/storage/session_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_names.sql \
  packages/storage/src/storage/catalogue_names_schema.gleam
gleam format packages/storage/src/storage/catalogue_names_schema.gleam
echo "generated SQL modules are up to date; review and commit the diff"
