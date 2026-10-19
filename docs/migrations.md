# Migrating an existing install

`migrate.sh <path-to-scripts-dir>` brings an installed server up to the current suite. It
does three things, in this order of risk:

1. **Scripts and shared services.** The deployed helper scripts and the API wrapper are
   compared with `src/scripts`, changed files are replaced, files the suite dropped are
   removed (a copy stays in the pre-migration backup archive).
2. **Variables.** New keys are appended to `common/variables.txt`; your values are never
   overwritten.
3. **Server-side migrations** (`migrate-lib/server_migrations.sh`). Files the suite wrote for the
   server itself, which a scripts update alone never reaches.

The Minecraft server is stopped only when the scripts it runs change, and never by the
server-side migrations. When a stop is needed, the run checks that the server really is down
(the unit inactive and no screen session of that exact name) before it moves anything, and
puts the old layout back (instance folder, unit paths, `SERVER_PATH`) if a later step fails.

The operation locks stay held across the swap of the scripts folder: `.locks/` is moved into
the new tree rather than copied. Because the whole folder is swapped, ACLs that
`service_user.sh` granted on it are lost; the final summary prints the command to run again.
Each run leaves a `<scripts>_backup_<stamp>` archive next to the scripts folder, and the
newest five are kept (`MIGRATE_KEEP_ARCHIVES=N`; `0` keeps them all).

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

Add three functions to `migrate-lib/server_migrations.sh` (`sm_<id>_describe`, `_check`, `_apply`) and
append the id to `SERVER_MIGRATIONS`. `_apply` returns 0 when done, 1 when it failed and 3 when
the operator has to do something. Replace files by writing a temporary copy and renaming it, never
edit one a running server may be reading. Cover the three outcomes in
`tests/shell/test_server_migrations.sh`.

## How migrate.sh is organized

`migrate.sh` only runs the phases in order. The code lives in `migrate-lib/`, one module per concern. Each module defines functions and constants and nothing else, so loading it runs nothing, and `migrate.sh` sources every module by name (`tests/shell/test_migrate_modules.sh` fails when a module is not sourced exactly once). The modules share one shell with `migrate.sh`, so state is plain global variables, as it was before the split.

| Phase | Modules |
|---|---|
| Inputs | `ui.sh` (messages, `run_cmd`), `cli.sh` (flags, `--help`), `context.sh` (target instance, shared state) |
| Plan, nothing is changed | `preflight.sh`, `plan_scripts.sh`, `api_wrapper.sh`, `variables.sh`, `structure.sh`, `server_migration_steps.sh`, `plan.sh` (scope, summary, confirmation) |
| Apply | `locks.sh`, `backup.sh`, `recovery.sh` (undo on failure), `server_lifecycle.sh`, `structure.sh`, `replace_scripts.sh`, `api_wrapper.sh`, `variables.sh`, `server_migration_steps.sh`, `npm.sh` |
| Finish | `verify.sh`, `report.sh` |
| Helpers | `json_config.sh`, `npm.sh`, `server_migrations.sh` (the migrations themselves, see above) |

Rules when changing a module:

- Keep phase functions global-state functions: no `local` for anything a later phase reads, and no `declare` (it is local inside a function).
- End a phase function with `return 0`. `migrate.sh` runs under `set -e`, and a function whose last command was an `a && b` that did not run would otherwise abort the migration.
- Call phase functions as plain statements, never as `if f` or `f || ...`, so `set -e` still stops the run inside them.
- Do not use `BASH_SOURCE` in a module. The checkout root is `MIGRATE_SCRIPT_DIR`, set by `migrate.sh`.
- `migrate-lib/` is not deployed to servers (only `src/scripts/` is), so a change here never reaches an installed instance except through running `migrate.sh`.
