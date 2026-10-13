# Migrating an existing install

`migrate.sh <path-to-scripts-dir>` brings an installed server up to the current suite. It
does three things, in this order of risk:

1. **Scripts and shared services.** The deployed helper scripts and the API wrapper are
   compared with `src/scripts`, changed files are replaced, files the suite dropped are
   removed (a copy stays in the pre-migration backup archive).
2. **Variables.** New keys are appended to `common/variables.txt`; your values are never
   overwritten.
3. **Server-side migrations** (`src/migrations/server.sh`). Files the suite wrote for the
   server itself, which a scripts update alone never reaches.

The Minecraft server is stopped only when the scripts it runs change, and never by the
server-side migrations.

## Server-side migrations

| Id | What it does | Takes effect |
|---|---|---|
| `instance_start_script` | Replaces `<instance>/start.sh` with `src/vanilla/start.sh` (lifecycle events, crash-loop webhook). The old file is kept as `start.sh.pre-migrate-<time>`. | at the next server start |
| `unit_start_limits` | Adds `StartLimitIntervalSec=120`, `StartLimitBurst=5` and `StartLimitAction=none` to the instance's systemd unit, after `RestartSec`, then `daemon-reload`. A unit that already sets any `StartLimit*` is left alone. The old unit is kept in `common/migration-backups/`. | at the next crash loop |

Each migration looks at the real files to decide whether it still applies, so it is safe to
run again and needs no record to be right. Results are also appended to
`common/server-migrations.log` (time, id, `applied`, `manual` or `failed`). A failed or manual
migration does not stop the others and is tried again next time.

If the unit cannot be written without a password, the migration prints the exact `sudo cp`
and `daemon-reload` commands, keeps the patched unit next to the backup, and reports a manual
step instead of failing.

```
migrate.sh <scripts-dir> --list-server-migrations   # pending or current, last result; changes nothing
migrate.sh <scripts-dir> --dry-run                  # the whole migration, nothing written
migrate.sh <scripts-dir> --no-server-migrations     # scripts and services only
```

The world, mods, `server.jar` and `server.properties` are never touched.

## Adding one

Add three functions to `src/migrations/server.sh` (`sm_<id>_describe`, `_check`, `_apply`) and
append the id to `SERVER_MIGRATIONS`. `_apply` returns 0 when done, 1 when it failed and 3 when
the operator has to do something. Replace files by writing a temporary copy and renaming it, never
edit one a running server may be reading. Cover the three outcomes in
`tests/shell/test_server_migrations.sh`.
