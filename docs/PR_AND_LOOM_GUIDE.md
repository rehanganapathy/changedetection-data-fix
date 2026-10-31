# Upstream PR + Loom: full breakdown

## 0. What is and is not PR-worthy

| Finding | Upstream status | PR? |
|---|---|---|
| Destructive actions on GET links (crawler wipes data) | **Already fixed** in 0.60.1, advisory GHSA-3v57-xv5m-v7m7 (Aug 2026). Master has every one of those routes as POST. | **No.** It would be a duplicate. Mention it as "fixed upstream, Ersatzteilstore just needs to upgrade". |
| Datastore silently in the container layer when no volume is mounted | Not handled. Dockerfile has no `VOLUME`, no warning anywhere (checked master `7a925eb5`). | **Yes**, this is the PR. |

Before opening it, search the issue tracker for `volume`, `datastore lost`, `watches disappeared`,
`docker compose down`. If an issue exists, link it in the PR ("Closes #…"). That makes a merge far more likely.

## 1. Understand the change (be able to explain every line)

Files (all in `upstream-pr/0001-*.patch`):

- `changedetectionio/datastore_checks.py` (new)
  - `in_container()`: true if `/.dockerenv` (Docker) or `/run/.containerenv` (Podman) exists.
  - `parse_mountinfo()`: reads `/proc/self/mountinfo` lines → `(mount_point, fstype)`. Field 5 is the mount
    point, the first field after ` - ` is the fs type. Octal escapes (`\040` = space) are decoded.
  - `mount_for_path()`: longest mount point that prefixes the datastore path (so `/datastore2` does not match
    `/datastore`).
  - `datastore_storage_warning()`: if we are in a container and the datastore sits on `/` with an overlay-type
    fs, return a warning string. Otherwise `None`. Opt-out: `DISABLE_DATASTORE_STORAGE_CHECK=true`.
- `changedetectionio/__init__.py`: calls the check in `main()` right after the datastore dir is ensured,
  logs `CRITICAL: DATA LOSS RISK: …`, and stores the message in `app_config`.
- `changedetectionio/flask_app.py`: a `context_processor` exposing `datastore_storage_warning` to templates.
- `changedetectionio/templates/base.html`: red banner above flash messages, text wrapped in `_()` for i18n.
- `changedetectionio/tests/unit/test_datastore_storage_check.py`: 9 tests with real-shaped mountinfo samples
  (no volume, named volume, bind mount with a space, outside container, opt-out, garbage input).

Why mountinfo and not `os.path.ismount('/datastore')`: `ismount` misses the case where the datastore is a
sub-directory of a bind mount (`-v /srv/data:/data`, `-d /data/changedetection`), and it can't tell an overlay
root from a real disk.

## 2. Open the PR

```bash
# 1. Fork dgtlmoon/changedetection.io on GitHub, then:
git clone https://github.com/rehanganapathy/changedetection.io && cd changedetection.io
git remote add upstream https://github.com/dgtlmoon/changedetection.io
git fetch upstream && git checkout -b datastore-ephemeral-storage-warning upstream/master

# 2. Apply the patch (keeps the commit message; author = you)
git am /path/to/ersatzteil-fix/upstream-pr/0001-*.patch
#    If master moved and it doesn't apply: git am --3way, fix conflicts, git am --continue

# 3. Test
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
cd changedetectionio
pytest tests/unit/test_datastore_storage_check.py      # 9 passed
pytest tests/unit                                        # full unit suite
# Note: test_time_extension::test_default_timezone_not_overridden failed for me on pristine master too
# (environment timezone), so it is not caused by this change. Check yours on master before/after.

# 4. Real Docker check (screenshot this for the PR)
docker build -t cd-warning-test ..
docker run --rm -p 5000:5000 cd-warning-test                       # banner + CRITICAL log
docker run --rm -p 5000:5000 -v cdtest:/datastore cd-warning-test  # no banner

# 5. Push and open the PR against dgtlmoon:master
git push -u origin datastore-ephemeral-storage-warning
```

### PR title
`Warn at startup and in the UI when the datastore is not on a persistent volume`

### PR description (paste and adjust)

```markdown
### Problem
The Docker image has no `VOLUME` for `/datastore`. When a container is started without
`-v …:/datastore` (or a compose/Portainer/Coolify template drops the `volumes:` entry), every
watch and setting is written into the container's writable layer. It all works and even survives
`docker restart`, but the next re-create (image update, `docker compose up` with a new image,
Watchtower/redeploy) silently discards it. Users report this as "my watches/settings randomly disappear".

I ran into this while debugging a production instance for a client.

### Change
- New `datastore_checks.py`: on Linux, inside a container (`/.dockerenv` or `/run/.containerenv`),
  read `/proc/self/mountinfo` and find the mount the datastore lives on. If that is the overlay root,
  return a warning.
- `main()` logs it as CRITICAL at startup.
- A banner in `base.html` shows it in the UI (most self-hosters never read container logs).
- Opt-out: `DISABLE_DATASTORE_STORAGE_CHECK=true` (CI, intentionally ephemeral setups).
- No behaviour change otherwise, read-only, no new dependencies.

### Tests
`tests/unit/test_datastore_storage_check.py`: no volume, named volume, bind mount with escaped path,
sub-directory of a bind mount, outside a container, opt-out, unparseable mountinfo.

Manually: `docker run` without `-v` shows the banner and the CRITICAL log line, with `-v` it does not.
[screenshots]
```

## 3. Loom script (target 4 to 5 minutes)

Record with the terminal font large, one browser tab, notifications off.

**0:00 Intro (20 s)**
"Hi Afram, Rehan here. In this video I'll reproduce why your changedetection.io loses watches and fields,
show the fix, and an upstream contribution I prepared."

**0:20 What I noticed first (40 s)**
Open `https://ersatzteil-store.ch` (only look, do not click anything).
"ersatzteil-store.ch is the changedetection.io admin itself, no login. Note: scheduling is globally paused,
notifications muted, and the watches are unrelated LinkedIn/Facebook URLs. Keep that state in mind."

**1:00 Ruling out storage (40 s)**
Show `store/file_saving_datastore.py` → `save_json_atomic` (write temp, `os.replace`).
"0.55.8 writes each watch.json immediately and atomically. I added a watch, killed the process with kill -9,
restarted: data was still there. So the data isn't failing to save, something is deleting it."

**1:40 The bug (60 s)**
Show `blueprint/ui/__init__.py` at 0.55.8: `@route("/delete", methods=['GET'])`, and the delete `<a href>` in
`edit.html` with only a JS confirm.
"Delete, pause, mute, delete group, reset API key are all plain links. A bot that follows links doesn't
run JavaScript, so it clicks all of them."

**2:40 Reproduce (50 s)**
Run `./repro/run_local_demo.sh`, pause on the BEFORE section.
"Three watches before, zero after. And the global settings end up paused and muted: exactly what your
live instance shows right now."

**3:30 Fix (50 s)**
Same script, AFTER A and AFTER B sections. Then `docker-compose.yml` on screen.
"Upstream fixed the GET issue in 0.60.1, so: upgrade pinned to 0.60.10, password via SALTED_PASS, app only
behind Caddy with robots disallow, named volume plus nightly backups. The migrate script copies your current
data into the volume first, and verify_persistence.sh proves it survives re-create, kill -9 and a crawler."

**4:20 Upstream PR (30 s)**
Show the banner screenshot and the PR.
"One thing upstream still doesn't catch: running without a volume. I added a startup warning and UI banner
and opened a PR."

**4:50 Close (10 s)**
"Repo link is in the message. Happy to walk through it live."

Do **not** run the crawler, or click any pause/mute/delete link, on the live ersatzteil-store.ch in the video.
