import os

/// Diagnostics: timings, languages and outcomes. Never the dictated text.
/// Read with: /usr/bin/log show --last 1h --predicate 'subsystem == "com.vcamaral.utter"'
/// (the full path matters in zsh, where `log` is a shell builtin).
let logger = Logger(subsystem: "com.vcamaral.utter", category: "dictation")
