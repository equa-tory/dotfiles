# What's next

One file. Four sections: do these now, your services (fill in as you go),
the bigger plan (tick what you actually want), and later-maybe with real
numbers so each is a one-line decision. Nothing in here runs itself —
every command is yours to run and report back on.

A copy of this file lives at `/@/NEXT.md` too, refreshed automatically
every time you run `srv push` — edit the one in git, not the copy.

---

## 1. Do these now

### 1.1 Enable xray at boot (1 min)
`xray.service` is running but **disabled** — it was started by hand and
won't come back after a reboot. frp's proxy route depends on it (socks
`:1080`), so a reboot silently drops your VPS tunnel too, not just the
proxy.

```bash
sudo systemctl enable xray
```

Tell me: "xray enabled".

### 1.2 shutter's secrets are world-readable — fix regardless of backups
`/etc/systemd/system/shutter.service` is mode `0644` and has your iLO
password + shutter token hardcoded as `Environment=` lines, readable by
any local user. The `.env` file next to `shutter.py` is correctly locked
down (`chmod 600`) but systemd's `Environment=` wins over it, so the
world-readable copy is the one actually in effect right now.

```bash
sudo chmod 600 /etc/systemd/system/shutter.service
```
That alone doesn't fully fix it — the values are still hardcoded in the
unit, just no longer world-readable. The real fix is moving those 4
`Environment=` lines out of the unit and into an `EnvironmentFile=`
pointing at the existing `.env` (which is already correctly 0600), then
`sudo systemctl daemon-reload && sudo systemctl restart shutter`.

Tell me: "shutter secrets fixed" — or if you want me to write the exact
unit-file diff for this, ask and I will (not applying it myself, per the
standing rule on live configs).

### 1.3 Pick one service and reinstall it by hand
The whole point of this session: **do one reinstall manually before we
automate anything.** Pick anything from the table below — a small one
(`mus`, `silly`, `shutter`) is the easiest first try. Use the "worth
keeping" column as your checklist of what to actually preserve.

Tell me: which service, what you did, and what was annoying or confusing
about it. That's the raw material for whatever gets automated later.

---

## 2. Your services

What each one needs if you rebuild it. Corrected against the real box
2026-09-09 — sizes/paths below were checked live, not carried over from an
earlier session. The third column is yours to edit as you actually go
through reinstalls.

| service | lives in | worth keeping if you rebuild |
|---|---|---|
| comfyui | `~/git/ComfyUI` (134G) | `custom_nodes/` 225M — **copy as files**, only 4 of 16 are git repos (Gallery, Manager, Crystools, lora-manager and 7 more are hand-installed, not clonable); `user/default/workflows/` + `user/comfyui.db` (18M total). `output/` is empty — real output goes to `/@/Media_SRV/Photo` (205M, set in `comfyui.service`), back that up too. `models/loras` 109G + `checkpoints` 12G are re-downloadable, just note which you use |
| ollama | `/mnt/ssd/ai/ollama` (73G) | just the model names — 7 models: `qwen3-coder-next` (51.7G, unused since Jun 12 — maybe don't re-pull), `gemma2:9b`, `qwen3:8b`, `fluffy/l3-8b-stheno-v3.2`, `qwen2.5-coder:7b`, `qwen3-vl:4b`, `llama3.2:3b`. Gated behind `ollama-api` (a root toggle service) — its secrets file `/etc/ollama-toggle.env` isn't captured anywhere yet |
| booru | `~/git/booru` (879M, but 678M of that is 2 duplicate copies — see §3) | **DB is `db.sqlite3`, not `db.sqlite`** (103M) + real media at `/mnt/ssd/Media_SSD/Photo` (**260G**, on a disk with only 32G free). Code on GitHub (`equa-tory/booru`), no unpushed commits, but **13 uncommitted files including 2 real migrations** — those only exist on this disk right now |
| booru-main | `~/git/booru-main` (339M) + a 3rd nested copy at `~/git/booru/booru-main` | **duplicate** of booru, same remote/commit, stub DB — safe to delete both copies |
| homeflix | `~/git/homeflix` (744M) | `db.sqlite3` (1.4M) + `config/` + the app code (`library/` is code, not media). Real video library is `HOMEFLIX_LIBRARY=/mnt/videos/YouTube` — **on the network share, not backupable from this box**. `converted/`+`subtitles/`+`thumbnails/` (662M) are regenerable cache, skip them. **23 uncommitted files** including a whole unpushed auth feature (`library/auth.py`, a migration) — only on this disk |
| mus | `~/git/mus` (617M) | `data/library.db` (316K) + `data/art/` (559M, **entirely untracked in git** — 1086 album art images that exist nowhere else). Real music files at `/@/Media_SRV/Music` (5.9G), outside the repo. Code on GitHub, no unpushed commits |
| silly (SillyTavern) | `~/git/SillyTavern` (738M) | `data/default-user/` (105M: characters/ 37M, chats, settings.json, worlds, groups) + `config.yaml`. Code is pure upstream SillyTavern (zero uncommitted changes) — `node_modules/` (452M) is the only reason this folder is big, rebuilds via `npm install` |
| n8n | `~/git/n8n` (4.7M) | `data/database.sqlite` + `data/config` (the encryption key — without it stored credentials are undecryptable) + `.env` (gitignored, has the login password). ⚠️ `-wal` file is newer than the DB — checkpoint before copying or you lose recent workflow edits. `.git` exists but **has zero commits, ever** — nothing here is backed up anywhere but this disk |
| shutter | `~/git/shutter` (19M, 44K without `venv/`) | the whole folder minus `venv/` (rebuild via `pip install -r requirements.txt`). **No `.git` at all** — zero off-disk copies. ⚠️ see §1.2 — its iLO password is currently in a world-readable systemd unit |
| frp | `~/frp` (50M) | `frpc.toml` (typo already fixed, parses clean) + `frps.toml` (the VPS-side config, also present here) + the `frpc`/`frps` binaries (37M) — real files, nothing to re-download. `frp.service` runs the client half |
| xray | `/usr/local/etc/xray/config.json` | the config shape is in `conf/xray/` (git, placeholders); real UUID/keys regenerate per `conf/SECRETS.md`. See §4 — this session adds saved multi-server support |
| gitea | docker, compose project `mirror` at `/mnt/nas/mirror` | data at `/mnt/nas/mirror/gitea` (4.5G: 2.4G repos + **2.0G attachments, easy to miss** + 176M git-lfs + 12M db). ⚠️ **`gitea.service` (a separate systemd unit doing `docker start -a gitea`) is active+enabled and has never been captured to `conf/systemd/`** — two owners for one container, still unresolved |
| nexus | docker, compose project `mirror` | `db/`+`etc/`+`keystores/` (67M) matter; `blobs/` (16G) is a cache, let it refill |
| pacman-cache | docker, compose project `mirror` | just an nginx:alpine config + the mirror pool itself, nothing to keep beyond the compose file |
| teamspeak-server | docker (manual run) | `ts-data/tsserver.sqlitedb*` (556K) only, not `logs/` (113M and growing — 28,000+ log files). ⚠️ **still crash-looping** (expired TS6 license, unchanged from last session) |
| open-webui | docker (manual run, `--network host`) | named volume `open-webui`, 2.2G, mostly uploaded images |
| uptime-kuma | docker, compose | `kuma.db` (61M). ⚠️ **lives at `/data` on the root filesystem, NOT under `/home/equa`** — a home-scoped backup would silently skip it entirely |
| searxng | docker, compose (`searxng-setup`) | just the compose file, no real data. ⚠️ currently running but functionally broken — zero search results, backend engines can't resolve DNS. Not urgent, just not secretly fine |
| exposcan (cve) | docker, compose (`~/git/cve`) | `data/exposcan.db` (75M) + its own `.env` (**not captured anywhere yet**). 4 uncommitted files, no unpushed commits. `venv/` (83M) appears to be committed into the working tree — check `.gitignore` |
| n8n's Telegram tunnel | `redsocks` (installed, currently inactive) + iptables NAT rules | documented fully in your own `~/n8n-server-setup.md` — not captured to `conf/` yet, worth doing since it's real setup work you'd otherwise redo from memory |
| whisper-ui | `~/git/whisper.cpp`, a uvicorn process on `:8770` with its own frp tunnel | ⚠️ **found running, not documented anywhere before this** — no systemd unit, started some other way. Worth figuring out how it's meant to start before any reinstall plan covers it |
| ilo-api | systemd, failed (Type=oneshot, fires at boot) | nothing to back up — one `curl` call. ⚠️ **the captured copy in `conf/systemd/` is stale** — real endpoint/token differ from what's committed. Fix already written at `vps/notify-boot/`, waiting on your own VPS access |
| danbooru | systemd, disabled | `~/git/danbooru` (109M, upstream clone) — not running, decide if you still want it. Unit not yet captured |
| minecraft | systemd, disabled | ⚠️ **zero backups exist right now** — most exposed item on this list. Core+config (jar+mods+config, no world) ≈ 168M. `server.jar` is only a 176K Fabric stub — `libraries/`+`versions/` (56M) are also needed to actually restore it. World (679M) includes Nether/End as `DIM-1`/`DIM1` inside `world/` — nothing separate to grab |
| minecraft-hrd | systemd, disabled | core+config (jar+plugins+yml/conf, no world) ≈ 317-429M depending on whether you count `plugins/CoreProtect/database.db` (112M runtime log) as config. ⚠️ real main world is `overworld/` (12M), **not** `world/` (4.6M, mostly empty) — a naive `world*` glob backup would grab the wrong/small one. `world_backups/world.tar.gz` is 6.5 months stale (Feb); `fahare-backups/` has 2 newer ones (Apr, ~43M total) |
| mine (miner) | systemd, disabled | `~/miner` (45M) — wallet address is a `-u` argument on the unit's `ExecStart=` line (not an env var), needs templating before any commit. Probably abandoned, decide |
| tagger | systemd, disabled | just a docker image (`ghcr.io/danbooru/autotagger`), no folder, nothing to keep. Unit not captured |
| udp2raw | systemd, disabled | shared key is a `-k` argument on the unit's `ExecStart=` line, same as `mine` — needs templating before any commit. Decide if still needed |

---

## 3. The bigger plan — tick what you actually want

You said, in your own words: move important files to another drive so you
can easily reinstall the OS, install services in a few clicks, restore
configs (config backups on another drive too, tool sees them and copies,
maybe a git private repo for configs too), and after reinstalling OS +
services + configs everything works again. Below is that goal broken into
the 4 pieces you named, as checkboxes — tick or edit, nothing under here
gets built until you've gone through it.

### Move important files off the root disk / ssd
- [ ] decide where the 3TB lands once it's attached — **no such disk exists
      on this box yet**, confirmed via `lsblk`; it needs adding at the
      ESXi level first (see Part 2 above for the full placement plan)
- [ ] comfyui models (125G, currently on the root disk `/`) → 3TB, once it exists
- [ ] booru media (260G, on `/mnt/ssd` which is **92% full, 32G free**) →
      needs somewhere with room before it grows further, not after
- [ ] photos at `/mnt/ssd/Media_SSD/Photo` (260G) → same disk, same problem

### Install a service "in a few clicks"
- [ ] pick the shape: one recipe file per app (like the old `apps/*.app`
      format from before the strip-down) vs. just good-enough notes in
      this file's §2 that you follow by hand
- [ ] test this manually on ONE service first (your own words, §1.3) —
      before any of it becomes a script

### Config backups on another drive, tool sees them
- [ ] `conf/` (in this git repo) already IS a config backup, today — it's
      just missing 5 real unit files (`gitea`/`mine`/`tagger`/`danbooru`/
      `udp2raw`) and 3 captured copies are stale (`ilo-api`, `homeflix`,
      `shutter`, plus `.bashrc`) — see the ⚠️ marks in §2 above
- [ ] decide: should `srv conf capture` also write a second copy to
      `/mnt/nas` or the 3TB once it exists, alongside the git copy — so
      there's a local copy even if GitHub is unreachable?
- [ ] "tool sees them and just copies" — clarify which you mean: (a)
      detecting configs that changed on disk and re-capturing
      automatically, or (b) restoring a captured config back onto a fresh
      install. These are different features — which one first?

### Reinstall OS → services → configs → "everything works again"
- [ ] fix the capture gaps above first — no reinstall plan is trustworthy
      while the capture itself has known holes
- [ ] pick the first service to actually test a manual reinstall on
      (small ones: `mus`, `silly`, or `shutter` are the easiest tries)
- [ ] after that one works, decide what (if anything) gets scripted

---

## 4. Later, when you want to (real numbers, nothing runs)

`srv clean` used to have "Stray files & dirs" and "Old backup tarballs"
categories with a curated, dorm-specific path list — removed 2026-09-05
(they don't generalize to another box, and the list needed re-auditing
almost every session). Everything that list covered is below, by hand.

Re-checked live 2026-09-09:

| what | size | note |
|---|---|---|
| dangling docker volumes | **17 volumes** | `nexus-data` (nexus moved to a bind mount), `immich_model-cache` (no immich container exists) among them. `docker volume prune` reclaims them |
| `~/.cache` | **8.8G** | pip/uv/huggingface — rebuilds itself on next use |
| old backup snapshots | `/mnt/nas/backups/state/` | mostly `open-webui` (1.8G) and `minecraft`/`minecraft-app` (1.6G + 785M). Decide per-service using §2's table |
| old manual minecraft tarballs | **4 files** | `/mnt/nas/backups/mc*.tar.gz` — pre-`srv` manual backups. Keep 1-2 recent, `rm` the rest |
| `~/git/FriendNet` | 497M | root-owned, no git remote — check what it is before deleting |
| `~/minecraft-hrd/world_backups/world.tar.gz` | 526M | stale (Feb) — if you want a minecraft-hrd backup, do a fresh one instead |
| `~/git/booru-main` **+** `~/git/booru/booru-main` (nested) | 339M + ~339M | **two** duplicate copies now, not one — both same remote/commit as the real booru, both stub DBs |
| `/@/v2rayN-linux-64.zip` | 128M | never extracted |
| `/@/ops/{NEXT.md,lib/,srv,srv.conf.example}` | ~92K | a stale manual mirror of this tool from before `srv push` auto-copied `NEXT.md` here — safe to delete now, see §1 of the plan doc. **Leave the rest of `/@/ops` alone** — `fubuki/` (238M), `21.12 Eula/` (131M), and `23.02 kita ikuyo 1/` (69M) are unrelated folders that ended up inside that same directory and aren't part of the tool mirror |
| `frp.tar.gz` ×2 | 14M each | `~/frp/` and `/@/`, byte-identical |
| docker images | — | **not actually reclaimable today** — every image backs a running container |
| `~/git/library.db` | 316K | loose file in `~/git/`, same size as `mus/data/library.db` — looks like an orphaned copy |
| `~/git/cve/venv/` | 83M | appears to be committed into the cve repo's working tree — check `.gitignore` before treating it as source |

Deferred on purpose, not forgotten: moving `~/git` somewhere else, `/@`
PARA reorg, the 3TB drive, n8n, any reinstall automation. Revisit once
§3's checkboxes above have been through a real pass.
