# The creative mirror

A creative mirror is a second Minecraft server where people build in creative mode on a **copy of your survival world**, refreshed every night. They can fly to their survival base, design something, and nothing they do there can touch the real world. Next to the copied overworld the creative server also has flat **build plots** for free-form building.

The mirror is **optional**. Nothing else in this suite needs it: without it every command works as before, and removing it puts the server back as it was. It works on servers you already run, and it can be set up together with a new server.

## What you get

```
 survival server                                  creative server
 world (overworld)  --- nightly, read-only --->   overworld = copy of survival
                        over SSH (rsync)          plots     = flat build plots
```

- **Survival is only ever read.** The creative server pulls; the survival server has no key that can write anywhere.
- **The creative server restarts once a night** for a few seconds, to swap the copied chunk folders in. Players see a warning in chat.
- **Builds in the copied overworld are replaced every night.** Plots are never touched.

## Before you start

| | |
|---|---|
| Two servers | A survival server and a creative server, each a normal install of this suite. They can be two machines or two VMs (the audit tested two VMs on one network). They need to reach each other on SSH (port 22 by default). |
| Same Minecraft version | Both on the same version, for example 26.3. The pull refuses a different one. |
| Same seed | The creative world must be created with the survival world's seed (`/seed` on survival). A seed cannot be changed on an existing world. |
| Linux with systemd | On both. The jobs are systemd timers. |
| Packages | `rsync` on both, `openssh-server` on the survival side, `rrsync` (comes with the rsync package on Debian 12 and newer). |

## Set up on servers that already exist

### 1. Survival server

Run as the server's user (not root; it asks for `sudo` where it must):

```bash
bash mirror.sh setup source --instance survival
```

This does not stop or restart the running server. It:

- creates a shell-less read-only account `mcsync` that can only serve the export folder,
- installs a nightly export timer (04:40 by default),
- stores its settings in the instance's `common/variables.txt` (a clearly marked block),
- prints the host's SSH fingerprint.

`--instance` finds the instance below your home folder; use `--scripts-dir` to point at `scripts/<instance>` yourself.

### 2. Creative server

```bash
bash mirror.sh setup target --instance creative --source <survival address>
```

This generates the pull key, installs a nightly pull timer (05:15 plus up to 5 minutes), and adds a sudo rule that lets this user stop and start `creative.service` and nothing else. It prints the exact `authorize` command for the next step.

### 3. Pair the two (read-only, pinned to this machine)

On the survival server, allow the creative server's key. The `--from` address pins the key to the creative server:

```bash
bash mirror.sh authorize --instance survival --from <creative address> --key "ssh-ed25519 AAAA..."
```

On the creative server, pin the survival server's SSH host key. Compare the fingerprint with the one `mirror.sh fingerprint` prints on the survival server, so nobody can sit in the middle:

```bash
bash mirror.sh pin-host --instance creative --host <survival address> --fingerprint SHA256:...
```

### 4. Check the link and run the first refresh

```bash
bash mirror.sh test --instance creative     # on the creative server
bash mirror.sh export --instance survival   # on the survival server (first snapshot)
bash mirror.sh pull --instance creative     # on the creative server
```

`test` checks that listing works and that everything it should not do is refused: a shell command, a write, a path above the export folder, following links, and a different host key. It also shows the versions, the seed and the worldgen mods of the source.

### 5. The creative server itself

An existing creative server only needs the pull wired in; its world already has a seed. If you are setting up a **new** creative server, use `mirror.sh prepare` (below) before its first start.

## Set up with a new server

A source needs nothing but a flag, so the Default route is enough:

```bash
bash main.sh --default --agree-eula --mirror-source
```

A target must know the survival server and its seed, so it uses your own `variables.json` (the Power-user route). `--default` refuses to run when that file exists, and the Default route would have no `MIRROR.REMOTE`. Put the optional block in the file, set `JAVA.SERVER.SEED` to the survival world's `level-seed`, and run setup without `--default` (the `--mirror-target` flag is then optional). The Guided wizard asks for the same things.

```json
"MIRROR": { "ENABLED": true, "ROLE": "target", "REMOTE": "mcsync@192.168.1.20" }
```

```bash
bash main.sh --agree-eula
```

A target needs `MIRROR.REMOTE` and, in `JAVA.SERVER.SEED`, the survival world's seed. The mirror setup runs after the install, so a problem with it never rolls the install back. **If the preparation of a target fails, the server is not started**, because the first start would create a world with the wrong seed. Fix it, then run `mirror.sh prepare` and start the server.

### What `prepare` does

`mirror.sh prepare --instance creative [--seed N]` changes files only, on a new instance (it refuses a running server and an existing world; `--force` prepares the rest anyway but never touches a world's seed):

- game mode creative, `force-gamemode` off, region compression `deflate`, the seed,
- RCON on (the suite's own RCON mode, used for the nightly swap),
- Fabric API (a plain Fabric server has none), FabricPlots and Dimensional Inventories from Modrinth by exact version, with the SHA-512 checked (see `src/mirror/pins.json`; for a Minecraft version without a pin the newest release is used and the output says so),
- FabricPlots without its own game-mode switching, and Dimensional Inventories pools so the plots, the mirrored overworld and the Nether with the End (one shared pool) each keep their own inventory, all creative,
- C2ME turned off on a new server (see below).

On Minecraft 26.3 the whitelist is on by default: add players, or turn it off on purpose.

## What is copied, and what is not

Only the chunk folders of the mirrored dimensions: `region/`, `entities/` and `poi/` of `minecraft/overworld` (add `minecraft/the_nether` or `minecraft/the_end` with `--dims`; the End can disagree with its dragon-fight data, so the overworld is the default).

Never copied: `level.dat`, `data/` (scoreboard, maps, game rules, world border), `players/`, the plot dimension, and each dimension's own `data/` folder. Item frames with maps may show blank maps on the creative side.

## Parity: what has to match

- **Minecraft version:** must match, or the pull refuses.
- **Seed:** a different seed is reported. Copied chunks are exact, but terrain generated later does not continue them.
- **Fabric Loader and world-generation mods:** differences are a warning by default (`MIRROR_PARITY=warn`; `refuse` stops the pull, `off` is silent).
- **Generation is only approximate even with everything matching.** In the audit's test, newly generated chunks on two identical servers differed in small features (kelp, ore blobs, leaves) in roughly two thirds of the chunks, and with C2ME the number of differing blocks was about three times higher. Large terrain and biomes line up. Plan for the edge of the mirrored area not being block-perfect.
- **C2ME:** the installer and `doctor` warn when it is installed. On a new target `prepare` turns it off. On an existing survival server nothing is removed for you.

## Every night

Survival, 04:40: take the instance lock, turn auto-save off, confirm a flush, copy the chunk files into an immutable snapshot (usually a second or two with auto-save off), turn auto-save back on, publish a manifest, keep the last two snapshots.

Creative, 05:15: fetch the manifest, check it (age, version, parity, size), pull the snapshot (only changed files, resumable), check it against the manifest, refuse a snapshot that is empty or much smaller than the current mirror, pre-stage a copy, warn players, stop the server, swap the chunk folders with renames, start the server, wait for "Done", keep the old folders for a rollback. If the server does not start on the new data, the old folders are put back.

## Day to day

```bash
bash mirror.sh status --instance creative      # what is configured and applied
bash mirror.sh doctor --instance creative      # healthy or not
bash manage.sh mirror doctor creative          # the same through manage.sh
sudo bash manage.sh doctor creative            # includes the mirror lines
bash mirror.sh pull --instance creative --dry-run   # run every check, change nothing
bash mirror.sh pull --instance creative --force     # re-apply, or accept a real shrink
```

Webhook events (see the README table): `mirror_export_failed`, `mirror_sync_complete`, `mirror_sync_failed`.

| What went wrong | What happens |
|---|---|
| The survival server is unreachable | The pull is retried, the creative server is untouched, the next night tries again |
| The transfer drops | The next run resumes from the cache; the server was never stopped |
| The snapshot is old, empty, much smaller, or the wrong version | Refused; the message names the reason |
| Not enough disk space | Exit 73; nothing is deleted, not even the old rollback |
| The export was killed with auto-save off | The service's `ExecStopPost` and the next export turn it back on |
| The pull was killed during the swap | `ExecStopPost` (or the next run) puts every folder back and restarts the server |
| The server does not start on new data | Rolled back; the rejected data is kept in `sync/failed/` |

## Security

- **Pull, not push:** the creative server holds the only key, and it can only read.
- **A dedicated account `mcsync`** with no password, serving one folder with `rrsync -ro`. Its `authorized_keys` line is root-owned and pinned with `restrict,from=...,command=...`, and sshd's `Match User mcsync` block disables forwarding and terminals.
- **The host key is pinned** by you, comparing the fingerprint, and a changed key fails the pull.
- **The manifest is not trusted:** sizes must be plausible, a transfer that grows past what the manifest declared is stopped, and a single file is capped at 2 GiB (`MIRROR_MAX_FILE_SIZE`). A survival server you do not trust can still fill the creative server's disk before the check stops it, so only pull from a server you control.
- **Privileges:** the creative side may stop and start its own service through sudo, nothing else; the jobs and the settings are the server user's. All privileged steps are in `src/mirror/root_helper.sh`, which validates every input and has `--dry-run`.
- **The timer services** carry no sandboxing options (the jobs use sudo and screen), and the job shell opens its own log after systemd has dropped to the server user.

## Settings

Switched on by `mirror.sh setup` (which keeps a marked block in `common/variables.txt`) or by the `MIRROR` block in `variables.json`. All optional:

| Key | Meaning | Default |
|---|---|---|
| `ENABLED`, `ROLE` | `source` (survival) or `target` (creative) | off |
| `REMOTE`, `SSH_PORT` | target only: `mcsync@address` of the survival server | |
| `SOURCE_MODE` | `live`: its own short save-off window; `stage`: copy the backup's staging mirror (needs `BACKUP_STAGING_MODE=mirror`) | `live` |
| `DIMS` | dimensions to mirror | `["minecraft/overworld"]` |
| `EXPORT_AT`, `PULL_AT` | times as `HH:MM` | `04:40`, `05:15` |
| `BWLIMIT_KIB` | pull speed limit, 0 for none | `40000` |
| `PARITY` | `warn`, `refuse` or `off` | `warn` |
| `MIN_REGION_RATIO_PCT` | refuse a snapshot with fewer region files than this share of the current mirror | `50` |
| `MAX_SNAPSHOT_GB` | refuse a larger snapshot, 0 for no limit | `0` |
| `KEEP_SNAPSHOTS` | snapshots kept on the source, at least 2 | `2` |

The same keys exist in `variables.txt` with a `MIRROR_` prefix. Other `MIRROR_*` tuning (timeouts, retries, lock wait) is read from the same file; see `src/mirror/lib/common.sh` for the full list.

## Removing it

```bash
bash mirror.sh uninstall --instance creative            # timers, rule, settings; keeps snapshots and key
bash mirror.sh uninstall --instance creative --purge    # also the state folder
```

The world is never touched. The source side removes the `mcsync` account when its last key is gone.

## What was and was not tested

Tested on two Debian 13 VMs on one network with Minecraft 26.3: the whole export, pull and swap chain, recovery after a kill at each point of the swap, disk-full and dropped-transfer behaviour, and the pairing checks. **Not tested:** behaviour with real players (inventory switching between the pools, game mode on dimension change), mc-router, and a path across the internet. The research is in `docs/research/2026-10-25-creative-mirror-vm-test-audit.md`.
