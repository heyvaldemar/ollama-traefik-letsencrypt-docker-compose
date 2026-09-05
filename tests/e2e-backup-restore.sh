#!/bin/bash
# End-to-end tests for the ollama-traefik-letsencrypt-docker-compose backup + restore flow.
#
# Requires: docker, docker compose. Assumes the stack is already up with
# short backup intervals in .env (CI uses INIT_SLEEP=15s, INTERVAL=60s).
#
# Run from the repository root:
#   ./tests/e2e-backup-restore.sh
#
# The restore scenario stops the application briefly and writes into its
# data directory: run this on a staging copy, not on production.
#
# Tests and helpers are dispatched indirectly via run_test "$name"; shellcheck
# cannot trace that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ollama}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-ollama-traefik-letsencrypt-docker-compose.yml}"

if [[ -f .env ]]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
else
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  exit 1
fi

: "${OPEN_WEBUI_BACKUPS_PATH:=/srv/open-webui/backups}"
: "${OPEN_WEBUI_BACKUP_NAME:=open-webui-database-backup}"
: "${OPEN_WEBUI_DATA_BACKUP_NAME:=open-webui-data-backup}"
: "${OPEN_WEBUI_BACKUP_INTERVAL:=24h}"

BACKUPS_PATH="${OPEN_WEBUI_BACKUPS_PATH%/}"
DB_PREFIX="${OPEN_WEBUI_BACKUP_NAME}"
DATA_PREFIX="${OPEN_WEBUI_DATA_BACKUP_NAME}"
INTERVAL="${OPEN_WEBUI_BACKUP_INTERVAL}"
DB_FILE="webui.db"
DB_BASE="webui"

# Note: never `grep -q` on a docker logs pipe here - with pipefail, grep
# exiting early sends docker logs a SIGPIPE and the whole pipeline fails.

BACKUPS_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq backups | head -n 1)"
APP_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq webui | head -n 1)"
[[ -n "$BACKUPS_CONTAINER" ]] || { echo "error: backups container not found" >&2; exit 1; }
[[ -n "$APP_CONTAINER" ]] || { echo "error: application container not found" >&2; exit 1; }

interval_seconds() {
  local v="$INTERVAL"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}
CYCLE_WAIT=$(( $(interval_seconds) + 60 ))

PASSED=0
FAILED=0
FAILURES=()

run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}

fail() {
  echo "  ASSERT: $*" >&2
  return 1
}

backups_sh() {
  docker exec "$BACKUPS_CONTAINER" sh -c "$1"
}

# python in the backups container is the only SQLite client this stack has
db_query() {
  docker exec "$BACKUPS_CONTAINER" python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1], timeout=30); r=c.execute(sys.argv[2]).fetchall(); c.commit(); print(r[0][0] if r and r[0] else '')" "/data/$DB_FILE" "$1"
}

list_data_backups() {
  backups_sh "ls -1 ${BACKUPS_PATH}/${DATA_PREFIX}-*.tar.gz 2>/dev/null" | sort || true
}

# first backup set (data archive) taken after the marker existed
post_marker_backup() {
  local f elapsed=0
  while :; do
    f=$(backups_sh "find ${BACKUPS_PATH} -name '${DATA_PREFIX}-*.tar.gz' -newer ${BACKUPS_PATH}/.e2e-marker-stamp 2>/dev/null | sort | head -1")
    # complete only once the loop has logged it - the file appears when tar starts
    if [[ -n "$f" ]] && docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -F "Data backup OK: $f" > /dev/null; then echo "$f"; return 0; fi
    [[ $elapsed -lt $CYCLE_WAIT ]] || return 1
    sleep 5; elapsed=$((elapsed + 5))
  done
}

# --- Test cases ---

test_env_required() {
  mv .env .env.bak
  local out
  out=$(env -i PATH="$PATH" HOME="$HOME" docker compose -f "$DOCKER_COMPOSE_FILE" config 2>&1 || true)
  mv .env.bak .env
  echo "$out" | grep -qiE "set in \.env|required|is not set" && return 0
  fail "expected a required-variable error from docker compose config"
}

test_backup_created() {
  echo "  waiting up to ${CYCLE_WAIT}s for a backup set after the marker..."
  local first size
  first=$(post_marker_backup) || { fail "no backup set within ${CYCLE_WAIT}s"; return 1; }
  size=$(backups_sh "stat -c %s $first" | tr -d '[:space:]')
  [[ -n "$size" && "$size" -gt 0 ]] || { fail "archive $first has size '$size'"; return 1; }
  echo "  data archive: $first ($size bytes)"
}

test_data_archive_valid() {
  # the archive named in the newest 'Data backup OK' line is complete by definition
  local f
  f=$(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep "Data backup OK" | tail -1 | sed -E 's/.*Data backup OK: ([^ ]+) .*/\1/')
  [[ -n "$f" ]] || { fail "no 'Data backup OK' line"; return 1; }
  backups_sh "tar -tzf $f > /dev/null" || { fail "tar -tzf failed on $f"; return 1; }
}

test_database_copy_valid() {
  # the copy taken in the same cycle as the post-marker data archive
  local set stamp copy r
  set=$(post_marker_backup) || { fail "no backup set"; return 1; }
  stamp="${set##*/}"; stamp="${stamp#"${DATA_PREFIX}"-}"; stamp="${stamp%.tar.gz}"
  copy="${BACKUPS_PATH}/${DB_PREFIX}-${DB_BASE}-${stamp}.sqlite3.gz"
  backups_sh "test -f $copy" || { fail "no database copy $copy for the set"; return 1; }
  r=$(backups_sh "gunzip -c $copy > /tmp/e2e-check.db && python3 -c \"import sqlite3; print(sqlite3.connect('/tmp/e2e-check.db').execute('pragma integrity_check').fetchone()[0])\"")
  [[ "$r" == "ok" ]] || { fail "integrity_check on $copy: $r"; return 1; }
  echo "  database copy passes integrity_check: $copy"
}

test_backup_failure_detected() {
  # The sidecar runs as root, so permissions cannot stop it. Occupy the
  # names the next few cycles will WRITE TO with directories: tar cannot
  # write into a directory, so the loop must log FAILED. The write target is
  # <archive>.partial, not the archive itself — the loop only renames to the
  # final name once the write succeeded, so occupying the final name proves
  # nothing: tar would write the partial file happily and the rename would
  # move it inside the directory, reporting success. Then clean up.
  echo "  occupying the next archive names with directories to force a failed cycle"
  local i stamp now
  now=$(backups_sh "date +%s")
  for i in 0 1 2 3; do
    stamp=$(backups_sh "date -d @$(( now + i * 60 )) +%Y-%m-%d_%H-%M")
    backups_sh "mkdir -p ${BACKUPS_PATH}/${DATA_PREFIX}-${stamp}.tar.gz.partial"
  done
  echo "  waiting ${CYCLE_WAIT}s for the failed cycle..."
  sleep "$CYCLE_WAIT"
  backups_sh "find ${BACKUPS_PATH} -maxdepth 1 -type d \\( -name '${DATA_PREFIX}-*.tar.gz' -o -name '${DATA_PREFIX}-*.tar.gz.partial' -o -name '${DATA_PREFIX}-*.tar.gz.failed' \\) -exec rm -rf {} +"
  docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -i "backup FAILED" > /dev/null || { fail "expected a 'backup FAILED' log line"; return 1; }
}

test_restore_roundtrip() {
  # Insert a marker row after the baseline set, restore the baseline copy
  # over the live database with the application stopped, assert it is gone.
  local set stamp copy before
  set=$(post_marker_backup) || { fail "no baseline set"; return 1; }
  stamp="${set##*/}"; stamp="${stamp#"${DATA_PREFIX}"-}"; stamp="${stamp%.tar.gz}"
  copy="${BACKUPS_PATH}/${DB_PREFIX}-${DB_BASE}-${stamp}.sqlite3.gz"
  echo "  baseline copy: $copy"
  db_query "CREATE TABLE IF NOT EXISTS restore_test (id INTEGER)" > /dev/null
  db_query "INSERT INTO restore_test VALUES (1)" > /dev/null
  before=$(db_query "SELECT count(*) FROM restore_test")
  [[ "$before" -ge 1 ]] || { fail "marker insert failed: count=$before"; return 1; }
  echo "  stopping the application, restoring the copy"
  docker stop "$APP_CONTAINER" > /dev/null
  backups_sh "rm -f /data/$DB_FILE /data/$DB_FILE-wal /data/$DB_FILE-shm && gunzip -c $copy > /data/$DB_FILE" || { docker start "$APP_CONTAINER" > /dev/null; fail "restore commands failed"; return 1; }
  docker start "$APP_CONTAINER" > /dev/null
  local exists
  exists=$(db_query "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='restore_test'")
  [[ "$exists" == "0" ]] || { fail "restore_test still present after restore - restore was a no-op"; return 1; }
  echo "  marker absent after restore - the copy is restorable"
}

test_prune_removes_old() {
  local fake_old="${BACKUPS_PATH}/${DATA_PREFIX}-0000-00-00_00-00.tar.gz"
  echo "  placing a fake file dated 2020 at $fake_old"
  backups_sh "echo fake > $fake_old && touch -t 202001010000 $fake_old" || { fail "could not create the fake file"; return 1; }
  echo "  waiting ${CYCLE_WAIT}s for the next prune cycle..."
  sleep "$CYCLE_WAIT"
  if backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; then fail "fake old file survived the prune cycle"; return 1; fi
  [[ -n "$(list_data_backups)" ]] || { fail "prune removed everything, including recent backups"; return 1; }
}

# --- Main ---

echo "=== open-webui: backup/restore E2E tests ==="
echo "  project=${COMPOSE_PROJECT_NAME} backups=${BACKUPS_CONTAINER} app=${APP_CONTAINER}"
echo "  path=${BACKUPS_PATH} interval=${INTERVAL}"

# the application creates its database on first start - wait for it
elapsed=0
until backups_sh "test -f /data/$DB_FILE"; do
  [[ $elapsed -lt 180 ]] || { echo "error: /data/$DB_FILE did not appear within 180s" >&2; exit 1; }
  sleep 3; elapsed=$((elapsed + 3))
done
db_query "CREATE TABLE IF NOT EXISTS e2e_marker (id INTEGER PRIMARY KEY)" > /dev/null
backups_sh "touch ${BACKUPS_PATH}/.e2e-marker-stamp"

run_test test_env_required
run_test test_backup_created
run_test test_data_archive_valid
run_test test_database_copy_valid
run_test test_backup_failure_detected
run_test test_restore_roundtrip
run_test test_prune_removes_old

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
