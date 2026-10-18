# Glossary

Terms specific to this project that are easy to misread.

**Operation lock.** The one slot per instance for work that rewrites the server or its archives: restore, rollback, backup, upgrade, backup cleanup and the mod scripts. It is a file under `scripts/<instance>/.locks` (or `INSTANCE_LOCK_DIR`), taken with `flock`, or with a `mkdir` lock where `flock` is missing. A refused run exits `75`. The holder exports `MC_OPERATION_LOCK_HELD=1` so the scripts it starts pass instead of waiting on it.

**Pre-restore copy.** The server folder as it was before a restore or rollback, kept as `<server>.pre-restore` when the run was given `--keep-old`. Without the flag the old folder is deleted after the swap. Only one such copy exists; the next run with `--keep-old` replaces it.

**Instance lock.** A named per-instance lock (`maintenance`, `onjoin`) that keeps a second copy of the same script from running. Separate from the operation lock.

**Confirmed save.** A `save-all flush` the server has acknowledged: over RCON the command's reply, in screen mode the server's own "Saved the game" log line written after the command was sent. A backup of a running server is made only after one.
