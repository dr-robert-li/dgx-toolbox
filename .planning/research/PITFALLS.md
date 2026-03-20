# Pitfalls Research

**Domain:** Symlink-based tiered model storage (HuggingFace + Ollama, local NVMe drives)
**Researched:** 2026-03-21
**Confidence:** HIGH (most pitfalls verified against official docs and known filesystem behavior)

---

## Critical Pitfalls

### Pitfall 1: Migrating While a Model Is Open (Race Condition on Move)

**What goes wrong:**
A cron job starts migrating a model directory from hot to cold at 2 AM. Simultaneously, a user
launches vLLM or transformers and opens the model files. The migration script uses `mv` to
move the directory, then creates a symlink back. During the gap between `mv` completing and
`ln -s` completing, the model path resolves to nothing — any process that re-opens a file
(e.g., to load a second shard) gets ENOENT. Even if a process has files open, `mv` on the
parent directory does not invalidate existing open file descriptors (the kernel keeps the
inode alive), but any new open() call on the symlink path fails during the gap.

**Why it happens:**
`mv` + `ln -s` is two separate operations. There is no atomic "move directory and replace
with symlink" syscall. Scripts naively run `mv src dst && ln -s dst src`, leaving a window.

**How to avoid:**
- Before migrating any model, check if it is currently in use: `lsof +D "$model_path"` or
  check if any launcher lock/PID files indicate active inference. If in use, skip migration
  and log a warning.
- Keep the window as short as possible: move to a staging path, then atomically swap the
  symlink using `ln -snf` (which replaces the symlink atomically via rename(2) under
  the hood on Linux).
- Never migrate models during hours when inference is likely; make the cron window
  configurable and default it to 2 AM.

**Warning signs:**
- `lsof` shows open handles on model files when migration runs
- vLLM or transformers errors referencing "No such file or directory" on shard files
- Log entries showing migration and inference overlapping timestamps

**Phase to address:** Migration cron + recall logic phase

---

### Pitfall 2: Broken Symlinks When External Drive Is Unmounted

**What goes wrong:**
The external NVMe at `/media/robert_li/modelstore-1tb` unmounts (cable pull, systemd
decision, kernel USB error, power event). Every symlink pointing into that mount now
resolves to a dangling path. Tools that walk `~/.cache/huggingface/hub/` or
`~/.ollama/models/` silently find broken symlinks, or worse, raise cryptic errors. vLLM
will fail with an unhelpful "model not found" or file read error.

**Why it happens:**
`nofail` in fstab allows the system to boot without the drive — it does not re-mount the
drive if it disappears mid-session. Symlinks are stored as path strings; the kernel does not
invalidate them when a mount disappears.

**How to avoid:**
- Every script that creates or follows symlinks must verify the mount first:
  `mountpoint -q /media/robert_li/modelstore-1tb || { log_error "cold drive not mounted"; exit 1; }`.
  The `mountpoint` command (util-linux) is the correct check — do not use `ls` or `test -d`
  which can succeed if the directory exists but the drive is unmounted (showing an empty
  mount point directory).
- The `migrate` and `recall` subcommands must refuse to operate if the cold drive is not
  mounted — this is already listed as a requirement and must be the first check in every
  script that touches cold paths.
- The `status` command should flag all symlinks that are currently broken (dangling) and
  clearly indicate the drive is unmounted.
- Add drive-present check to launcher hooks: before invoking inference, if the model
  resolves through a symlink to an unmounted drive, emit a desktop notification and abort.

**Warning signs:**
- `find ~/.cache/huggingface/hub -xtype l` returns any results (finds dangling symlinks)
- `mountpoint -q /media/robert_li/modelstore-1tb` returns non-zero
- journalctl showing USB/storage errors

**Phase to address:** Init phase (establish mount-check utility function used everywhere)

---

### Pitfall 3: HuggingFace Internal Symlinks Break When Blobs Are Split Across Tiers

**What goes wrong:**
The HuggingFace cache uses a two-level internal symlink structure:
`snapshots/<revision>/<filename> -> ../../blobs/<hash>` — these are **relative symlinks**.
If you move only the `blobs/` directory to cold storage and leave `snapshots/` on hot,
the relative symlinks break because `../../blobs/` no longer resolves correctly relative
to the snapshot path.

Conversely, if you move the entire model directory
(`models--org--name/`) to cold and replace it with a symlink pointing to cold, this is
safe — the internal relative paths remain intact because the whole directory tree moves
together. Breaking them apart (blobs on cold, snapshots on hot) is what causes silent
corruption.

**Why it happens:**
The migration unit must be the entire `models--org--name/` directory, not individual blobs
or snapshots. Developers unfamiliar with the HF cache structure attempt to be clever and
migrate only large blob files, breaking the internal relative symlinks.

**How to avoid:**
- Always treat `~/.cache/huggingface/hub/models--org--name/` as an atomic unit.
  Migrate (or recall) the entire model directory, never individual subdirectories.
- After migration, verify internal symlinks are intact:
  `find "$cold_path/models--org--name/snapshots" -type l | xargs -I{} readlink -e {}` —
  any empty output indicates a broken internal symlink.

**Warning signs:**
- `find <model_dir>/snapshots -xtype l` returns results after migration
- `transformers` errors about missing config.json or model weights even though the model
  directory exists

**Phase to address:** Migration logic phase — enforce whole-directory-as-unit rule in code

---

### Pitfall 4: Ollama Server Caches Manifest Paths at Startup

**What goes wrong:**
Ollama reads `~/.ollama/models/manifests/` at startup and resolves blob paths. If you
move the `~/.ollama/models/` directory to cold storage and replace it with a symlink while
the Ollama server is running, the server may continue using cached internal paths from before
the move, causing "model not found" or blob integrity errors on the next `ollama run`.

The Ollama server must be stopped before moving its model directory and restarted after
the symlink is in place.

**Why it happens:**
Ollama (like any server process) reads the filesystem at open() time. After a directory is
replaced with a symlink to a new location, existing processes resolve the new target
correctly on the next open() — but some implementations cache directory entries or file
descriptors. Ollama's manifest loading may re-read on each inference request (safe) or
cache on startup (unsafe to move mid-session). The safe assumption is: always restart Ollama
around any move of its models directory.

**How to avoid:**
- Migration and recall scripts must detect if the Ollama server is running
  (`systemctl is-active ollama` or checking the process) before moving `~/.ollama/models/`.
- If Ollama is running, either skip migration for Ollama models with a logged warning, or
  stop Ollama, perform the move, and restart.
- Use `OLLAMA_MODELS` environment variable approach as an alternative to symlinking the
  entire models dir — but this requires systemd service file changes.

**Warning signs:**
- `ollama run <model>` errors immediately after migration without the server being restarted
- Ollama log showing blob hash mismatch errors
- `ollama list` shows model but `ollama run` fails

**Phase to address:** Migration logic phase — add Ollama server state checks

---

### Pitfall 5: Revert/Reinit Leaves Orphaned Symlinks or Deletes Model Data

**What goes wrong:**
Two failure modes during `revert` or `reinitialize`:

1. **Orphaned symlinks after partial revert**: The script moves models from cold back to hot,
   then removes the symlink. If the script is interrupted (Ctrl+C, power loss) after moving
   some models but before removing their symlinks, you end up with valid symlinks pointing to
   paths that no longer exist on cold (because they were moved to hot), but the hot path also
   doesn't have the model where the symlink expects.

2. **Accidental deletion during reinit**: A reinitialize that reconfigures the cold drive
   path runs `rm -rf` on what it thinks is an empty staging directory, not realizing it is
   following a symlink into a cold drive that still contains model data.

**Why it happens:**
Interrupt-unsafe scripts. Using `rm -rf` without verifying the target is not a symlink
to a data directory. Not maintaining a migration state log that allows resumption.

**How to avoid:**
- Maintain a JSON state file (`.planning/modelstore-state.json` or similar) that tracks
  which models are on which tier and their migration status. Before operating on any model,
  record the intended operation; after completion, record success. This allows safe resumption
  after interruption.
- Never use `rm -rf` on a path without first confirming it is a real directory, not a symlink:
  `[[ -L "$path" ]] && unlink "$path"` for symlinks, `rm -rf "$path"` only for real dirs.
- The `revert` command should: (1) copy model back to hot, (2) verify copy integrity,
  (3) only then remove the cold copy and the symlink. Never remove source before verifying destination.
- Revert should be idempotent: re-running after interruption should safely complete.

**Warning signs:**
- Revert script exits non-zero mid-run (trap ERR and log the state)
- Model directory exists on hot but also has a symlink pointing to cold (both exist = revert interrupted)
- Cold drive shows model directories that should have been removed after revert

**Phase to address:** Init/revert phase — implement state file and interrupt-safe operations

---

### Pitfall 6: Disk Space Check Using Wrong Tool or Method

**What goes wrong:**
The migration script checks available space on the cold drive before migrating, but uses
`du -sh "$model_path"` to estimate the model size and `df -h /media/...` to check free
space. The `du` default measures **disk blocks used** (not apparent size), and on some
filesystems or with sparse files, this can differ significantly from the actual bytes
that will be copied. More critically: `df` reports filesystem-level free space, but `du`
on the source counts blocks allocated on the source filesystem — if the source is ext4 and
the destination is also ext4 but with different block sizes, the estimate is wrong.

The common mistake is: `du -s "$model_path"` returns 14G for a model, free space is 15G,
migration proceeds — but the destination only has 14.5G free after filesystem overhead,
journaling reservation, and block alignment rounding, and the copy fails mid-transfer,
leaving a partial model on cold.

**Why it happens:**
Developers use `du -sh` for human-readable output without understanding that 5% filesystem
reservation + journal overhead means "15G free" is actually only ~14.25G writable. Also,
`du` without `--apparent-size` can undercount sparse files or overcount due to block
boundaries.

**How to avoid:**
- Use `du -sb "$model_path"` (bytes, not blocks) for the source size estimate.
- Apply a 10% safety margin: `required=$(($(du -sb "$model_path" | cut -f1) * 110 / 100))`.
- Check available space with `df --output=avail -B1 "$dest_mount" | tail -1` (bytes).
- If available < required, refuse migration with a clear message.
- After copy, verify the destination size matches source before removing source and creating symlink.

**Warning signs:**
- Partial model directories on cold drive (some files present, copy was interrupted)
- `df` showing cold drive at 99%+ after a migration that "should have fit"

**Phase to address:** Migration logic phase — space check utility function

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcoded paths (`/media/robert_li/modelstore-1tb`) | Simpler scripts | Breaks if drive label changes or user differs | Never — always read from config |
| No state file for migration tracking | Fewer moving parts | Non-resumable after interruption, no audit trail | Never for production use |
| Skip Ollama server check during migration | Simpler script | Model corruption or "not found" errors mid-inference | Never |
| `rm -rf` without symlink check | One-liner cleanup | Can wipe model data through an unexpected symlink | Never |
| Hardcoded retention period (14 days) in script | Simpler | Can't be reconfigured without editing scripts | Never — config file required |
| Use `ls` or `test -d` to check mount | Familiar idiom | Returns success even when drive is unmounted (empty mountpoint dir) | Never — use `mountpoint -q` |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| HuggingFace cache | Migrating only `blobs/` to save space, leaving `snapshots/` on hot | Always migrate the entire `models--org--name/` directory as one unit |
| HuggingFace cache | Moving cache dir while `.lock` files exist from an active download | Check for `.lock` files in the model dir before migration; skip if present |
| Ollama | Moving `~/.ollama/models/` while server is running | Stop Ollama service, move, restart — or skip Ollama models if server is active |
| Ollama | Creating a symlink inside `~/.ollama/models/` per-model | Ollama's manifest system expects a flat blob store — symlink the entire models dir, not subdirs |
| `notify-send` from cron | Running `notify-send` directly in cron; fails silently with no DBUS session | Set `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus` in the cron script; test with `systemd-run --user` |
| vLLM/transformers launchers | Updating timestamp only on launch, not on continued use | Timestamp should be touched at launch entry point in launcher hooks, not on model load complete |
| Launcher hooks | Assuming TTY available for error reporting | Hook scripts must log to a file; never assume stderr reaches a user terminal |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| `find ~/.cache/huggingface` to list all models | Status command takes 30+ seconds with many models | Walk only one level deep; use `ls -d` on known directories, not recursive find | ~50+ model directories |
| `du -sh` on entire cold drive for space report | Status command hangs for minutes | Cache size values in state file; update incrementally during migrate/recall | Cold drive with 50+ models |
| Checking all symlinks for validity on every `status` call | Status is slow; cron health check times out | Only validate symlinks for models the user is querying, or sample-check on status | ~20+ symlinked models |
| `lsof +D "$model_path"` to check if in use | Very slow on large model directories (lsof walks all open FDs for all processes) | Use `fuser "$model_path"` or check launcher PID files instead for common-case | Any model directory with many files |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| World-writable state file or config | Another process or user corrupts migration state | `chmod 600` on config and state files; owned by the user running modelstore |
| Creating symlinks before verifying cold drive is ext4 (not exFAT) | exFAT does not support symlinks; `ln -s` silently fails or errors | Check filesystem type with `stat -f -c %T "$mount"` or `findmnt -o FSTYPE`; refuse if not ext4/xfs/btrfs |
| Running migration cron as root | A bug deleting through a symlink wipes system files | Run cron as the owning user; never require sudo for routine migration |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent migration failure (cron exits non-zero with no notification) | User has no idea migration is broken; stale models accumulate on hot drive | Always send `notify-send` on cron failure; also write to a log that `modelstore status` surfaces |
| `modelstore status` shows raw paths without indicating tier | User can't tell which models are hot vs cold at a glance | Color-code or label each entry: `[HOT]` / `[COLD]` / `[BROKEN SYMLINK]` |
| Recall completes but user's inference command still fails | User assumes recall didn't work | Recall should print the resolved path after completion so user can verify |
| Revert takes 10+ minutes with no progress output | User kills the process thinking it hung, leaving partial state | Show progress bar or per-model progress during revert and reinit |
| Drive-not-mounted error gives no recovery hint | User confused about what to do | Error message must say exactly: "Plug in the drive and run: sudo mount /media/robert_li/modelstore-1tb" |

---

## "Looks Done But Isn't" Checklist

- [ ] **Mount check**: Uses `mountpoint -q`, not `test -d` or `ls` — verify the latter two pass even with unmounted drives
- [ ] **Broken symlink detection**: `find -xtype l` (not `-type l`) finds dangling symlinks — verify `-type l` misses them
- [ ] **Atomic symlink replacement**: Uses `ln -snf` (or `mv -T` with temp symlink), not `rm` then `ln -s` — verify gap exists without this
- [ ] **notify-send from cron**: Script sets `DBUS_SESSION_BUS_ADDRESS` — verify by running the script via `crontab -e` with a test, not just manually
- [ ] **HF cache migration unit**: Script migrates entire `models--org--name/` dir — verify it does not operate on blobs or snapshots subdirs separately
- [ ] **Ollama server check**: Migration script checks `systemctl is-active ollama` before touching Ollama models dir — verify behavior when Ollama is running
- [ ] **Space check with margin**: Applies 10%+ buffer — verify with a model that nearly fills remaining space
- [ ] **Revert idempotency**: Re-running revert after interruption completes safely — verify by interrupting mid-revert and re-running
- [ ] **State file is updated transactionally**: State records intent before action, completion after — verify state is consistent after kill -9 during migration
- [ ] **exFAT rejection**: Tool refuses to use `backup-256g` (exFAT) as cold store — verify by attempting init with that path

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Broken symlinks from unmounted drive | LOW | Mount drive; symlinks auto-resolve. Run `modelstore status` to verify. |
| Partial migration (interrupted mv, no symlink created) | MEDIUM | Model data is on cold drive but no symlink exists on hot. Run `modelstore recall <model>` to move it back, or manually create the symlink. |
| Partial revert (some models back on hot, symlinks not cleaned up) | MEDIUM | Re-run `modelstore revert` — must be idempotent. Manually reconcile by checking state file vs actual filesystem state. |
| HF internal symlinks broken (blobs/snapshots split across tiers) | HIGH | Move entire `models--org--name/` directory back together (same filesystem). Re-download may be required if blobs were partially deleted. |
| Revert accidentally followed symlink and wiped cold data | HIGH | Restore from backup. This is why the backup-256g drive exists. Prevention is the only real mitigation. |
| Ollama "model not found" after migration | LOW | Restart Ollama service: `systemctl restart ollama`. The symlink is correct but Ollama needs to re-read manifests. |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Race condition: migration while model in use | Migration cron + launcher hook phase | Test: start a long inference, trigger migration, verify no file-not-found errors |
| Broken symlinks on drive unmount | Init phase (mount-check utility) | Test: unmount cold drive, run `modelstore migrate`, verify hard refusal |
| HF internal symlink breakage (wrong migration unit) | Migration logic phase | Test: migrate a model, verify `find snapshots -xtype l` returns nothing |
| Ollama server restart required | Migration logic phase | Test: migrate Ollama model with server running, verify refusal or graceful stop/restart |
| Revert/reinit data loss | Init/revert phase | Test: kill revert mid-run, re-run, verify completion without data loss |
| Disk space estimation errors | Migration logic phase | Test: attempt migration when only 1% more space than model size is available |
| Silent cron failure | Migration cron phase | Test: introduce a deliberate cron failure, verify notify-send fires and log is written |
| notify-send fails from cron (no DBUS) | Migration cron phase | Test: run cron as user, verify notification appears on desktop |
| exFAT cold drive (no symlink support) | Init phase | Test: run `modelstore init` with exFAT path, verify rejection with helpful message |
| Symlink loop from re-init on existing symlink | Init phase | Test: run `modelstore init` twice, verify second run detects and handles existing symlinks |

---

## Sources

- [HuggingFace Hub — Understand caching (official docs)](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache) — HIGH confidence, official documentation
- [HuggingFace hub v0.24.7 release: Fix race-condition in concurrent downloads](https://github.com/huggingface/huggingface_hub/releases/tag/v0.24.7) — HIGH confidence, official changelog
- [HF issue: models cannot be stored on network storage due to unhandled file lock errors](https://github.com/huggingface/huggingface_hub/issues/2038) — MEDIUM confidence, verified GitHub issue
- [Ollama FAQ — how to set custom models directory](https://docs.ollama.com/faq) — HIGH confidence, official docs
- [Ollama — Change models directory (Arch Linux Forums, solved)](https://bbs.archlinux.org/viewtopic.php?id=292487) — MEDIUM confidence, community verified
- [Atomic symlinks — Tom Moertel's Blog](https://blog.moertel.com/posts/2005-08-22-how-to-change-symlinks-atomically.html) — HIGH confidence, well-known reference on atomic symlink swap
- [Things UNIX can do atomically — rcrowley](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html) — HIGH confidence
- [notify-send from cron (selivan.github.io)](https://selivan.github.io/2016/07/08/notify-send-from-cron-in-ubuntu.html) — MEDIUM confidence, verified against multiple forum threads
- [Why notify-send doesn't work in cron (uptimia.com)](https://www.uptimia.com/questions/why-doesnt-notify-send-work-in-cron) — MEDIUM confidence
- [Symlink loop detection — Linux man page symlink(7)](https://linux.die.net/man/7/symlink) — HIGH confidence, kernel documentation
- [du vs df differences — IBM Knowledge Base](https://www.ibm.com/support/pages/why-numbers-du-s-and-df-disagree) — HIGH confidence

---
*Pitfalls research for: symlink-based tiered ML model storage (DGX Toolbox — modelstore)*
*Researched: 2026-03-21*
