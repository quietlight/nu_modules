# nu_modules

Nushell modules for [op](https://github.com/quietlight/op).

- **`hop.nu`**: interactive REPL over op sessions. Streams `op --stream` through
  `op --render`, prints a stats line with context gauge, and threads session and
  branch ids across turns. Commands: `:e [skill]` edit in `$EDITOR`, `:l [n]`
  browse/fork sessions, `:m [model]` pick/set model, `:h [goal]` hand off to a
  new session, `:n` new session, `:q` quit. `@path` attaches files via `--context`.
- **`pi-session-view.nu`**: standalone renderer for op/pi `.jsonl` session logs.
- **`hop-reader.nu`**: optional `@path` Tab completion for `hop` (requires a
  patched nushell with `input --completer`).

## Use

```nu
use ~/nu_modules/hop.nu
hop --context CLAUDE.md
hop --session <id>          # resume a session

use ~/nu_modules/pi-session-view.nu
pi-session-view ~/.op_global/sessions/<dir>/<file>.jsonl
```

Requires `op` on `PATH` and Nushell 0.117+.

## Licence

MIT, see [LICENSE](LICENSE).
