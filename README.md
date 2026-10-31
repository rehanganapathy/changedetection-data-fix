# changedetection.io: why watches and fields disappear, and the fix

Ersatzteilstore skill test, by Rehan Ganapathy.

## TL;DR

The data is not being lost by the storage layer. Version 0.55.8 writes every change to disk immediately
(I verified it survives even `kill -9`). The watches disappear because **they get deleted**:

1. **The instance is public and has no password.** `https://ersatzteil-store.ch` opens the full admin UI to anyone.
2. **In 0.55.8 many destructive actions are plain GET links**, with only a JavaScript "are you sure?" popup in front:
   `/delete?uuid=…`, `/tags/delete/…`, `/settings/toggle-all-paused`, `/settings/toggle-all-muted`,
   `/settings/reset-api-key`, `/?op=pause&uuid=…`. Any crawler, SEO bot, link-preview bot or uptime checker that
   follows links deletes every watch it finds. No hacking needed, just "visiting" the site.
3. **Possible second cause (please check on the server):** the official image has no `VOLUME` for `/datastore`.
   If the container was started without `-v …:/datastore`, all data lives in the container layer and is wiped on
   every re-create (image update, `docker compose up` with a new image, Portainer/Watchtower redeploy).

Evidence from the live instance today: scheduling is globally **paused** and notifications globally **muted**,
and the remaining watches are unrelated LinkedIn/Facebook URLs. That is exactly the end state my crawler
reproduction leaves behind (see below).

## Reproduction (local, takes ~30 s)

```bash
./repro/run_local_demo.sh
```

| Scenario | What a link-following crawler does |
|---|---|
| 0.55.8, no password (production today) | deletes **all** watches and groups, pauses + mutes everything, rotates the API key |
| Same data upgraded to 0.60.10 | nothing changes, all fields intact (destructive actions are now POST + CSRF) |
| 0.55.8 with a password | only sees the login page, nothing changes |

`repro/crawler_repro.py` is a 60-line crawler that only does GET requests on same-origin links.
**Run it only against your own test instance.**

## The fix

`docker-compose.yml` in this repo:

- **Upgrade to 0.60.10 (pinned).** Upstream fixed the GET/CSRF issue in 0.60.1
  (advisory GHSA-3v57-xv5m-v7m7, upstream commit `89a41c0d`).
  Schema migration is automatic and makes a tarball backup first.
- **Password via `SALTED_PASS`**: lives in `.env`, cannot be removed from the web UI, survives restores.
- **App not published on the host**; only Caddy (HTTPS, `robots.txt: Disallow /`, `X-Robots-Tag`) can reach it.
- **Named volume** `changedetection-data` with a fixed name + `FORCE_FSYNC_DATA_IS_CRITICAL=true`.
- **Nightly backups** of the volume to `./backups` (14 kept).

### Rollout on the server

```bash
git clone <this repo> && cd <repo>
cp .env.example .env
python3 scripts/make_salted_pass.py          # paste output into SALTED_PASS in .env
./scripts/migrate_existing_data.sh <old-container-name>   # copies current data into the volume first
docker compose up -d
./scripts/verify_persistence.sh              # re-create, kill -9, crawler: fields must survive all three
```

`migrate_existing_data.sh` also prints the old container's mounts. If it prints nothing, cause 3 was active too.

## Upstream contribution

The volume problem is silent in upstream too, so I prepared a patch (`upstream-pr/`) that logs a critical
warning at startup and shows a banner in the UI when `/datastore` is not on a volume. 9 unit tests,
the existing unit suite passes.

## Tested

- 0.55.8 persistence under normal restart and `kill -9`: data kept (code writes `watch.json` atomically on every save).
- Crawler reproduction on 0.55.8: all data deleted. On 0.60.10 and on 0.55.8 + password: nothing lost.
- `docker compose config` validates. The stack was not started here because my sandbox blocks image registries,
  so please run `verify_persistence.sh` once after deploying.
