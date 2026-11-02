#!/usr/bin/env bash
# Move the data of the CURRENT changedetection.io container into the persistent
# named volume used by docker-compose.yml, BEFORE the old container is removed.
#
# Why: if the old container was started without a volume, its watches live only in
# that container's writable layer. Removing/recreating it would delete them.
#
# Usage:  ./scripts/migrate_existing_data.sh <old-container-name-or-id>
set -euo pipefail

OLD="${1:?usage: $0 <old-container-name-or-id>}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESCUE="rescue-$STAMP"
VOLUME="changedetection-data"
RENAMED="${OLD}-old-${STAMP}"

echo "== Mounts of $OLD (empty means: data is ONLY inside the container):"
docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$OLD"

echo "== Stopping $OLD first, so nothing changes while we copy"
docker stop "$OLD" >/dev/null

echo "== Copying /datastore out of $OLD into ./$RESCUE"
docker cp "$OLD:/datastore" "./$RESCUE"
tar czf "$RESCUE.tgz" -C "$RESCUE" .
echo "   Safety copy: $RESCUE.tgz ($(du -sh "$RESCUE.tgz" | cut -f1))"
echo "   Watches found: $(find "$RESCUE" -mindepth 2 -maxdepth 2 -name watch.json | wc -l)"

echo "== Renaming $OLD -> $RENAMED (kept for rollback; frees the name for docker compose)"
docker rename "$OLD" "$RENAMED"

echo "== Loading the data into volume '$VOLUME'"
docker volume create "$VOLUME" >/dev/null
docker run --rm -v "$VOLUME":/datastore -v "$(pwd)/$RESCUE":/rescue:ro alpine:3.20 \
  sh -c 'cp -a /rescue/. /datastore/ && ls /datastore | head'

echo "== Done. Now run:  docker compose up -d"
echo "   Rollback:          docker compose down && docker rename $RENAMED $OLD && docker start $OLD"
echo "   When all is good:  docker rm $RENAMED"
