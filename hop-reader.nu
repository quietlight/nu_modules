# @path Tab completion for hop. Requires patched nu with `input --completer`
# (kept separate from hop.nu so stock nu can parse hop.nu).
#
# Sets $env.HOP_READER: {|history, completer| -> string|null} (reedline: ctrl-d -> null, ctrl-c throws).
export-env {
    $env.HOP_READER = {|history, completer|
        input --reedline --history-file $history --completer $completer "hop> "
    }
}
