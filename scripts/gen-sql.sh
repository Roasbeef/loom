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
#                        session_schema.gleam, catalogue_names_schema.gleam,
#                        catalogue_archives_schema.gleam,
#                        catalogue_claims_schema.gleam and
#                        catalogue_subtitles_schema.gleam and
#                        catalogue_credential_kinds_schema.gleam and
#                        catalogue_logins_schema.gleam and
#                        catalogue_recent_folders_schema.gleam. Each catalogue version
#                        after the first has its own migration schema;
#                        runtime catalogue creation never embeds session tables.
#   packages/executor — native, workspace, resource and generation schemas; named queries
#                     under src/executor/sql/ -> src/executor/sql.gleam,
#                     custody_schema.gleam, workspace_schema.gleam,
#                     resource_schema.gleam and generation_registry_schema.gleam.
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
  local tmpdb output
  tmpdb="$(mktemp -t loom-gen-sql-XXXXXX.db)"
  output="$(mktemp -t loom-gen-sql-XXXXXX.log)"
  trap 'rm -f "$tmpdb" "$output"' RETURN
  sqlite3 "$tmpdb" < "packages/$pkg/sql/schema.sql"
  if [[ "$pkg" == storage ]]; then
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_names.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_archives.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_claims.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_subtitles.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_credential_kinds.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_logins.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_recent_folders.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_profiles.sql
    sqlite3 "$tmpdb" < packages/storage/sql/catalogue_workspace_bindings.sql
    sqlite3 "$tmpdb" < packages/storage/sql/session.sql
    sqlite3 "$tmpdb" < packages/storage/sql/owner_custody.sql
  fi
  if [[ "$pkg" == executor ]]; then
    sqlite3 "$tmpdb" < packages/executor/sql/workspace.sql
    sqlite3 "$tmpdb" < packages/executor/sql/resources.sql
    sqlite3 "$tmpdb" < packages/executor/sql/generations.sql
    sqlite3 "$tmpdb" < packages/executor/sql/lsp_custody.sql
  fi
  # Parrot 2.3.0 prints generation errors but returns zero. Its success marker
  # follows sqlc, code generation and formatting; require it as well as the
  # process exit status so a stale committed binding cannot masquerade as fresh.
  (cd "packages/$pkg" && gleam run --module parrot -- --sqlite "$tmpdb") | tee "$output"
  if ! grep -Fq 'SQL successfully generated!' "$output"; then
    echo "gen-sql: $pkg generation did not complete successfully" >&2
    return 1
  fi
}

# An optional package list lets independent schema owners regenerate only
# their artifacts. The default remains the complete repository surface.
packages=("$@")
if [[ ${#packages[@]} -eq 0 ]]; then
  packages=(events storage executor)
fi
for pkg in "${packages[@]}"; do
  case "$pkg" in
    events|storage|executor) gen_package "$pkg" ;;
    *) echo "gen-sql: unsupported package $pkg" >&2; exit 1 ;;
  esac
done

# Schema constants are deterministic copies and do not invoke sqlc.
python3 scripts/embed-sql-schema.py packages/executor/sql/schema.sql \
  packages/executor/src/executor/custody_schema.gleam
gleam format packages/executor/src/executor/custody_schema.gleam
python3 scripts/embed-sql-schema.py packages/executor/sql/workspace.sql \
  packages/executor/src/executor/workspace_schema.gleam
gleam format packages/executor/src/executor/workspace_schema.gleam
python3 scripts/embed-sql-schema.py packages/executor/sql/resources.sql \
  packages/executor/src/executor/resource_schema.gleam
gleam format packages/executor/src/executor/resource_schema.gleam
python3 scripts/embed-sql-schema.py packages/executor/sql/generations.sql \
  packages/executor/src/executor/generation_registry_schema.gleam
gleam format packages/executor/src/executor/generation_registry_schema.gleam
python3 scripts/embed-sql-schema.py packages/executor/sql/generations_v2.sql \
  packages/executor/src/executor/generation_scope_plan_migration.gleam
gleam format packages/executor/src/executor/generation_scope_plan_migration.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/schema.sql \
  packages/storage/src/storage/sql_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/session.sql \
  packages/storage/src/storage/session_schema.gleam
gleam format packages/storage/src/storage/sql_schema.gleam
gleam format packages/storage/src/storage/session_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_names.sql \
  packages/storage/src/storage/catalogue_names_schema.gleam
gleam format packages/storage/src/storage/catalogue_names_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_archives.sql \
  packages/storage/src/storage/catalogue_archives_schema.gleam
gleam format packages/storage/src/storage/catalogue_archives_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_claims.sql \
  packages/storage/src/storage/catalogue_claims_schema.gleam
gleam format packages/storage/src/storage/catalogue_claims_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_subtitles.sql \
  packages/storage/src/storage/catalogue_subtitles_schema.gleam
gleam format packages/storage/src/storage/catalogue_subtitles_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_credential_kinds.sql \
  packages/storage/src/storage/catalogue_credential_kinds_schema.gleam
gleam format packages/storage/src/storage/catalogue_credential_kinds_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_logins.sql \
  packages/storage/src/storage/catalogue_logins_schema.gleam
gleam format packages/storage/src/storage/catalogue_logins_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_recent_folders.sql \
  packages/storage/src/storage/catalogue_recent_folders_schema.gleam
gleam format packages/storage/src/storage/catalogue_recent_folders_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/owner_custody.sql \
  packages/storage/src/storage/owner_custody_schema.gleam
gleam format packages/storage/src/storage/owner_custody_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_workspace_bindings.sql \
  packages/storage/src/storage/catalogue_workspace_bindings_schema.gleam
gleam format packages/storage/src/storage/catalogue_workspace_bindings_schema.gleam
python3 scripts/embed-sql-schema.py packages/storage/sql/owner_command_offers.sql \
  packages/storage/src/storage/owner_command_offers_schema.gleam
gleam format packages/storage/src/storage/owner_command_offers_schema.gleam
python3 scripts/embed-sql-schema.py packages/executor/sql/lsp_custody.sql \
  packages/executor/src/executor/lsp_custody_schema.gleam
gleam format packages/executor/src/executor/lsp_custody_schema.gleam

python3 scripts/embed-sql-schema.py packages/storage/sql/catalogue_profiles.sql \
  packages/storage/src/storage/catalogue_profiles_schema.gleam
gleam format packages/storage/src/storage/catalogue_profiles_schema.gleam
echo "generated SQL modules are up to date; review and commit the diff"
