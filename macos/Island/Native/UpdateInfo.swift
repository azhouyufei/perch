struct UpdateInfo: Encodable, Equatable {
    var version: String
    var phase: String
    var progress = 0.0
    var notes = ""
    var bullets: [String] = []
    /// Counts up to say an offer again (Check for updates while one waits): the page treats it as new.
    var nudge = 0
    /// A failed update (phase "failed"): one line for the notch, a few words for Settings, what you can do (retry, move, none), and
    /// whether it was looking ("check") or getting one in ("update").
    var problem = ""
    var short = ""
    var fix = ""
    var during = ""
    /// Found by a check on the schedule, not one you asked for: the notch peeks (one line, a click opens the row) instead of
    /// opening the row. `listOnly`: it peeked already for this version, or a Not now holds: only the list's Update says it.
    var peek = false
    var listOnly = false
}
