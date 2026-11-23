# nu_modules

Nushell modules that go with [op](https://github.com/quietlight/op), a one-shot
agentic loop.

- **`hop.nu`**: an interactive chat over op sessions. op itself runs one prompt
  and exits; hop reads a line, runs `op --json`, prints the answer and a stats
  line (with a context gauge), and threads the session and branch into the next
  send. Commands: `:e [skill]` compose in `$EDITOR`, `:v` view the current
  branch's transcript, `:l [n]` browse and fork sessions, `:m [model]` pick a
  model, `:h [goal]` hand off to a fresh session, `:n` new session, `:q` quit.
  `@file/path` in a prompt attaches the file as `--context`.
- **`pi-session-view.nu`**: renders an op/pi session `.jsonl` log as a
  readable transcript; `--leaf <entry-id>` renders one branch. hop's `:v` uses it.
- **`hop-reader.nu`**: optional. Gives hop inline Tab completion of `@path`
  tokens, but needs a nushell build with `input --completer` (not in stock nu).
  Without it hop works the same, minus Tab.

## Use

```nu
use ~/nu_modules/hop.nu
hop --context CLAUDE.md
hop --session <id>          # pick up an existing session

use ~/nu_modules/pi-session-view.nu
pi-session-view ~/.op_global/sessions/<dir>/<file>.jsonl
```

Requires `op` on PATH and nushell 0.117 or later.

## Licence

MIT, see [LICENSE](LICENSE).
