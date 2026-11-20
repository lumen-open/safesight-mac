// SPDX-License-Identifier: Apache-2.0
// Every sentence the cover-only app shows, in one place, so tests can check it against the project's
// rules: the honest promise word for word, the mode picker's one sentence, and none of the claims the
// project never makes ("can't be bypassed", "100%", "blocks all", "treats addiction",
// "nobody can ever unlock it").

public enum AppText {
    /// The product's name. Every piece of the app's own text that names the product reads it from here, so a
    /// rebrand changes this line, the README's promise (a test compares them) and `packaging/Info.plist`.
    public static let productName = "SafeSight Mac"

    /// The only promise the project may make (README, blueprint chapter 01).
    public static let honestPromise = "\(productName) is free, open-source software that runs entirely on your Mac. It covers explicit images and video on your screen, and once it's on, it stays on until a waiting period you chose ahead of time has passed. If you choose to add a friend, they can shorten that wait, but never to less than a day. Nobody else can, including us. It isn't perfect: wiping your Mac removes it, it can miss something or cover something harmless, and it only protects this Mac. It's an early release built with the help of AI, so keep a backup."

    // MARK: Practice state (SD-223)

    /// The menu's practice-state line, when no keeper is installed.
    public static let practiceTitle = "Practice: no lock"
    public static let practiceDetail = "This is the cover-only build. It has no lock: you can pause it or quit it at any time, and it protects nothing against you. The lock comes in a later version."
    /// When a keeper launch file is present, or the check could not be completed.
    public static let notPracticeTitle = "Not in practice: pause is off"
    public static let keeperFoundDetail = "A \(productName) keeper is installed on this Mac. This cover-only build has no lock and cannot work with a keeper, so pausing is turned off. Covering carries on as usual."
    public static let practiceUnknownDetail = "This build could not check whether a \(productName) keeper is installed, so pausing is turned off. Covering carries on as usual."

    // MARK: Status

    public static let statusOn = "Covering: on"
    public static let statusNeedsPermission = "Needs Screen Recording"
    public static let needsPermissionDetail = "\(productName) needs the Screen Recording permission to check what your displays show. Until you grant it, nothing is checked or covered."
    public static let grantPermission = "Open Screen Recording settings…"
    /// Under the button, the two questions macOS itself asks, so neither is left waiting behind a window or a cover.
    public static let permissionSteps = "macOS asks first: choose Open System Settings in its message, turn \(productName) on, and let macOS quit and reopen it. When it reopens, macOS may ask once more whether it may record the screen directly: choose Allow."
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
    public static let quit = "Quit \(productName)"

    /// The "How it works" window's title.
    public static let howItWorksTitle = "How \(productName) works"
    /// The "How it works" screen.
    public static let howItWorksBody: [String] = [
        "\(productName) checks what your displays show, on this Mac only. When it finds an explicit image or video, it puts a plain cover over it. Everything else keeps working: your windows, calls, music and code.",
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
    public static var wayOutPieces: [(text: String, isKey: Bool)] { pieces(of: wayOutLine, keys: wayOutKeys) }

    /// A line cut into plain words and the shortcuts it names, in order. Joined, the pieces give the line exactly.
    public static func pieces(of line: String, keys: [String]) -> [(text: String, isKey: Bool)] {
        var out: [(text: String, isKey: Bool)] = []
        var rest = Substring(line)
        while !rest.isEmpty {
            let next = keys.compactMap { k in rest.firstRange(of: k).map { (k, $0) } }.min { $0.1.lowerBound < $1.1.lowerBound }
            guard let found = next else { out.append((String(rest), false)); break }
            let (key, r) = found
            if r.lowerBound > rest.startIndex { out.append((String(rest[..<r.lowerBound]), false)) }
            out.append((key, true))
            rest = rest[r.upperBound...]
        }
        return out
    }

    // MARK: The Testing edition (owner, 19 November 2026: a testing mode that is guaranteed to be only that)

    /// The edition's name: its menu, its windows and its bundle (packaging/Testing-Info.plist).
    public static let testingName = "\(productName) Testing"
    /// Carried everywhere the Testing edition shows itself: the menu bar item (as its tooltip and spoken label), the
    /// top of its menu, the repair card, whole-window and whole-display covers, and the "How it works" window.
    public static let testingLine = "Testing edition: no lock. Quit any time with ⌃⌥⌘Q."
    /// The emergency shortcut in `testingLine`, drawn as key caps.
    public static let testingKeys = ["⌃⌥⌘Q"]
    /// The line when macOS would not give this copy ⌃⌥⌘Q (another app holds it): it never names a shortcut that
    /// does not work.
    public static let testingLineNoShortcut = "Testing edition: no lock. Quit any time from its menu bar icon."
    /// The word beside the menu bar icon.
    public static let testingBadge = "Testing"
    /// The menu's edition line and its explanation (in place of the practice state's).
    public static let testingTitle = "Testing edition: no lock"
    public static let testingDetail = "This is the Testing edition, for people helping to test \(productName). It has no lock and installs nothing: no keeper, no login item, and it never asks for your administrator password. macOS keeps it in its own sandbox, so it can't write anywhere but its own folder. Pause it or quit it whenever you like."
    public static let testingShortcutTaken = "Another app is using ⌃⌥⌘Q, so this copy can't. Quit from this menu instead."
    public static let testingShortcutOtherCopy = "Another copy of \(testingName) is using ⌃⌥⌘Q. Quit that copy from its own menu bar icon, and this one takes the shortcut. Until then, quit from this menu."
    /// Shown, and nothing is checked or covered, when the app finds it is not inside the App Sandbox.
    public static let testingNotSandboxed = "Not sandboxed: covering is off"
    public static let testingNotSandboxedDetail = "This copy of the Testing edition is not running inside macOS's App Sandbox, so it checks and covers nothing. Make the app with tools/make-app.sh --testing, or quit it."
    public static let testingAlreadyRunning = "\(testingName) is already running. Look for it in the menu bar."
    public static let testingQuit = "Quit \(testingName)"
    /// The one-click removal of the app's own settings and data.
    public static let testingRemove = "Remove \(testingName)"
    public static let testingRemovedTitle = "\(testingName) has removed its settings and data."
    public static let testingRemovedDetail = "Two things are left, because macOS keeps them. To remove the Screen Recording permission, open Screen Recording settings, select \(testingName) and click the minus button. Then drag \(testingName) to the Trash. macOS also keeps an empty folder for the app's sandbox; the Testing guide says how to remove it."
    public static let testingRemovedOpenSettings = "Open Screen Recording settings"
    public static let testingRemovedShowApp = "Show the app in Finder"
    public static let testingRemovedDone = "Quit"
    /// The Testing report: a window of numbers to copy by hand into a GitHub issue.
    public static let testingReportMenu = "Testing report…"
    public static let testingReportTitle = "\(testingName) report"
    public static let testingReportIntro = "Nothing here leaves your Mac and nothing is saved. To send it, select the text, copy it and paste it into the testing report form on GitHub. It holds numbers about your Mac, its displays and how the app ran, and your note: no pictures, window titles, app names, addresses or anything about what was covered."
    public static let testingReportNoteLabel = "Your note (what happened, in words; it appears in the report below):"
    /// The "How it works" window's title and opening paragraphs in the Testing edition.
    public static let testingHowItWorksTitle = "How \(testingName) works"
    public static let testingHowItWorksBody: [String] = [
        testingLine,
        "This is the Testing edition, for people helping to test \(productName). It has no lock and installs nothing: no keeper, no login item, and it never asks for your administrator password. macOS keeps it in its own sandbox, so it can't write anywhere but its own folder.",
        "To stop it, choose Quit from its menu or press ⌃⌥⌘Q, even when a cover is in the way. Its covers go the moment it quits. To take it off your Mac, choose Remove \(testingName) from its menu, then drag the app to the Trash.",
        "Please test it with what you normally do, and never with explicit material. Tell us when it covers something harmless, when it feels slow, and how it copes with your displays.",
    ]

    /// The edition's line: `testingLine`, or `testingLineNoShortcut` when the shortcut could not be had.
    public static func testingLine(shortcut: Bool) -> String { shortcut ? testingLine : testingLineNoShortcut }
    /// The edition's line cut into words and key caps.
    public static func testingPieces(shortcut: Bool = true) -> [(text: String, isKey: Bool)] {
        pieces(of: testingLine(shortcut: shortcut), keys: shortcut ? testingKeys : [])
    }

    /// The "How it works" paragraphs of an edition. The Testing edition opens with its own and leaves out the
    /// paragraph that promises a lock later: it never gets one.
    public static func howItWorksParagraphs(_ edition: Edition) -> [String] {
        switch edition {
        case .standard: return howItWorksBody
        case .testing: return testingHowItWorksBody + howItWorksBody.filter { !$0.contains("comes in a later version") }
        }
    }

    /// The "How it works" window's title in an edition.
    public static func howItWorksWindowTitle(_ edition: Edition) -> String {
        edition == .testing ? testingHowItWorksTitle : howItWorksTitle
    }

    /// Every Testing edition string, for checks.
    public static var testingAll: [String] {
        [testingName, testingLine, testingLineNoShortcut, testingBadge, testingTitle, testingDetail, testingShortcutTaken,
         testingShortcutOtherCopy, testingNotSandboxed, testingNotSandboxedDetail, testingAlreadyRunning, testingQuit, testingRemove,
         testingRemovedTitle, testingRemovedDetail, testingRemovedOpenSettings, testingRemovedShowApp, testingRemovedDone,
         testingHowItWorksTitle, testingReportMenu, testingReportTitle, testingReportIntro, testingReportNoteLabel] + testingHowItWorksBody
    }

    // MARK: The repair card

    public static let repairHeading = "\(productName) is covering a display."
    public static let repairDetail = "While it is covered you cannot see other apps on it. Nothing is locked, and nobody is told."
    public static let repairTryAgain = "Try again"
    public static let repairPause = "Pause"
    public static let repairQuit = "Quit"

    /// Phrases the project never uses (README).
    public static let forbiddenPhrases = ["can't be bypassed", "cannot be bypassed", "100%", "blocks all", "treats addiction", "nobody can ever unlock it"]

    /// Every string above, for checks.
    public static var all: [String] {
        [honestPromise, practiceTitle, practiceDetail, notPracticeTitle, keeperFoundDetail, practiceUnknownDetail, statusOn,
         statusNeedsPermission, needsPermissionDetail, grantPermission, permissionSteps, statusPaused, statusStarting, statusFault, statusModelsMissing,
         modeHeader, modeBalanced, modeEither, modeSentence, strictCoverMode, pauseFor15, pauseFor60, resume, howItWorks, quit,
         howItWorksTitle, wayOutLine, repairHeading, repairDetail, repairTryAgain, repairPause, repairQuit]
            + howItWorksBody + testingAll
    }
}
