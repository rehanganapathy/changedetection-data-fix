#!/usr/bin/env bash
# Local before/after demo, no Docker needed (good for a screen recording).
#
#   ./repro/run_local_demo.sh
#
# BEFORE: changedetection.io 0.55.8, no password (= the production setup)
#         -> an anonymous crawler deletes every watch, pauses + mutes everything,
#            deletes groups and rotates the API key.
# AFTER A: same 0.55.8 data upgraded to 0.60.10 -> crawler changes nothing, fields intact.
# AFTER B: 0.55.8 with a password (SALTED_PASS)   -> crawler only ever sees the login page.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd); WORK="$ROOT/.demo"; mkdir -p "$WORK"

venv() { # $1=version
  local d="$WORK/venv-$1"
  [ -x "$d/bin/changedetection.io" ] || { python3 -m venv "$d"; "$d/bin/pip" install -q "changedetection.io==$1"; }
  echo "$d/bin/changedetection.io"
}
start() { # $1=bin $2=datastore $3=port [env...]
  local bin=$1 ds=$2 port=$3; shift 3
  env "$@" "$bin" -d "$ds" -p "$port" -h 127.0.0.1 -l WARNING >"$ds.log" 2>&1 & echo $! >"$ds.pid"
  for _ in $(seq 60); do curl -s -o /dev/null "http://127.0.0.1:$port/" && return; sleep 0.5; done
  echo "server on $port did not start"; cat "$ds.log"; exit 1
}
stop() { kill "$(cat "$1.pid")" 2>/dev/null || true; sleep 1; }
token() { python3 -c "import json;print(json.load(open('$1/changedetection.json'))['settings']['application']['api_access_token'])"; }
add_watch() { # $1=port $2=datastore
  curl -s -X POST -H "x-api-key: $(token "$2")" -H 'content-type: application/json' "http://127.0.0.1:$1/api/v1/watch" \
    -d '{"url":"https://example.com/part/4711","title":"Stock: Part 4711","include_filters":[".stock-level",".price"]}' >/dev/null
}
fields() { python3 - "$1" <<'EOF'
import json,glob,sys
for f in sorted(glob.glob(sys.argv[1]+"/*/watch.json")):
    d=json.load(open(f)); print(f"    {d.get('title') or d.get('url')}  filters={d.get('include_filters')}  paused={d.get('paused')}")
EOF
}

V55=$(venv 0.55.8); V60=$(venv 0.60.10)

echo; echo "################ BEFORE: 0.55.8, no password (production setup) ################"
rm -rf "$WORK/before"; mkdir "$WORK/before"
start "$V55" "$WORK/before" 5101; add_watch 5101 "$WORK/before"
echo "  on disk before crawl:"; fields "$WORK/before"
python3 repro/crawler_repro.py http://127.0.0.1:5101 --max-pages 400 | grep -vE "set-language|auto-detect" || true
echo "  on disk after crawl:"; fields "$WORK/before"; echo "    ($(ls -d "$WORK"/before/*/ 2>/dev/null | wc -l) watch/tag dirs left)"
stop "$WORK/before"

echo; echo "################ AFTER A: same data, upgraded to 0.60.10 ################"
rm -rf "$WORK/after" "$WORK/seed"; mkdir "$WORK/seed"
start "$V55" "$WORK/seed" 5102; add_watch 5102 "$WORK/seed"; stop "$WORK/seed"
cp -a "$WORK/seed" "$WORK/after"
start "$V60" "$WORK/after" 5103
python3 repro/crawler_repro.py http://127.0.0.1:5103 --max-pages 400 | grep -vE "set-language|auto-detect" || true
echo "  on disk after upgrade + crawl:"; fields "$WORK/after"
stop "$WORK/after"

echo; echo "################ AFTER B: 0.55.8 with SALTED_PASS ################"
rm -rf "$WORK/pass"; cp -a "$WORK/seed" "$WORK/pass"
start "$V55" "$WORK/pass" 5104 SALTED_PASS="$(python3 scripts/make_salted_pass.py 'demo-password-123')"
python3 repro/crawler_repro.py http://127.0.0.1:5104 --max-pages 400 | grep -vE "set-language|auto-detect" || true
echo "  on disk after crawl:"; fields "$WORK/pass"
stop "$WORK/pass"
