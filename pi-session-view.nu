# pi-session-view.nu — render an op/pi session .jsonl log as a readable transcript.
#
# Usage:
#   use pi-session-view.nu
#   pi-session-view /path/to/session.jsonl
#
# Standalone alternative to `op --render` (modeled on op's lib/render.ml; may drift).
# Also renders `todo` checklist details. Unknown entry types are skipped.

# --- limits ----------------------------------------------------------------

const PREVIEW_LINES = 5
const NU_PREVIEW_LINES = 10
const ERROR_PREVIEW_LINES = 15
const SCRIPT_LINES = 15
const THINKING_LINES = 5
const TODO_ITEMS = 5
const VALUE_CHARS = 60
const EDIT_CHARS = 40
const LINE_CHARS = 200
const INDENT = "    "

# nu tool exit footer: "<output>\n(exit code: N)".
const EXIT_PREFIX = "(exit code: "

# --- helpers ---------------------------------------------------------------

def is-list [v]: nothing -> bool {
    let d = ($v | describe)
    ($d | str starts-with "list") or ($d | str starts-with "table")
}

# Truncate to n chars (not bytes, matching str substring).
def clip [n: int, s: string]: nothing -> string {
    if ($s | str length --chars) > $n { ($s | str substring 0..<$n) + "…" } else { $s }
}

def one-line [s: string]: nothing -> string {
    $s | str replace -a "\n" " " | str trim
}

def text-of [v]: nothing -> string {
    if ($v | describe) == "string" { $v } else { $v | to json -r }
}

# Join text blocks from message content (list of blocks or bare string).
def block-text [content]: nothing -> string {
    if (is-list $content) {
        $content
        | where {|b| ($b | get -o type) == "text"}
        | get -o text
        | compact
        | str join "\n"
    } else if (($content | describe) == "string") {
        $content
    } else {
        ($content | to text)
    }
}

# Strip session cwd prefix (falling back to $env.PWD) using literal "/" separators.
def rel [path: string]: nothing -> string {
    let cwd = ($env.PI_SESSION_CWD? | default $env.PWD)
    if ($cwd != "") and ($path | str starts-with ($cwd + "/")) {
        $path | str substring (($cwd | str length --chars) + 1)..
    } else {
        $path
    }
}

def human-bytes [n: int]: nothing -> string {
    if $n < 1024 {
        $"($n) B"
    } else if $n < 1048576 {
        $"(($n / 1024.0) | into string --decimals 1) kB"
    } else {
        $"(($n / 1048576.0) | into string --decimals 1) MB"
    }
}

# Tool call/result header with 5-char padded name and no trailing space.
def head-line [arrow: string, name: string, rest: string]: nothing -> string {
    let padded = ($name | fill --alignment left --width 5)
    $"  (ansi magenta)($arrow)(ansi reset) ($padded) ($rest)" | str trim --right
}

def print-body [text: string, limit: int] {
    let ls = ($text | lines)
    for l in ($ls | first $limit) {
        print $"($INDENT)(ansi default_dimmed)(clip $LINE_CHARS $l)(ansi reset)"
    }
    if ($ls | length) > $limit {
        print $"(ansi default_dimmed)($INDENT)…  ($ls | length) lines total(ansi reset)"
    }
}

# --- tool calls ------------------------------------------------------------

def read-range [args]: nothing -> string {
    let offset = ($args | get -o offset)
    let limit = ($args | get -o limit)
    if ($offset == null) and ($limit == null) {
        ""
    } else if $limit != null {
        let o = (if $offset == null { 1 } else { $offset })
        $"  lines ($o)-($o + ([$limit 1] | math max) - 1)"
    } else {
        $"  from line ($offset)"
    }
}

def edit-summary [args]: nothing -> string {
    let old = (clip $EDIT_CHARS (one-line ($args | get -o old_string | default "")))
    let new = (clip $EDIT_CHARS (one-line ($args | get -o new_string | default "")))
    let all = (if ($args | get -o replace_all) == true { $"  (ansi default_dimmed)\(all\)(ansi reset)" } else { "" })
    $"(rel ($args | get -o path | default "?"))  ($old) → ($new)($all)"
}

def todo-summary [args]: nothing -> string {
    let action = ($args | get -o action | default "?")
    let text = ($args | get -o text)
    let id = ($args | get -o id)
    if ($action == "add") and ($text != null) {
        $"add (clip $VALUE_CHARS (one-line $text))"
    } else if ($action == "toggle") and ($id != null) {
        $"toggle #($id)"
    } else {
        $action
    }
}

# Fallback k=v summary for unknown tools.
def arg-summary [args]: nothing -> string {
    if (($args | describe) | str starts-with "record") {
        $args
        | transpose k v
        | each {|r| $"($r.k)=(clip $VALUE_CHARS (one-line (text-of $r.v)))" }
        | str join ", "
    } else if (($args | describe) == "nothing") {
        ""
    } else {
        (one-line ($args | to json -r))
    }
}

def print-script [args] {
    let ls = ($args | get -o script | default "" | lines)
    for l in ($ls | first $SCRIPT_LINES) {
        print $"($INDENT)(ansi default_dimmed)(clip $LINE_CHARS $l)(ansi reset)"
    }
    if ($ls | length) > $SCRIPT_LINES {
        print $"(ansi default_dimmed)($INDENT)…  ($ls | length) lines total(ansi reset)"
    }
}

def render-call [b] {
    let name = ($b | get -o name | default "?")
    let args = ($b | get -o arguments)
    let path = { rel ($args | get -o path | default "?") }
    match $name {
        "read" => { print (head-line "→" $name $"(do $path)(read-range $args)") }
        "glob" => {
            let root = ($args | get -o path)
            let cwd = ($env.PI_SESSION_CWD? | default $env.PWD)
            let where = (if ($root == null) or ($root == $cwd) { "" } else { $"  in (rel $root)" })
            print (head-line "→" $name $"($args | get -o pattern | default "?")($where)")
        }
        "write" => {
            let bytes = ($args | get -o content | default "" | str length)
            print (head-line "→" $name $"(do $path)  \((human-bytes $bytes)\)")
        }
        "edit" => { print (head-line "→" $name (edit-summary $args)) }
        "todo" => { print (head-line "→" $name (todo-summary $args)) }
        "nu" => {
            let timeout = ($args | get -o timeout)
            let rest = (if ($timeout != null) and ($timeout != 120) { $"timeout ($timeout)s" } else { "" })
            print (head-line "→" $name $rest)
            print-script $args
        }
        _ => { print (head-line "→" $name (arg-summary $args)) }
    }
}

# --- tool results ----------------------------------------------------------

# Parse exit code from nu's "(exit code: N)" footer, or null.
def exit-code-of [line: string]: nothing -> any {
    let n = ($EXIT_PREFIX | str length)
    if (($line | str length) > $n) and ($line | str starts-with $EXIT_PREFIX) and ($line | str ends-with ")") {
        let code = ($line | str substring $n..<(($line | str length) - 1))
        if $code == "" { null } else { $code }
    } else {
        null
    }
}

# Split nu's trailing exit-code footer into {summary, body}.
def split-exit [text: string]: nothing -> record {
    let ls = ($text | lines)
    if ($ls | is-empty) {
        {summary: "done", body: $text}
    } else {
        let code = (exit-code-of ($ls | last))
        if $code == null {
            {summary: "done", body: $text}
        } else {
            {summary: $"exit ($code)", body: ($ls | drop 1 | str join "\n")}
        }
    }
}

# Normalize tool output for preview (strip nu exit footer, relativize glob paths).
def body-of [name: string, text: string]: nothing -> string {
    match $name {
        "nu" => { (split-exit $text).body }
        "glob" => { $text | lines | each {|l| rel $l } | str join "\n" }
        _ => { $text }
    }
}

# One-line summary and preview line limit for a tool result.
def result-summary [name: string, args: any, text: string]: nothing -> record {
    let n = ($text | lines | length)
    match $name {
        "read" => {
            let path = ($args | get -o path)
            if $path == null {
                {summary: $"($n) lines", limit: $PREVIEW_LINES}
            } else {
                {summary: $"(rel $path)  ($n) lines", limit: $PREVIEW_LINES}
            }
        }
        "glob" => { {summary: $"($n) paths", limit: $PREVIEW_LINES} }
        "write" | "edit" => { {summary: (one-line $text), limit: 0} }
        "nu" => { {summary: (split-exit $text).summary, limit: $NU_PREVIEW_LINES} }
        _ => { {summary: $"($n) lines", limit: $PREVIEW_LINES} }
    }
}

# Render todo result details: checklist for list, one-line text for other actions.
def render-todo-details [d, text: string] {
    let err = ($d | get -o error)
    if $err != null {
        print (head-line "←" "todo" $"(ansi red)error: ($err)(ansi reset)")
        return
    }
    if ($d | get -o action) != "list" {
        print (head-line "←" "todo" (clip $VALUE_CHARS (one-line $text)))
        return
    }
    let todos = ($d | get -o todos | default [])
    let n = ($todos | length)
    print (head-line "←" "todo" $"($n) item\(s\)")
    if $n == 0 {
        print $"($INDENT)(ansi default_dimmed)no todos(ansi reset)"
    } else {
        for t in ($todos | first $TODO_ITEMS) {
            let mark = (if ($t | get -o done) == true {
                $"(ansi green)✓(ansi reset)"
            } else {
                $"(ansi default_dimmed)○(ansi reset)"
            })
            print $"($INDENT)($mark) (ansi magenta)#($t | get -o id | default 0)(ansi reset) ($t | get -o text | default "")"
        }
        if $n > $TODO_ITEMS {
            print $"(ansi default_dimmed)($INDENT)…  ($n - $TODO_ITEMS) more(ansi reset)"
        }
    }
}

def render-tool-result [m, calls: record] {
    let name = ($m | get -o toolName | default "?")
    let text = (block-text ($m | get -o content))
    let args = ($calls | get -o ($m | get -o toolCallId | default ""))
    let details = ($m | get -o details)
    if ($m | get -o isError) == true {
        let tag = (if $name == "nu" {
            $"(ansi red)[error](ansi reset) ((split-exit $text).summary)"
        } else {
            $"(ansi red)[error](ansi reset)"
        })
        print (head-line "←" $name $tag)
        print-body (body-of $name $text) $ERROR_PREVIEW_LINES
    } else if ($name == "todo") and ($details != null) {
        render-todo-details $details $text
    } else {
        let s = (result-summary $name $args $text)
        print (head-line "←" $name $s.summary)
        if $s.limit > 0 { print-body (body-of $name $text) $s.limit }
    }
}

# --- messages --------------------------------------------------------------

def render-thinking [b] {
    let ls = ($b | get -o thinking | default "" | lines)
    for l in ($ls | first $THINKING_LINES) {
        print $"  (ansi default_dimmed)(clip $LINE_CHARS $l)(ansi reset)"
    }
    if ($ls | length) > $THINKING_LINES {
        print $"(ansi default_dimmed)  …  ($ls | length) lines of thinking(ansi reset)"
    }
}

def render-user [m] {
    print ""
    print $"(ansi cyan_bold)### USER(ansi reset)"
    print (block-text ($m | get -o content))
}

def render-assistant [m] {
    let out = ($m | get -o usage | get -o output | default 0)
    let model = ($m | get -o model | default "?")
    print ""
    print $"(ansi blue_bold)### ASSISTANT(ansi reset) (ansi blue)[($model)]  out=($out) tok(ansi reset)"
    let content = ($m | get -o content)
    let blocks = (if (is-list $content) { $content } else { [] })
    for b in $blocks {
        if ($b | get -o type) == "thinking" { render-thinking $b }
    }
    let txt = (block-text $content)
    if ($txt | str trim | is-not-empty) { print $txt }
    for b in $blocks {
        if ($b | get -o type) == "toolCall" { render-call $b }
    }
}

def render-message [e, calls: record] {
    let m = ($e | get -o message)
    match ($m | get -o role) {
        "user" => { render-user $m }
        "assistant" => { render-assistant $m }
        "toolResult" => { render-tool-result $m $calls }
        _ => {}
    }
}

# --- other entries ---------------------------------------------------------

def render-session [e] {
    print $"(ansi green_bold)══ session ($e | get -o id | default "?") ══(ansi reset)"
    print $"(ansi green)cwd: (ansi reset) ($e | get -o cwd | default "?")"
    print $"(ansi green)time:(ansi reset) ($e | get -o timestamp | default "?")"
}

def render-model-change [e] {
    print $"(ansi yellow)[model → ($e | get -o provider | default "?")/($e | get -o modelId | default "?")](ansi reset)"
}

# --- call memory -----------------------------------------------------------

# Extract {toolCallId: arguments} from an assistant message (toolResult only carries the id).
export def calls-of [e: record]: nothing -> record {
    let m = ($e | get -o message)
    if (($e | get -o type) != "message") or (($m | get -o role) != "assistant") {
        return {}
    }
    let content = ($m | get -o content)
    if not (is-list $content) { return {} }
    $content
    | where {|b| ($b | get -o type) == "toolCall"}
    | reduce --fold {} {|b, acc| $acc | upsert ($b | get -o id | default "?") ($b | get -o arguments) }
}

# --- entry point -----------------------------------------------------------

# Render one parsed JSONL entry. Pass `calls` from calls-of to show paths on read results.
export def render-entry [e: record, calls: record = {}] {
    match ($e | get -o type) {
        "session" => { render-session $e }
        "model_change" => { render-model-change $e }
        "message" => { render-message $e $calls }
        _ => {}
    }
}

# Render an op/pi session .jsonl log to stdout.
export def main [file: path] {
    let entries = (
        open --raw $file
        | lines
        | where {|l| ($l | str trim | is-not-empty)}
        | each {|l| try { $l | from json } catch { null } }
        | compact
    )
    # Use session header cwd for relative paths, falling back to $env.PWD.
    let header = ($entries | where {|e| ($e | get -o type) == "session"} | get -o 0)
    $env.PI_SESSION_CWD = (if $header == null { $env.PWD } else { $header | get -o cwd | default $env.PWD })
    let calls = ($entries | reduce --fold {} {|e, acc| $acc | merge (calls-of $e) })
    for e in $entries { render-entry $e $calls }
}
