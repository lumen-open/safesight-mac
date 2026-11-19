# SPDX-License-Identifier: Apache-2.0
"""Source half of tools/check-testing-edition.sh: a tripwire for honest mistakes, not a proof.

The binary scan there cannot see short string literals (Swift keeps a string of 15 bytes or fewer, such as
"/bin/launchctl", inside the instructions), so this reads the source of every module the Testing app is built from, as
the Testing build compiles it:
- comments are dropped; code the Testing build leaves out (`#if !SAFESIGHTMAC_TESTING`, `#if SAFESIGHTMAC_LAB`, ...)
  is skipped, and any other condition counts as compiled in, so nothing is skipped on a guess;
- a `#if` written inside a string literal is text, not a condition;
- the whole compiled text is matched at once, so a call split over lines (`d.write(` then `to: u)`) is still seen;
- a name may carry its module (`Darwin.posix_spawn`, `Foundation.Process()`).

Someone who sets out to hide a capability from a text scan can still do it (a name put together at run time, say).
The scan is there to stop honest mistakes; the App Sandbox is the boundary that holds either way.

Usage: testing_edition_scan.py FOLDER...     (each target's declared folder, from `swift package describe`)
       testing_edition_scan.py --self-test   (the scanner checks itself on made-up files first)
"""
import os
import re
import sys

FLAGS = {"SAFESIGHTMAC_TESTING": True, "SAFESIGHTMAC_LAB": False, "KESTREL_LAB": False}

# A name may be written with its module in front of it, and a method follows a dot: only a letter, digit or underscore
# just before a name makes it part of another name.
MODULES = r"(?:Darwin|Glibc|Foundation|CoreFoundation|ObjectiveC|AppKit|Cocoa|Carbon|CoreServices|ServiceManagement|" \
          r"Security|IOKit|Dispatch|CoreGraphics|ScreenCaptureKit|os|Swift)\."
QUALIFIED = r"(?<!\w)(?:" + MODULES + r")?"

# Each rule: its name and what it matches. A rule ending in "(" needs a call; others match the whole name.
RULES = [
    # Running another program, signalling or inspecting other processes.
    ("spawn", r"posix_spawnp?\b|NSTask\b|Process\s*\(|executableURL\b|launchPath\b|v?fork\s*\(|exec[lv]\w*\s*\(|popen\b|"
              r"system\s*\(|kill(?:pg)?\s*\(|ptrace\b|task_for_pid\b"),
    # Installing, registering or reaching launchd services, login items, extensions.
    ("install", r"SMAppService\b|SMJob\w*|SMLoginItem\w*|LSSharedFileList\w*|OSSystemExtension\w*|KextManager\w*|"
                r"es_new_client\b|enableRelaunchOnLogin\b|launch_msg\b|bootstrap_look_up\w*"),
    # Administrator rights, the keychain, accounts and owners.
    ("admin", r"Authorization\w+|SFAuthorization\w*|SecKeychain\w*|SecItem\w*|SecTrustSettingsSet\w*|CSIdentity\w*|"
              r"OD(?:Node|Record|Session|Query)\b|CB(?:User)?Identity\b|set(?:e|re)?[ug]id\b|[lf]?chown\b"),
    # Apple events and scripts, which can drive other apps.
    ("apple-events", r"NSAppleScript\b|NSUser\w*Task\b|OSAScript\b|AESendMessage\b|AECreateAppleEvent\b|SBApplication\b"),
    ("xpc", r"NSXPC\w+|xpc_\w+"),
    # Reaching code by name, which no scan could follow.
    ("by-name", r"dlopen\b|dlsym\b|NSClassFromString\b|NSSelectorFromString\b|objc_getClass\b|objc_lookUpClass\b|"
                r"sel_registerName\b|CFBundleGetFunctionPointer\w*|CFBundleGetDataPointer\w*|CFBundleLoadExecutable\w*|"
                r"CFBundleCreate\w*|classNamed\b|loadAndReturnError\b|principalClass\b"),
    # Recording or handing out pictures of the screen.
    ("record", r"CGImageDestination\w*|AVAssetWriter\w*|SCRecordingOutput\b|SCScreenshotManager\b|NSPasteboard\b|"
               r"CGWindowListCreateImage\b|CGDisplayCreateImage\b"),
    # Taking the screen, the keyboard or the pointer; changing power or hardware settings.
    ("takeover", r"CGDisplayCapture\w*|CGCaptureAllDisplays\w*|CGShieldingWindow\w*|SetSystemUIMode\b|presentationOptions\b|"
                 r"CGEventTapCreate\w*|CGEventPost\w*|CGWarpMouseCursorPosition\b|CGDisplayHideCursor\b|"
                 r"CGAssociateMouseAndMouseCursorPosition\b|IOPM\w+|IORegistryEntrySet\w*|enterFullScreenMode\b|"
                 r"addGlobalMonitorForEvents\w*"),
    # Other apps and their settings.
    ("other-apps", r"setDesktopImageURL\b|setPersistentDomain\b|forceTerminate\b|CFPreferencesSet\w*|"
                   r"UserDefaults\s*\(\s*suiteName\b|LSOpen\w*|LSRegisterURL\b|launchApplication\w*|openApplication\w*|"
                   r"NSWorkspace\.shared\.open\s*\("),
    # Writing data to files, or making, moving or linking them.
    ("write", r"write\s*\(|pwrite\w*\s*\(|writev\s*\(|fwrite\b|fopen\b|FileHandle\s*\(\s*for(?:Writing|Updating)\w*|"
              r"createFile\s*\(|OutputStream\b|NSOutputStream\b|O_(?:CREAT|WRONLY|RDWR|APPEND|TRUNC)\b|mkdir\s*\(|"
              r"rename\s*\(|symlink\s*\(|link\s*\(|f?truncate\s*\("),
    ("make-move", r"moveItem\b|copyItem\b|replaceItem\w*|linkItem\b|createSymbolicLink\b|createDirectory\b"),
    ("delete", r"removeItem\b|trashItem\b|unlink\s*\(|rmdir\s*\(|removefile\b"),
    # Names of windows and apps: the Testing report, and everything else, carries none.
    ("names", r"kCGWindowName\b|kCGWindowOwnerName\b|localizedName\b|frontmostApplication\b|menuBarOwningApplication\b"),
]
# Member calls, matched with their dot: writing through Data, String or NSData, and recycling through NSWorkspace.
MEMBER_RULES = [
    ("write", r"\.write\s*\(\s*(?:to|toFile|atomically)\b"),
    ("other-apps", r"\.recycle\s*\("),
]
IMPORTS = ["ServiceManagement", "SystemExtensions", "Security", "SecurityFoundation", "SecurityInterface",
           "OpenDirectory", "Collaboration", "EndpointSecurity", "NetworkExtension", "Network", "WebKit", "IOKit",
           "AVFoundation", "ScriptingBridge", "OSAKit", "LocalAuthentication", "AuthenticationServices"]
WORDS = ["launchctl", "LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools", "StartupItems", "LoginItems",
         "RunAtLoad", "KeepAlive", "ProgramArguments", "BundleProgram", "SMPrivilegedExecutables", "sudo", "osascript",
         "dscl", "sysadminctl", "dseditgroup", "pwpolicy", "createhomedir", "kickstart", "tccutil", "spctl", "csrutil",
         "systemsetup", "mobileconfig", "administrator privileges"]
PATH = re.compile(r'"(/(?:Library|System|usr|bin|sbin|etc|private|var|opt|Applications)/[^"]*)"')

# Lines allowed although they match: the Screen Recording settings, opened when the person asks.
ALLOWED_LINES = {
    'if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }',
}
# Rules allowed in one file each: the compiled-model cache is the one place that makes and moves files, and the
# removal the one place that deletes them (inside the container only).
ALLOWED_IN = {
    "Sources/DetectorCore/CompiledModels.swift": {"make-move", "delete"},
    "Sources/SafeSightMacTestingEdition/Removal.swift": {"delete"},
}

COMPILED = [(name, re.compile(QUALIFIED + r"(?:" + rx + r")")) for name, rx in RULES] + \
           [(name, re.compile(rx)) for name, rx in MEMBER_RULES]
IMP = re.compile(r"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:" + "|".join(IMPORTS) + r")\b", re.MULTILINE)
WORD = re.compile(r"\b(?:" + "|".join(re.escape(w) for w in WORDS) + r")\b", re.IGNORECASE)


def is_string_start(src, i):
    """Whether a string literal starts at i: optional #s (a raw string), then a quote."""
    while i < len(src) and src[i] == "#":
        i += 1
    return i < len(src) and src[i] == '"'


def string_end(src, i):
    """The index just after the string literal that starts at i: plain, multi-line (triple quotes) or raw (#"..."#),
    with interpolations (backslash-paren, or backslash-#-paren in raw strings), which may hold strings of their own."""
    n, h = len(src), 0
    while i + h < n and src[i + h] == "#":
        h += 1
    j = i + h
    multi = src.startswith('"""', j)
    j += 3 if multi else 1
    close, esc = ('"""' if multi else '"') + "#" * h, "\\" + "#" * h
    while j < n:
        if src.startswith(close, j):
            return j + len(close)
        if src.startswith(esc, j):
            k = j + len(esc)
            j = interpolation_end(src, k + 1) if k < n and src[k] == "(" else k + 1
            continue
        if not multi and src[j] == "\n":
            return j
        j += 1
    return n


def interpolation_end(src, i):
    """The index just after the parenthesis that closes an interpolation whose code starts at i."""
    depth, j, n = 1, i, len(src)
    while j < n:
        if is_string_start(src, j):
            j = string_end(src, j)
            continue
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def lex(src):
    """Two views of the source with the same lines: the code (comments dropped, string literals kept), and the same
    with string literals blanked, which is where `#if` lines are looked for."""
    code, plain, i, n = [], [], 0, len(src)
    while i < n:
        if is_string_start(src, i):
            j = string_end(src, i)
            code.append(src[i:j])
            plain.append("".join("\n" if c == "\n" else " " for c in src[i:j]))
            i = j
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif src.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            breaks = "\n" * src.count("\n", i, j)
            code.append(breaks); plain.append(breaks); i = j
        else:
            code.append(src[i]); plain.append(src[i]); i += 1
    return "".join(code), "".join(plain)


def condition(expr):
    """True, False, or None (unknown) for an #if condition."""
    e = expr.strip()
    if e.startswith("(") and e.endswith(")"):
        return condition(e[1:-1])
    for op, combine in (("||", any), ("&&", all)):
        if op in e:
            parts = [condition(p) for p in e.split(op)]
            if all(p is not None for p in parts):
                return combine(parts)
            if op == "||" and any(p is True for p in parts):
                return True
            if op == "&&" and any(p is False for p in parts):
                return False
            return None
    if e.startswith("!"):
        v = condition(e[1:])
        return None if v is None else not v
    return FLAGS.get(e)


def active_lines(plain):
    """For each line: whether the Testing build compiles it (directive lines themselves count as not)."""
    stack, out = [], []   # each: [this branch active, a branch already taken, condition known]
    for line in plain.split("\n"):
        s = line.strip()
        active = all(f[0] for f in stack)
        directive = True
        if s.startswith("#if ") or s.startswith("#if("):
            v = condition(s[3:])
            stack.append([v is not False, v is True, v is not None])
        elif s.startswith("#elseif"):
            f = stack[-1]
            v = condition(s[7:])
            if f[2] and v is not None:
                f[0] = not f[1] and v; f[1] = f[1] or f[0]
            else:
                f[0] = True; f[2] = False
        elif s.startswith("#else"):
            f = stack[-1]
            f[0] = not f[1] if f[2] else True
        elif s.startswith("#endif"):
            stack.pop()
        else:
            directive = False
        out.append(active and not directive)
    return out


def scan_text(path, text):
    """Findings in one source file: (path, line, rule, what matched)."""
    code, plain = lex(text)
    lines = code.split("\n")
    compiled = "\n".join(l if keep else "" for l, keep in zip(lines, active_lines(plain)))
    allowed = next((rules for suffix, rules in ALLOWED_IN.items() if path.replace(os.sep, "/").endswith(suffix)), set())

    def line_of(pos):
        return compiled.count("\n", 0, pos) + 1

    found = []
    for name, rx in COMPILED:
        if name in allowed:
            continue
        for m in rx.finditer(compiled):
            k = line_of(m.start())
            if lines[k - 1].strip() in ALLOWED_LINES:
                continue
            found.append((path, k, name, " ".join(m.group(0).split())))
    for m in IMP.finditer(compiled):
        found.append((path, line_of(m.start()), "import", m.group(0).strip()))
    for m in WORD.finditer(compiled):
        found.append((path, line_of(m.start()), "word", m.group(0)))
    for m in PATH.finditer(compiled):
        found.append((path, line_of(m.start()), "system path", m.group(1)))
    return sorted(set(found))


# Made-up files and what the scan must say about each: every (rule, text) pair listed must be reported, the text found
# in what was matched; an empty set means nothing may be reported. They include the shapes an independent review used
# to get past the first version of this scan.
PROBES = [
    ("A comment is not code", "Probe.swift",
     '// launchctl, SMAppService, Process() and posix_spawn in a comment\n/* nested /* block */ naming osascript */\nlet a = 1\n', set()),
    ("An import", "Probe.swift", "import Foundation\n@preconcurrency import ServiceManagement\n",
     {("import", "ServiceManagement")}),
    ("Compiled-out code is skipped", "Probe.swift",
     '#if !SAFESIGHTMAC_TESTING\nlet p = "/Library/LaunchDaemons"\n#endif\n#if SAFESIGHTMAC_LAB\nlet s = "sudo"\n#endif\n', set()),
    ("The Testing branch and an unknown condition count", "Probe.swift",
     '#if !SAFESIGHTMAC_TESTING\nlet a = 1\n#else\nlet p = Process()\n#endif\n#if DEBUG\nlet k = "/bin/launchctl"\n#endif\n',
     {("spawn", "Process("), ("word", "launchctl"), ("system path", "/bin/launchctl")}),
    ("An #elseif for the Testing build counts", "Probe.swift",
     '#if SAFESIGHTMAC_LAB\nlet a = 1\n#elseif SAFESIGHTMAC_TESTING\nfunc f() { try? SMAppService.mainApp.register() }\n#endif\n',
     {("install", "SMAppService")}),
    ("A // inside an interpolated string is not a comment", "Probe.swift",
     'let t = "a \\(f("//")) b"; let x = dlopen(nil, 0)\n', {("by-name", "dlopen")}),
    ("A raw string with // in it", "Probe.swift",
     'let r = #"a "quoted" // text"#; let c = NSClassFromString("NSTask")\n', {("by-name", "NSClassFromString"), ("spawn", "NSTask")}),
    ("A write split over two lines", "Probe.swift", "let d = Data()\ntry d.write(\n    to: u)\n", {("write", ".write( to")}),
    ("open with O_CREAT, then Darwin.write", "Probe.swift",
     "let fd = open(path, O_CREAT | O_WRONLY, 0o644)\n_ = Darwin.write(fd, buffer, count)\n",
     {("write", "O_CREAT"), ("write", "O_WRONLY"), ("write", "Darwin.write(")}),
    ("Module-qualified names", "Probe.swift",
     "_ = Darwin.posix_spawn(&pid, path, nil, nil, argv, nil)\nlet p = Foundation.Process()\n",
     {("spawn", "Darwin.posix_spawn"), ("spawn", "Foundation.Process(")}),
    ("A function found by name in a bundle", "Probe.swift",
     'let f = CFBundleGetFunctionPointerForName(bundle, "posix_spawn" as CFString)\n'
     'let s = ProcessInfo.processInfo.environment["SHELL"] ?? ""\n',
     {("by-name", "CFBundleGetFunctionPointerForName"), ("spawn", "posix_spawn")}),
    ("Classes and code loaded by name", "Probe.swift",
     'let c = Bundle.main.classNamed("X")\ntry other.loadAndReturnError()\n_ = CFBundleLoadExecutable(b)\nlet k = b.principalClass\n',
     {("by-name", "classNamed"), ("by-name", "loadAndReturnError"), ("by-name", "CFBundleLoadExecutable"), ("by-name", "principalClass")}),
    ("launchd and bootstrap lookups", "Probe.swift", "_ = launch_msg(nil)\n_ = bootstrap_look_up(port, name, &out)\n",
     {("install", "launch_msg"), ("install", "bootstrap_look_up")}),
    ("#if inside a multi-line string is text", "Probe.swift",
     'let note = """\n#if !SAFESIGHTMAC_TESTING\n"""\nlet p = Process()\nlet q = """\n#endif\n"""\n', {("spawn", "Process(")}),
    ("Making and moving files outside the compiled-model cache", "Probe.swift",
     "try FileManager.default.moveItem(at: a, to: b)\ntry FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)\n"
     "try FileManager.default.copyItem(at: a, to: b)\n",
     {("make-move", "moveItem"), ("make-move", "createDirectory"), ("make-move", "copyItem")}),
    ("Making and moving files inside the compiled-model cache", "Sources/DetectorCore/CompiledModels.swift",
     "try FileManager.default.moveItem(at: a, to: b)\ntry? FileManager.default.removeItem(at: c)\n", set()),
    ("Deleting outside the removal", "Probe.swift", "try FileManager.default.removeItem(at: a)\n_ = unlink(p)\n",
     {("delete", "removeItem"), ("delete", "unlink(")}),
    ("The one allowed NSWorkspace line, and another", "Probe.swift",
     'if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }\n'
     'NSWorkspace.shared.open(URL(fileURLWithPath: other))\n', {("other-apps", "NSWorkspace.shared.open(")}),
    ("Kiosk mode and other apps' settings", "Probe.swift",
     "NSApp.presentationOptions = [.disableForceQuit]\nUserDefaults(suiteName: \"com.apple.dock\")?.set(1, forKey: \"k\")\n",
     {("takeover", "presentationOptions"), ("other-apps", "UserDefaults(suiteName")}),
    ("Window titles and app names", "Probe.swift",
     "let t = info[kCGWindowName as String]\nlet o = info[kCGWindowOwnerName as String]\nlet n = NSWorkspace.shared.frontmostApplication?.localizedName\n",
     {("names", "kCGWindowName"), ("names", "kCGWindowOwnerName"), ("names", "frontmostApplication"), ("names", "localizedName")}),
    ("Paths and launchd words in strings", "Probe.swift",
     'let a = "/usr/local/bin/x"\nlet b = "\\(home)/Library/LaunchAgents/x.plist"\n',
     {("system path", "/usr/local/bin/x"), ("word", "LaunchAgents")}),
]


def self_test():
    bad = []
    for title, path, src, want in PROBES:
        got = [(rule, what) for _, _, rule, what in scan_text(path, src)]
        missing = [w for w in want if not any(r == w[0] and w[1] in t for r, t in got)]
        if missing or (not want and got):
            bad.append("%s: missing %s, got %s" % (title, missing or "nothing", got or "nothing"))
    for b in bad:
        print("FAIL: the source scanner's self-test: " + b)
    if bad:
        return 1
    print("Source scanner self-test: %d made-up files, the review's shapes among them, read as expected" % len(PROBES))
    return 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    found, files = [], 0
    for folder in sys.argv[1:]:
        if not os.path.isdir(folder):
            print("FAIL: no such folder to scan: %s" % folder)
            return 1
        for dirpath, _, names in os.walk(folder):
            for name in sorted(names):
                if not name.endswith(".swift"):
                    continue
                files += 1
                path = os.path.join(dirpath, name)
                found += scan_text(path, open(path, encoding="utf-8").read())
    for path, line, rule, what in found:
        print("FAIL: %s:%d: %s %r" % (path, line, rule, what))
    if found:
        return 1
    print("Sources: %d files in %d folders, as the Testing build compiles them, name none of it" % (files, len(sys.argv) - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
