# Upstream contribution guide

## 0. What is and is not worth contributing

| Finding | Upstream status | Action |
|---|---|---|
| Destructive actions on GET links (a crawler wipes data) | **Already fixed** in 0.60.1 (advisory GHSA-3v57-xv5m-v7m7, commit `89a41c0d`, Aug 2026). | **No PR.** But comment on discussion #4133 (below): a user on 0.55.1 behind Caddy reported exactly this symptom and it was never explained. |
| Datastore silently in the container layer when no volume is mounted | Not handled anywhere (checked master `7a925eb5`). | **PR** (patch in `upstream-pr/`). |

## 1. Comment on discussion #4133 (do this first, 5 minutes)

https://github.com/dgtlmoon/changedetection.io/discussions/4133 ("watches vanish as if deleted", 0.55.1, Caddy
in front, opened May 2026, no root cause found).

Suggested comment:

```markdown
I hit the same symptom on a self-hosted 0.55.8 and found the cause there; it may explain this one too.

Before 0.60.1, several destructive actions were plain GET links guarded only by a JS confirm:
`/delete?uuid=…`, `/tags/delete/<uuid>`, `/settings/toggle-all-paused`, `/settings/toggle-all-muted`,
`/settings/reset-api-key`, `/?op=pause|mute`. If the instance is reachable without a password, any
crawler or link-preview bot that follows links deletes every watch it sees. A 60-line GET-only crawler
reproduces it locally on 0.55.8 (all watches deleted, everything paused and muted). On 0.60.x the same
crawl changes nothing, since these are now POST + CSRF (GHSA-3v57-xv5m-v7m7).

@oms0401 a quick way to check: the container log records the requests, so
`docker logs <container> 2>&1 | grep -E 'GET /(delete\?|tags/delete)'`
(or the same grep on Caddy's access log, which also shows the User-Agent) should show the deletions if
this is it. Fix: upgrade to >= 0.60.1 and set a password (or `SALTED_PASS`).
```

Before posting: run `./repro/run_local_demo.sh` yourself so you've seen it with your own eyes, and
check nobody has already answered in the thread.

## 2. The PR: what the change does (be able to explain every line)

Files (all in `upstream-pr/0001-*.patch`):

- `changedetectionio/datastore_checks.py` (new)
  - `in_container()`: true if `/.dockerenv` (Docker) or `/run/.containerenv` (Podman) exists.
  - `parse_mountinfo()`: reads `/proc/self/mountinfo` lines into `(mount_point, fstype)`. Field 5 is the mount
    point, the first field after ` - ` is the fs type. Octal escapes (`\040` = space) are decoded.
  - `mount_for_path()`: longest mount point that prefixes the datastore path (so `/datastore2` does not match
    `/datastore`).
  - `datastore_storage_warning()`: if we're in a container and the datastore sits on `/` with an overlay-type
    fs, return a warning string, else `None`. Opt-out: `DISABLE_DATASTORE_STORAGE_CHECK=true`.
- `changedetectionio/__init__.py`: calls the check in `main()` right after the datastore dir is ensured, logs
  `CRITICAL: DATA LOSS RISK: …`, stores the message in `app_config`.
- `changedetectionio/flask_app.py`: a `context_processor` exposing `datastore_storage_warning` to templates.
- `changedetectionio/templates/base.html`: red banner above flash messages, text wrapped in `_()` for i18n.
- `changedetectionio/tests/unit/test_datastore_storage_check.py`: 9 tests with real-shaped mountinfo samples.

Why mountinfo and not `os.path.ismount('/datastore')`: `ismount` misses a datastore that is a sub-directory of a
bind mount (`-v /srv/data:/data`, `-d /data/changedetection`) and can't tell an overlay root from a real disk.

Likely review questions and answers:
- *Why not add `VOLUME /datastore` to the Dockerfile?* That creates an anonymous volume, which also gets lost
  on `docker rm` / compose re-create with a new project name, and it changes behaviour for existing users.
  A warning is zero-risk.
- *False positives?* Only fires inside a container, only for overlay/aufs roots. Kubernetes emptyDir or a
  PVC is not on the overlay root, so no warning. Opt-out env var for anything else.
- *Windows/macOS?* No `/proc/self/mountinfo` and no container marker, returns `None`.

## 3. Opening the PR

```bash
# Fork dgtlmoon/changedetection.io on GitHub, then:
git clone https://github.com/rehanganapathy/changedetection.io && cd changedetection.io
git remote add upstream https://github.com/dgtlmoon/changedetection.io
git fetch upstream && git checkout -b datastore-ephemeral-storage-warning upstream/master
git am /path/to/ersatzteil-fix/upstream-pr/0001-*.patch     # if it conflicts: git am --3way

python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
cd changedetectionio
pytest tests/unit/test_datastore_storage_check.py   # 9 passed
pytest tests/unit                                     # test_default_timezone_not_overridden also fails on clean master

# Real Docker check, screenshot both for the PR
cd .. && docker build -t cd-warning-test .
docker run --rm -p 5000:5000 cd-warning-test                       # banner + CRITICAL log line
docker run --rm -p 5000:5000 -v cdtest:/datastore cd-warning-test  # no banner

git push -u origin datastore-ephemeral-storage-warning
```

Title: `Warn at startup and in the UI when the datastore is not on a persistent volume`

Description:

```markdown
### Problem
The Docker image has no `VOLUME` for `/datastore`. When a container is started without
`-v …:/datastore` (or a compose/Portainer/Coolify template drops the `volumes:` entry), every watch
and setting is written into the container's writable layer. It works and even survives `docker restart`,
but the next re-create (image update, redeploy) silently discards it. Users see this as watches and
settings randomly disappearing.

### Change
- New `datastore_checks.py`: on Linux, inside a container (`/.dockerenv` or `/run/.containerenv`), read
  `/proc/self/mountinfo` and find the mount the datastore lives on. If that is the overlay root, return a warning.
- `main()` logs it as CRITICAL at startup; a banner in `base.html` shows it in the UI, since most
  self-hosters never read container logs.
- Opt-out: `DISABLE_DATASTORE_STORAGE_CHECK=true`. Read-only, no new dependencies.

### Tests
`tests/unit/test_datastore_storage_check.py`: no volume, named volume, bind mount with escaped path,
sub-directory of a bind mount, outside a container, opt-out, unparseable mountinfo.
Manually: `docker run` without `-v` shows the banner and the log line, with `-v` it does not. [screenshots]

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
