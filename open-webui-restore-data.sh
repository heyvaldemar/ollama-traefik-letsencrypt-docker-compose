#!/usr/bin/env bash
# open-webui-restore-data.sh [timestamp]
#
# Replaces Open WebUI's data with one backup set: the data archive and, for each
# SQLite database, the consistent copy the backups service took beside it.
#
#   ./open-webui-restore-data.sh                      list the sets and ask
#   ./open-webui-restore-data.sh YYYY-MM-DD_hh-mm     restore that one
#
# EVERY PATH AND NAME COMES FROM THE RUNNING BACKUPS CONTAINER. The previous
# version carried the compose project, the backup directory and both backup
# names as literals, so any of them set differently in .env pointed it at
# nothing, and it unpacked the archive over the live data: tar does not delete,
# so files created after the backup survived the restore. The end-to-end test
# did the clearing itself, which is how it passed while the script merged.
#
# WHAT THE ARCHIVE LEAVES OUT ON PURPOSE IS KEPT. The loop excludes cache
# from the archive; those are set aside, the rest is cleared and unpacked, and
# they are put back.
#
# CI runs this exact file.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than ollama.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-ollama}"
STOP_SERVICES="webui"                   # every service that writes what is restored
ROOT="/data"                            # where the archive unpacks
PARTS="."                          # what it holds, relative to ROOT
KEEP="cache"                            # what it leaves out on purpose, relative to ROOT
DBS="webui.db"                              # SQLite files in /data, restored from their copies

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
BKP="$(cid backups)"
[ -n "$BKP" ] || { echo "error: no backups container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }
APPS=""
for s in $STOP_SERVICES; do
  c="$(cid "$s")"; [ -n "$c" ] || { echo "error: no $s container in compose project '$PROJECT'" >&2; exit 1; }
  APPS="$APPS $c"
done

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of OPEN_WEBUI_BACKUPS_PATH)"; DATA_NAME="$(env_of OPEN_WEBUI_DATA_BACKUP_NAME)"
DB_NAME=""; [ -z "$DBS" ] || DB_NAME="$(env_of OPEN_WEBUI_BACKUP_NAME)"

STAMP="${1:-}"
if [ -z "$STAMP" ]; then
  echo "Backup sets in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$DATA_NAME-.*\\.tar\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "Timestamp of the set to restore (YYYY-MM-DD_hh-mm): " STAMP
fi
case "$STAMP" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "error: '$STAMP' is not a timestamp like 2026-01-31_04-00" >&2; exit 1 ;;
esac
ARCHIVE="$DIR/$DATA_NAME-$STAMP.tar.gz"
docker exec "$BKP" tar -tzf "$ARCHIVE" > /dev/null \
  || { echo "error: $ARCHIVE is missing or does not open; nothing was changed" >&2; exit 1; }
for db in $DBS; do
  docker exec "$BKP" gunzip -t "$DIR/$DB_NAME-${db%%.*}-$STAMP.sqlite3.gz" \
    || { echo "error: the copy of $db for $STAMP is missing or does not open; nothing was changed" >&2; exit 1; }
done

echo "Stopping $STOP_SERVICES so nothing writes while the data is replaced"
# shellcheck disable=SC2086
docker stop $APPS > /dev/null
# shellcheck disable=SC2086
restart() { docker start $APPS > /dev/null && echo "Started $STOP_SERVICES"; }
trap 'restart' EXIT

echo "Restoring the set $STAMP"
if ! docker exec "$BKP" sh -c "set -eu
    cd '$ROOT'
    rm -rf /tmp/restore-keep; mkdir -p /tmp/restore-keep
    for p in $KEEP; do
      [ -e \"\$p\" ] || continue
      mkdir -p \"/tmp/restore-keep/\$(dirname \"\$p\")\"; mv \"\$p\" \"/tmp/restore-keep/\$p\"
    done
    for part in $PARTS; do find \"\$part\" -mindepth 1 -delete; done
    tar -xzpf '$ARCHIVE' -C '$ROOT'
    cp -a /tmp/restore-keep/. '$ROOT'/
    rm -rf /tmp/restore-keep
    owner=\$(stat -c %u:%g /data)
    for db in $DBS; do
      rm -f \"/data/\$db\" \"/data/\$db-wal\" \"/data/\$db-shm\"
      gunzip -c \"$DIR/$DB_NAME-\${db%%.*}-$STAMP.sqlite3.gz\" > \"/data/\$db\"
      chown \"\$owner\" \"/data/\$db\"
    done"; then
  echo "error: the restore failed part-way; the data may be incomplete. Restore another set before using Open WebUI." >&2
  exit 1
fi
echo "Restored the set $STAMP"
