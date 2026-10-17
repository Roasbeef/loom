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
# Requirements: gleam, sqlite3 (parrot shells out to `sqlite3 <db> .schema`
# to pull the schema).
#
# Currently generated surfaces:
#   packages/events  — sql/schema.sql (DDL, hand-written)
#                      src/events/sql/search.sql (named queries)
#                      -> src/events/sql.gleam   (generated, committed)
#   packages/storage — every sql/*.sql file is a schema, and
#                      src/storage/sql/*.sql holds the named queries
#                      -> src/storage/sql.gleam (parrot) and one
#                         src/storage/<name>_schema.gleam per schema file
#                         (packages/storage/dev/embed_schema.gleam).
#
# This script lists no storage schema. The embedder finds the files and
# prints the order a scratch database must load them in: the base schema,
# the catalogue migrations in version order (read from
# `storage/catalogue.migrations`, because a later version ALTERs tables an
# earlier one created), the session schema, then the rest by name. Runtime
# catalogue creation never embeds session tables. The executor ledger's
# tables live in their own database (protocol-change/078) but share
# sql.gleam's queries, so its schemas load here too.
#
# Known parrot 2.3.0 constraints (discovered by the WP-K pilot; keep in
# mind when editing the .sql files):
#   * Queries must be ASCII. A multi-byte character anywhere in a query
#     file shifts parrot's byte-offset slicing and silently corrupts
#     every later query's generated SQL text. The embedder refuses
#     non-ASCII schemas for the same reason.
#   * FTS5: `CREATE VIRTUAL TABLE ... USING fts5` parses, but sqlc
#     rejects the table-valued `tbl MATCH ?` form ("column does not
#     exist"); use the column-qualified `tbl.col MATCH ?` instead.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null || {
  echo "gen-sql: sqlite3 CLI is required (parrot dumps the schema with it)" >&2
  exit 1
}

# The DDL files a package loads, one path per line, relative to the package.
# Storage asks its embedder; the capture is a separate step so that a failing
# `gleam run` stops the script instead of vanishing into a pipeline.
ddl_files() {
  local pkg="$1"
  if [[ "$pkg" == storage ]]; then
    (cd packages/storage && gleam run -m embed_schema load-order)
  else
    echo "sql/schema.sql"
  fi
}

gen_package() {
  local pkg="$1"
  echo "==> $pkg"
  local tmpdb
  tmpdb="$(mktemp -t loom-gen-sql-XXXXXX.db)"
  trap 'rm -f "$tmpdb"' RETURN

  local files file
  files="$(ddl_files "$pkg")"
  while IFS= read -r file; do
    sqlite3 "$tmpdb" < "packages/$pkg/$file"
  done <<< "$files"

  (cd "packages/$pkg" && gleam run --module parrot -- --sqlite "$tmpdb")
}

gen_package events
gen_package storage
(cd packages/storage && gleam run -m embed_schema)
echo "generated SQL modules are up to date; review and commit the diff"
