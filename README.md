# changedetection.io: why watches and fields disappear, and the fix

Ersatzteilstore skill test, by Rehan Ganapathy. Option 1: find the cause and fix it.

## How to test it

| Option | What you see | Needs |
|---|---|---|
| `./repro/run_local_demo.sh` | the bug on 0.55.8 (all watches deleted), then the same data on 0.60.10 / with a password (nothing lost) | Python 3, internet for `pip`, ~1 min |
| `docker compose up -d`, then `./scripts/verify_persistence.sh` | the fixed stack keeps a watch's fields through container re-create and `kill -9` | Docker, a test server or laptop |
| Live demo link (if included in my message) | the fixed stack running: add fields, ask me to restart it, they stay | a browser |

## How I approached it

1. Looked at the link in the task: `ersatzteil-store.ch` opens the changedetection.io admin itself (v0.55.8, no
   login at the time), already showing "scheduling paused" and "notifications muted". I only loaded the start
   page and never clicked anything there.
2. Ruled out storage first: installed the same version, added and edited watches via the UI form and the API,
   killed the process with `kill -9`. Everything survived, so the data is saved. Something must be removing it.
3. Read the 0.55.8 routes: delete, pause, mute, delete group and reset API key are plain GET links.
4. Reproduced it with a small crawler that only follows links: every watch deleted, everything paused and
   muted. The same end state as the live instance.
5. Checked upstream: fixed in 0.60.2. Built and tested a hardened deployment around the current release.

## TL;DR

It is not a saving bug. Version 0.55.8 writes every change to disk immediately, both via the UI form and the API
(tested, including edits made while a check is running, and a hard `kill -9`). The watches disappear because
**they get deleted**:

1. **The instance was public with no password** (as of 31 Oct 2026; a login has been added since).
2. **In 0.55.8 many destructive actions are plain GET links**, with only a JavaScript "are you sure?" popup in front:
   `/delete?uuid=…`, `/tags/delete/…`, `/settings/toggle-all-paused`, `/settings/toggle-all-muted`,
   `/settings/reset-api-key`, `/?op=pause&uuid=…`. Any crawler, SEO bot, link-preview bot or visitor that follows
   links triggers them. Bots don't run JavaScript, so the popup never appears. No hacking needed.
   If the admin link was shared more widely (for example in this task), every person clicking around it, or an
   AI agent browsing it, can trigger them too.
3. **Possible second cause (check on the server):** the official image has no `VOLUME` for `/datastore`.
   If the container was started without `-v …:/datastore`, all data lives in the container layer and is wiped on
   every re-create (image update, `docker compose up` with a new image, Portainer/Watchtower redeploy).

Evidence from the live instance on 31 Oct 2026, before the login was added: scheduling was globally **paused**,
notifications globally **muted**, and the only watches left were social-media profile URLs unrelated to stock
monitoring. That is exactly the end state my crawler reproduction leaves behind (see below).

## Confirm it on your server (1 minute)

The container log records every request, including these (verified on 0.55.8). If this is the cause, the
deletions are in there:

```bash
docker logs <container-name> 2>&1 | grep -E 'GET /(delete\?|tags/delete|settings/(toggle-all|reset-api-key))|op=(pause|mute)'
```

Lines like `"GET /delete?uuid=… HTTP/1.1" 302` from IPs that are not yours confirm it. If you run a reverse proxy
with access logs (nginx/Caddy), grep those too: they also show the bot's User-Agent.
Note: `docker logs` only goes back to when the container was (re)created.

## Now that a login is set

Good: that stops anonymous visitors and crawlers. Upgrading is still needed. On 0.55.8 the session cookie has no
`SameSite` attribute and the server doesn't check where a GET request came from (both verified), so a logged-in
admin who clicks a crafted link (email, chat, any website) deletes data. In browsers that don't default cookies to
`SameSite=Lax`, merely loading a page that embeds `<img src="https://…/delete?uuid=…">` is enough.
From 0.60.2 on, all of these are POST + CSRF token.

## Reproduction (local, takes ~30 s)

```bash
./repro/run_local_demo.sh
```

| Scenario | What a link-following crawler does |
|---|---|
| 0.55.8, no password (production until recently) | deletes **all** watches and groups, pauses + mutes everything, rotates the API key |
| Same data upgraded to 0.60.10 | nothing changes, all fields intact (destructive actions are POST + CSRF) |
| 0.55.8 with a password | only sees the login page, nothing changes |

`repro/crawler_repro.py` is a small (~80 line) crawler that only does GET requests on same-origin links.
**Run it only against your own test instance.**

## The fix

`docker-compose.yml` in this repo:

- **Upgrade to 0.60.10 (pinned, current release).** Upstream made every destructive action POST + CSRF in commit
  `89a41c0d` ("GHSA-3v57-xv5m-v7m7 - Multiple front-end endpoints lacking CSRF protection"), first released in
  0.60.2 (Sep 2026). Upgrading is automatic: the datastore schema migrates on start and a tarball backup is made
  first. Tested: a 0.55.8 datastore upgraded to 0.60.10 keeps every watch and field.
- **Password via `SALTED_PASS`**: lives in `.env`, cannot be removed from the web UI, survives restores.
  The API keeps working with its key.
- **App not published on the host**; only Caddy (HTTPS, `robots.txt: Disallow /`, `X-Robots-Tag`) can reach it.
- **Named volume** `changedetection-data` with a fixed name + `FORCE_FSYNC_DATA_IS_CRITICAL=true`.
- **Daily backups** of the volume to `./backups` (one at start-up, then every 24 h, newest 14 kept).

### Rollout on the server

```bash
git clone <this repo> && cd <repo>
cp .env.example .env
python3 scripts/make_salted_pass.py          # paste output into SALTED_PASS in .env
./scripts/migrate_existing_data.sh <old-container-name>   # stops, copies data into the volume, renames old container
docker compose up -d
./scripts/verify_persistence.sh              # re-create + kill -9: fields must survive both
```

- `migrate_existing_data.sh` prints the old container's mounts first. If it prints nothing, cause 3 was active too.
  It keeps the old container (renamed) and a `rescue-*.tgz`, and prints the rollback command.
- **Already running nginx/Traefik/another proxy on ports 80/443?** Remove the `caddy` service and point your
  proxy at the container instead (add `ports: ["127.0.0.1:5000:5000"]` to `changedetection`).
- `DOMAIN=your.host ./scripts/verify_persistence.sh` also runs the crawler against your instance after the
  upgrade, to show it can no longer change anything.

## Upstream contribution

- The volume problem is silent upstream too, so I prepared a patch (`upstream-pr/`) that logs a critical warning at
  startup and shows a banner in the UI when `/datastore` is not on a volume. 9 unit tests; applies cleanly to
  current master.
- Upstream discussion #4133 (May 2026, unanswered) reports watches vanishing "as if deleted" on 0.55.1 behind Caddy:
  the same pattern. `docs/UPSTREAM_GUIDE.md` has the explanation to post there.

## Tested

| What | Result |
|---|---|
| 0.55.8: edit fields via the UI form while checks are in flight, then `kill -9` + restart | fields kept |
| 0.55.8: edit via API, `kill -9` + restart | fields kept |
| 0.55.8, no password: link-following crawler | all watches and groups deleted, paused + muted |
| 0.55.8 logged in: cross-site GET `/delete` | watch deleted (no SameSite, no origin check) |
| 0.55.8 data upgraded to 0.60.10, same crawler | nothing changed |
| 0.60.10 with `SALTED_PASS`: crawler / API key | login page only / API works |
| `verify_persistence.sh` against 0.60.10 | create, re-create, kill -9: all pass |
| Backup loop, migrate script (with a recording docker stand-in) | correct file names, retention 14, correct order |
| `docker compose config` | valid |
| Full stack via `docker compose up -d` (real images, Docker 29.8 / Compose 5.5) | all 3 containers up, app reports healthy |
| `verify_persistence.sh` on the full stack, incl. crawler through Caddy HTTPS | create, re-create, kill -9, anonymous crawler: all pass |
| `docker compose down` + `up -d` with a watch saved | watch and filters kept (named volume) |
| Caddy | HTTPS works, `/` redirects to the login page, `robots.txt` disallows everything, `X-Robots-Tag` + HSTS sent |
| Backup container | tarball written at start-up |

Tested locally with `DOMAIN=localhost`. On your server, run `verify_persistence.sh` once after deploying.
