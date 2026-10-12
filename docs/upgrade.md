# Server version upgrade

`src/scripts/update/upgrade.sh <version>` moves an instance to a new Minecraft
version as one supervised job. The dashboard starts it through the API wrapper;
it works the same from SSH.

## What it does

1. **Plan check.** `update-server.js --plan --json` resolves the target, the Java it
   needs and every installed mod's verdict. Nothing is changed.
2. **Countdown.** Players are warned in game.
3. **Stop.** Save, stop the service, confirm it is down.
4. **Backup.** `backup.sh --archive update`. If it fails, nothing was changed and the
   server is started again. The archive this run created is remembered by name.
5. **Install.** `update-server.js --apply --json`: the jar swap, then the version is
   recorded, then the mod update.
6. **Start and watch.** The service is started. Success is the `Done` line in
   `logs/latest.log`. Failure is a `crash_loop_gave_up` event in
   `logs/lifecycle.ndjson` or no `Done` before the timeout.
7. **If it fails and some mods have no build for the target:** exactly those mods are
   moved to `mods/disabled/` (`toggle-mod.js --disable`, reversible) and the server
   is started again. The first start keeps them, so a mod that still works on the
   new version is not lost.
8. **If it still fails:** the backup from step 4 (not "the newest one") is restored,
   the version record is put back, and the old version is started.

Mods with no build for the target are listed in the result as "kept on an old
build" when the first start worked. A mod that loads can still misbehave in
game; the result says so.

## Progress

Progress is one JSON object per line on stdout and in
`scripts/common/upgrade-status.ndjson`: `{seq, ts, phase, status, msg}`, and a
last `{type:"result", ok, ...}` line. `--expect-unavailable=a,b` refuses to start
when the installed mods no longer match the set a person confirmed.

## Locking

The whole job holds the per-instance **operation lock** (`acquire_operation_lock`
in `common/utils.sh`). `restore.sh`, `rollback.sh` and `backup.sh` take the same
lock, so none of them can run while an upgrade does. Scripts the job starts itself
pass because it exports `MC_OPERATION_LOCK_HELD=1`. A refused run exits `75`.

## Lifecycle events

`start.sh` appends to `<instance>/logs/lifecycle.ndjson` (1 MB, one rotated file):
`jvm_start`, `jvm_exit`, `restart_scheduled`, `crash_loop_gave_up`. Restart
behaviour is unchanged. After it gives up, systemd starts the script again and the
crash counter restarts, so a broken server cycles about once a minute until
something stops the service; the upgrade job does that itself (`instance_ops.sh
halt`). `crash_loop_gave_up` also sends a `server_crash_loop` webhook when the
webhook helper is installed next to the instance.
