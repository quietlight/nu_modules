# hop.nu — interactive REPL over op sessions.
# Streams turns through `op --stream | op --render` and threads sessionId/parentId across prompts.
# Structure: view -> effects -> model/msg/update -> runtime (`main`).

# ── view ─────────────────────────────────────────────────────────────────────

def dim [text: string] { print $"(ansi dark_gray)($text)(ansi reset)" }

def err [text: string] { print $"(ansi red)error: ($text)(ansi reset)" }

# Return [$name $value] or [] if null. Use if/else [] instead when building the value depends on non-null (Nu args are eager).
def flag [name: string, value: any]: nothing -> list<string> {
    if $value == null { [] } else { [$name ($value | into string)] }
}

# Context window usage badge (empty if model has no contextWindow).
def context-gauge [res] {
    let c = $res | get -o context
    if $c == null { return "" }
    let pct = ($c.pct * 100 | math round)
    let colour = if $c.pct < 0.6 { "green" } else if $c.pct < 0.85 { "yellow" } else { "red" }
    $"(ansi $colour)ctx ($pct)%(ansi reset)"
}

def status-line [res] {
    let stop = $res | get -o stopReason
    let t = $res | get -o tokens
    let parts = [
        (if ($res | get -o model) != null { [$res.model] } else { [] })
        (if $stop != null and $stop != "finished" { [$"stopped: ($stop)"] } else { [] })
        (if ($res | get -o turns) != null {
            [$"turns ($res.turns)" $"tools ($res.toolCalls)"]
        } else { [] })
        (if $t != null { [$"tokens ($t.input)+($t.cacheRead) in, ($t.output) out"] } else { [] })
    ] | flatten
    let gauge = context-gauge $res
    if ($parts | is-empty) { return $gauge }
    let dimmed = $"(ansi dark_gray)($parts | str join ' · ')(ansi reset)"
    if $gauge == "" { $dimmed } else { $"($dimmed) ($gauge)" }
}

# Print error (if any), stats line, and handoff hint on context_limit.
def show-result [res] {
    if ($res | get -o error) != null {
        err $res.error
        if ($res | get -o hint) != null { dim $res.hint }
    }
    print (status-line $res)
    if ($res | get -o stopReason) == "context_limit" {
        dim "context full — :h <goal> to hand off to a fresh session"
    }
}

# ── effects ──────────────────────────────────────────────────────────────────

# Filter user messages (already typed) and result lines (handled by show-result) from --render.
def off-screen [line: string]: nothing -> bool {
    let e = try { $line | from json } catch { null }
    if $e == null { return false }
    let type = $e | get -o type
    $type == "result" or ($type == "message" and (($e | get -o message | get -o role) == "user"))
}

# Run op --stream, teeing filtered output to op --render, and return the final result record.
def send-op [args: list<string>] {
    let results = (
        ^op --stream ...$args
        | tee { lines | where {|l| not (off-screen $l) } | to text | ^op --render }
        | lines
        | each {|l| try { $l | from json } catch { null } }
        | where {|e| ($e | describe | str starts-with "record") and ($e | get -o type) == "result" }
    )
    if ($results | is-empty) {
        {isError: true, error: "op produced no result line"}
    } else {
        $results | last
    }
}

# Open $buf in $EDITOR (default hx); returns true if mtime changed (saved).
def edit-buffer [buf: path] {
    let before = ls $buf | get 0.modified
    let editor = $env.EDITOR? | default "hx" | split row " "
    run-external ($editor | first) ...($editor | skip 1) $buf
    (ls $buf | get 0.modified) != $before
}

# Give each editor invocation its own scratch file and keep it through the send.
def edit-and-send [state: record, cfg: record, seed: string, from: any, unsaved: string] {
    let buf = (mktemp -t --suffix .md hop-XXXXXXXXXX)
    try {
        $seed | save --force $buf
        if (edit-buffer $buf) {
            run-send $state $cfg {prompt: ["--prompt" $buf], from: $from, contexts: []}
        } else {
            dim $unsaved
            $state
        }
    } finally {
        rm --force --permanent $buf
    }
}

# Recent sessions for cwd (newest first) with nested messages table for explore.
def session-tree [limit: int] {
    ^op --json --list sessions --limit $limit
    | from json
    | get sessions
    | sort-by timestamp --reverse
    | each {|s|
        # Pass count as limit to fetch all messages (op defaults to 25).
        let msgs = (
            try {
                ^op --json --list messages --sessionId $s.id --limit $s.count
                | from json
                | get messages
            } catch { [] }
        )
        {
            id: $s.id
            when: ($s.timestamp | into datetime | date to-timezone local | format date "%m-%d %H:%M")
            n: $s.count
            summary: ($s | get -o summary | default "")
            messages: ($msgs | select -o id role preview isFork)
        }
    }
}

# Return the session's branch tip, prompting if there are multiple (null on cancel/none).
def pick-tip [session: string] {
    let tips = (
        # --limit 1000 avoids op's default 25 cap.
        try {
            ^op --json --list branches --sessionId $session --limit 1000
            | from json
            | get branches
        } catch { [] }
    )
    if ($tips | length) <= 1 { return ($tips | get -o 0.tip) }
    dim $"($tips | length) branches — pick the one to continue, or Esc to cancel"
    let choice = (
        $tips
        | each {|t| {
            when: ($t.when | into datetime | date to-timezone local | format date "%m-%d %H:%M")
            role: $t.role
            tail: $t.preview
            tip: $t.tip
        }}
        | input list --display {|it| $"($it.when)  ($it.role)  ($it.tail)" }
    )
    $choice | get -o tip
}

# Ask op --handoff for a brief. Uses complete because op exits 1 with a JSON error on stdout.
def handoff-draft [session: string, parent: any, goal: string] {
    let args = [
        ["--handoff" "--json" "--sessionId" $session]
        (flag "--parentId" $parent)
        (if $goal == "" { [] } else { [$goal] })
    ] | flatten
    let out = (^op ...$args | complete)
    try { $out.stdout | from json } catch { null }
}

def list-models [] {
    try {
        ^op --json --list models --limit 1000
        | from json
        | get models
        | each {|m| $"($m.provider)/($m.model)" }
    } catch { [] }
}

# Fuzzy-pick from configured models; null on cancel or empty list.
def pick-model [current: any] {
    let models = (list-models)
    if ($models | is-empty) {
        dim "no models found — check ~/.op_global/agent/models.json"
        return null
    }
    $models | input list --fuzzy $"model (($current | default 'op default')) >"
}

# ── model ────────────────────────────────────────────────────────────────────
# Loop state: session/parent to attach to, :m model override, consecutive input errors, done flag.

def init [session: any, parent: any, model: any] {
    {session: $session, parent: $parent, model: $model, errors: 0, done: false}
}

# ── msg ──────────────────────────────────────────────────────────────────────
# Named parse-line to avoid shadowing builtin `parse`. Unrecognised :words fall through as prompts.
def parse-line [raw: string] {
    let line = $raw | str trim
    let cmd = $line | split row " " | first
    let arg = $line | str substring ($cmd | str length).. | str trim
    match $cmd {
        "" => ({msg: "nothing", arg: ""})
        ":q" => ({msg: "quit", arg: ""})
        ":n" => ({msg: "new", arg: ""})
        ":l" => ({msg: "browse", arg: $arg})
        ":m" => ({msg: "model", arg: $arg})
        ":h" => ({msg: "handoff", arg: $arg})
        ":e" => ({msg: "edit", arg: $arg})
        _ => ({msg: "send", arg: $line})
    }
}

# ── update ───────────────────────────────────────────────────────────────────

# :l — browse cwd sessions in explore; pick a session id to resume or message id to fork.
def update-browse [state: record, arg: string] {
    let limit = if $arg == "" { 15 } else { try { $arg | into int } catch { 15 } }
    let tree = (session-tree $limit)
    if ($tree | is-empty) {
        dim "no sessions for this directory yet"
        return $state
    }
    dim "Enter cursors in · Esc backs out / just browses · :q picks the id under the cursor"
    let picked = ($tree | explore --peek)
    # Esc returns the whole table/record; only a picked string cell is an id.
    if ($picked | describe) != "string" { return $state }
    if $picked in ($tree | get id) {
        dim $"next send resumes session ($picked)"
        return ($state | merge {session: $picked, parent: (pick-tip $picked)})
    }
    let owner = ($tree | where {|s| $picked in ($s.messages | get -o id | default [])})
    if ($owner | is-empty) {
        dim $"'($picked)' is not a session or message id — nothing picked"
        return $state
    }
    dim $"next send resumes session ($owner.0.id) forked at ($picked)"
    $state | merge {session: $owner.0.id, parent: $picked}
}

# :m — set model override directly or via fuzzy picker.
def update-model [state: record, arg: string] {
    let choice = if $arg != "" { $arg } else { pick-model $state.model }
    if $choice == null {
        dim "model unchanged"
        return $state
    }
    dim $"model set to ($choice)"
    $state | merge {model: $choice}
}

# :h — draft a handoff brief, edit in $EDITOR, and send as a new linked session.
def update-handoff [state: record, cfg: record, goal: string] {
    if $state.session == null {
        dim "nothing to hand off yet"
        return $state
    }
    let res = (handoff-draft $state.session $state.parent $goal)
    if $res == null {
        err "handoff produced no result"
        return $state
    }
    if ($res | get -o isError) == true {
        err ($res | get -o error | default "handoff failed")
        return $state
    }
    edit-and-send $state $cfg $res.handoffPrompt $state.session "draft not saved — nothing sent"
}

# :e — compose prompt in $EDITOR, optionally seeded from skills/<skill>.md.
def update-edit [state: record, cfg: record, skill: string] {
    let seed = if $skill == "" {
        ""
    } else {
        let path = $"skills/($skill).md"
        if not ($path | path exists) {
            dim $"no skill file ($path)"
            return $state
        }
        open --raw $path
    }
    edit-and-send $state $cfg $seed null "buffer not saved — nothing sent"
}

# Plain prompt: attach existing @path tokens via --context (non-files like @skill pass through).
def update-send [state: record, cfg: record, line: string] {
    let at_files = (
        $line
        | parse -r '(?:^|\s)@(\S+)'
        | get capture0
        | uniq
        | where {|p| ($p | path type) == "file" }
    )
    run-send $state $cfg {prompt: [$line], from: null, contexts: $at_files}
}

# Session/context flags: fresh sessions (new or --fromSession) get --context; resumes already have it.
def attach-args [state: record, cfg: record, from: any] {
    let ctx = if $cfg.context == null { [] } else { ["--context" $cfg.context] }
    if $from != null {
        ["--fromSession" $from] ++ $ctx
    } else if $state.session != null {
        let at = if $state.parent == null { [] } else { ["--parentId" $state.parent] }
        ["--sessionId" $state.session] ++ $at
    } else {
        $ctx
    }
}

# Invoke op for a send request ({prompt, from, contexts}) and advance session/parent.
def run-send [state: record, cfg: record, req: record] {
    let args = [
        ($req.contexts | each {|f| ["--context" $f] } | flatten)
        (flag "--model" $state.model)
        (flag "--profile" $cfg.profile)
        (flag "--tools" $cfg.tools)
        (flag "--max-steps" $cfg.max_steps)
        (attach-args $state $cfg $req.from)
        $req.prompt
    ] | flatten
    let res = (send-op $args)
    show-result $res
    # Track parentId to stay on this branch; keep old values on crash, advance session even on isError.
    $state | merge {
        parent: ($res | get -o parentId | default $state.parent)
        session: ($res | get -o sessionId | default $state.session)
    }
}

def update [state: record, cfg: record, msg: record] {
    let state = if $msg.msg == "interrupted" { $state } else { $state | merge {errors: 0} }
    match $msg.msg {
        "nothing" => $state
        "quit" => ($state | merge {done: true})
        "interrupted" => {
            # Ctrl-c clears the line instead of quitting; bail after 20 straight errors (e.g. closed stdin).
            let n = $state.errors + 1
            if $n > 20 { dim "input keeps failing — quitting" }
            $state | merge {errors: $n, done: ($n > 20)}
        }
        "new" => {
            dim "next send starts a fresh session"
            $state | merge {session: null, parent: null}
        }
        "browse" => (update-browse $state $msg.arg)
        "model" => (update-model $state $msg.arg)
        "handoff" => (update-handoff $state $cfg $msg.arg)
        "edit" => (update-edit $state $cfg $msg.arg)
        "send" => (update-send $state $cfg $msg.arg)
        # Exhaustive fallback: an unmatched arm in Nu returns null.
        _ => { err $"no handler for ($msg.msg)"; $state }
    }
}

# ── runtime ──────────────────────────────────────────────────────────────────

# Interactive REPL over op sessions.
# Plain text sends; `@path` attaches existing files via --context.
#
# Commands:
#   :e [skill]  compose in $EDITOR (optional seed: skills/<skill>.md); save to send
#   :h [goal]   draft handoff brief, review in $EDITOR, send as new linked session
#   :l [n]      browse last n (default 15) sessions in explore; :q on id to resume/fork
#   :m [model]  set provider/model override (bare: fuzzy picker)
#   :n          start a fresh session on next send
#   :q          quit (ctrl-d also quits; ctrl-c clears line)
export def main [
    --model (-m): string    # provider/model override
    --profile: string       # capability profile (from nuProfiles)
    --tools: string         # tool set (e.g. read,glob or "none")
    --session: string       # resume an existing session
    --parent: string        # starting entry id in --session (tip to continue, other to fork)
    --context (-c): string  # context file injected on fresh sessions (e.g. CLAUDE.md)
    --max-steps: int        # step cap per send
] {
    let cfg = {
        history: ($nu.home-dir | path join ".op_global" "hop_history.txt")
        profile: $profile
        tools: $tools
        context: $context
        max_steps: $max_steps
        # Complete @path tokens as file paths (--type path avoids PATH binary completion).
        completer: {|buf, pos|
            let before = $buf | str substring 0..<$pos
            let tok = $before | split row -r '\s+' | last
            if ($tok | str starts-with "@") {
                let start = ($before | str length) - ($tok | str length)
                ($tok | str substring 1..) | commandline complete --type path
                | each {|c| {value: $"@($c)", start: $start, end: $pos} }
            } else { [] }
        }
    }
    dim "@path TAB -> attach context · :e [file] -> edit prompt · :h [goal] -> handoff · :l [n] -> browse sessions · :m [model] -> pick/set model · :n -> new thread · :q -> quit"
    # Resolve branch tip up front for --session when --parent is unset.
    let start_parent = if $session != null and $parent == null {
        pick-tip $session
    } else {
        $parent
    }
    mut state = (init $session $start_parent $model)
    # Injectable reader (hop-reader.nu sets $env.HOP_READER). Use `if`, not `default` (default calls closures).
    let fallback = {|history, completer|
        input --reedline --history-file $history "hop> "
    }
    let reader = if $env.HOP_READER? == null { $fallback } else { $env.HOP_READER }
    loop {
        # reedline: ctrl-d -> null, ctrl-c -> throws (caught as non-string record).
        let raw = (try { do $reader $cfg.history $cfg.completer } catch { {interrupted: true} })
        let msg = if $raw == null {
            {msg: "quit", arg: ""}
        } else if ($raw | describe) != "string" {
            {msg: "interrupted", arg: ""}
        } else {
            parse-line $raw
        }
        $state = (update $state $cfg $msg)
        if $state.done { break }
    }
    # Include --parent so resuming a branched session isn't ambiguous.
    if $state.session != null {
        let at = if $state.parent == null { "" } else { $" --parent ($state.parent)" }
        dim $"resume: hop --session ($state.session)($at)"
    }
}
