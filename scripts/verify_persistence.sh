#!/usr/bin/env bash
# Proves the stack keeps data across the events that used to lose it.
# Run from the repo root after `docker compose up -d`.
#
#   ./scripts/verify_persistence.sh
#
# 1. adds a watch with custom fields through the API
# 2. force-recreates the container (what an image update / redeploy does)
# 3. kills it hard (power loss / OOM)
# 4. runs a link-following crawler as an anonymous visitor
# and checks after every step that the watch and its fields are unchanged.
set -euo pipefail
C=changedetection

api_key() { docker exec "$C" python3 -c "import json;print(json.load(open('/datastore/changedetection.json'))['settings']['application']['api_access_token'])"; }
api() { docker exec "$C" python3 -c "
import json,sys,urllib.request
req=urllib.request.Request('http://127.0.0.1:5000'+sys.argv[1],method=sys.argv[2],data=(sys.argv[3].encode() if len(sys.argv)>3 else None),headers={'x-api-key':sys.argv[4] if len(sys.argv)>4 else '$(api_key)','content-type':'application/json'})
print(urllib.request.urlopen(req,timeout=20).read().decode())" "$@"; }
wait_up() { for _ in $(seq 60); do docker exec "$C" python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:5000/',timeout=3)" 2>/dev/null && return; sleep 2; done; echo "container did not come up"; exit 1; }
check() {
  local got; got=$(api "/api/v1/watch/$UUID" GET | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['title'],'|',','.join(d['include_filters']))")
  if [ "$got" = "$EXPECT" ]; then echo "  PASS after $1: $got"; else echo "  FAIL after $1: got '$got'"; exit 1; fi
}

wait_up
EXPECT="Persistence test | .stock,.price"
UUID=$(api /api/v1/watch POST '{"url":"https://example.com/persistence-test","title":"Persistence test","include_filters":[".stock",".price"]}' | python3 -c "import sys,json;print(json.load(sys.stdin)['uuid'])")
echo "Created watch $UUID"
check "create"

docker compose up -d --force-recreate changedetection >/dev/null; wait_up; check "container re-create"
docker kill -s KILL "$C" >/dev/null; docker compose up -d changedetection >/dev/null; wait_up; check "kill -9 + start"

if command -v python3 >/dev/null && [ -n "${DOMAIN:-}" ]; then
  python3 repro/crawler_repro.py "https://$DOMAIN" --max-pages 200 >/dev/null 2>&1 || true
  check "anonymous crawler on https://$DOMAIN"
fi

api "/api/v1/watch/$UUID" DELETE >/dev/null
echo "All persistence checks passed (test watch removed)."
