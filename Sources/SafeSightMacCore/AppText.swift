// SPDX-License-Identifier: Apache-2.0
// Every sentence the cover-only app shows, in one place, so tests can check it against the project's
// rules: the honest promise word for word, the mode picker's one sentence, and none of the claims the
// project never makes ("can't be bypassed", "100%", "blocks all", "treats addiction",
// "nobody can ever unlock it").

public enum AppText {
    /// The only promise the project may make (README, blueprint chapter 01).
    public static let honestPromise = "SafeSight Mac is free, open-source software that runs entirely on your Mac. It covers explicit images on your screen, and turning it off takes a waiting period you choose ahead of time. Only a friend you choose can shorten that wait, and never to less than a day. Nobody else can, including us. It isn't perfect: wiping your Mac removes it, it can miss an image or cover a harmless one, and it only protects this Mac. It's an early release built with the help of AI, so keep a backup."

    // MARK: Practice state (SD-223)

    /// The menu's practice-state line, when no keeper is installed.
    public static let practiceTitle = "Practice: no lock"
    public static let practiceDetail = "This is the cover-only build. It has no lock: you can pause it or quit it at any time, and it protects nothing against you. The lock comes in a later version."
    /// When a keeper launch file is present, or the check could not be completed.
    public static let notPracticeTitle = "Not in practice: pause is off"
    public static let keeperFoundDetail = "A SafeSight Mac keeper is installed on this Mac. This cover-only build has no lock and cannot work with a keeper, so pausing is turned off. Covering carries on as usual."
    public static let practiceUnknownDetail = "This build could not check whether a SafeSight Mac keeper is installed, so pausing is turned off. Covering carries on as usual."

    // MARK: Status

    public static let statusOn = "Covering: on"
    public static let statusNeedsPermission = "Needs Screen Recording"
    public static let needsPermissionDetail = "SafeSight Mac needs the Screen Recording permission to check what your displays show. Until you grant it, nothing is checked or covered."
    public static let grantPermission = "Open Screen Recording settings…"
    public static let statusPaused = "Paused: nothing is checked or covered"
    public static let statusStarting = "Starting…"
    public static let statusFault = "A display is covered whole"
    public static let statusModelsMissing = "The picture checker could not start"

    // MARK: Detector mode picker (SD-125: these words, and no figure)

    public static let modeHeader = "Detector mode"
    public static let modeBalanced = "Balanced (default)"
    public static let modeEither = "Either"
    /// The picker's only wording about the difference.
    public static let modeSentence = "Balanced covers fewer harmless things and misses more. How much more has not been measured."

    // MARK: Strict cover mode

    public static let strictCoverMode = "Strict cover mode: not in this version"

    // MARK: Pause (allowed only because step 1 has no lock)

    public static let pauseFor15 = "Pause for 15 minutes"
    public static let pauseFor60 = "Pause for 1 hour"
    public static let resume = "Resume covering"

    public static let howItWorks = "How it works…"
    public static let quit = "Quit SafeSight Mac"

    /// The "How it works" screen.
    public static let howItWorksBody: [String] = [
        "SafeSight Mac checks what your displays show, on this Mac only. When it finds an explicit picture, it puts a plain cover over it. Everything else keeps working: your windows, calls, music and code.",
        "It shows every window first and checks it just after. A picture can be seen for a moment before its cover. How long is not measured; the target is under half a second.",
        "Small pictures it is unsure about are blurred instead of covered. When it cannot check a display at all, it covers the whole display and tells you why.",
        "It misses some pictures and wrongly covers others. How many it misses has not been measured, so no accuracy figure is given.",
        "This build contains no networking code. It never writes what it sees to a file, a log or a crash report, keeps no list of what was covered, and tells nobody anything.",
        "This cover-only build has no lock. You can pause or quit it at any time. The lock, with a wait you choose in advance, comes in a later version.",
    ]

    // MARK: The way out (owner, 18 November 2026)

    /// Drawn on every whole-window and whole-display cover, and repeated on the repair card. Covers never take
    /// the keyboard, so these shortcuts reach the app underneath.
    public static let wayOutLine = "Press ⌘W to close this tab, or ⌘[ to go back."
    /// The shortcuts in `wayOutLine`, drawn as key caps.
    public static let wayOutKeys = ["⌘W", "⌘["]

    /// `wayOutLine` cut into plain words and shortcuts, in order. Joined, the pieces give the line exactly.
    public static var wayOutPieces: [(text: String, isKey: Bool)] {
        var out: [(text: String, isKey: Bool)] = []
        var rest = Substring(wayOutLine)
        while !rest.isEmpty {
            let next = wayOutKeys.compactMap { k in rest.firstRange(of: k).map { (k, $0) } }.min { $0.1.lowerBound < $1.1.lowerBound }
            guard let found = next else { out.append((String(rest), false)); break }
            let (key, r) = found
            if r.lowerBound > rest.startIndex { out.append((String(rest[..<r.lowerBound]), false)) }
            out.append((key, true))
            rest = rest[r.upperBound...]
        }
        return out
    }

    // MARK: The repair card

    public static let repairHeading = "SafeSight Mac is covering a display."
    public static let repairDetail = "While it is covered you cannot see other apps on it. Nothing is locked, and nobody is told."
    public static let repairTryAgain = "Try again"
    public static let repairPause = "Pause"
    public static let repairQuit = "Quit"

    /// Phrases the project never uses (README).
    public static let forbiddenPhrases = ["can't be bypassed", "cannot be bypassed", "100%", "blocks all", "treats addiction", "nobody can ever unlock it"]

    /// Every string above, for checks.
    public static var all: [String] {
        [honestPromise, practiceTitle, practiceDetail, notPracticeTitle, keeperFoundDetail, practiceUnknownDetail, statusOn,
         statusNeedsPermission, needsPermissionDetail, grantPermission, statusPaused, statusStarting, statusFault, statusModelsMissing,
         modeHeader, modeBalanced, modeEither, modeSentence, strictCoverMode, pauseFor15, pauseFor60, resume, howItWorks, quit,
         wayOutLine, repairHeading, repairDetail, repairTryAgain, repairPause, repairQuit]
            + howItWorksBody
    }
}
