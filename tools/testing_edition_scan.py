# SPDX-License-Identifier: Apache-2.0
"""Source half of tools/check-testing-edition.sh.

The binary scan there cannot see short string literals: Swift keeps a string of 15 bytes or fewer (such as
"/bin/launchctl") inside the instructions, not in the binary's string table. So this scans the source of every
module the Testing app is built from, as the Testing build compiles it: comments are dropped, and code that the
Testing build leaves out (`#if !SAFESIGHTMAC_TESTING`, `#if SAFESIGHTMAC_LAB`, ...) is skipped. Any other
condition counts as compiled in, so nothing is skipped on a guess.

Usage: testing_edition_scan.py SOURCES_DIR MODULE...
       testing_edition_scan.py --self-test     (the scanner checks itself on a made-up file first)
"""
import os
import re
import sys

FLAGS = {"SAFESIGHTMAC_TESTING": True, "SAFESIGHTMAC_LAB": False, "KESTREL_LAB": False}

# APIs and words that have no place in the Testing app (see check-testing-edition.sh for why).
APIS = [
    r"SMAppService", r"SMJob\w*", r"SMLoginItem\w*", r"LSSharedFileList\w*", r"Authorization\w+", r"SFAuthorization\w*",
    r"SecKeychain\w*", r"SecItem\w*", r"SecTrustSettingsSet\w*", r"OSSystemExtension\w*", r"KextManager\w*",
    r"es_new_client", r"CSIdentity\w*", r"OD(Node|Record|Session|Query)", r"CB(User)?Identity", r"set(e|re)?[ug]id",
    r"[lf]?chown", r"posix_spawnp?", r"NSTask", r"Process\s*\(", r"executableURL", r"launchPath", r"NSAppleScript",
    r"NSUser\w*Task", r"OSAScript", r"AESendMessage", r"AECreateAppleEvent", r"SBApplication", r"NSXPC\w+",
    r"xpc_connection\w*", r"CGImageDestination\w*", r"AVAssetWriter\w*", r"SCRecordingOutput", r"NSPasteboard",
    r"CGWindowListCreateImage", r"CGDisplayCreateImage", r"CGDisplayCapture\w*", r"CGCaptureAllDisplays\w*",
    r"CGShieldingWindow\w*", r"SetSystemUIMode", r"presentationOptions", r"CGEventTapCreate\w*", r"CGEventPost\w*",
    r"CGWarpMouseCursorPosition", r"CGDisplayHideCursor", r"CGAssociateMouseAndMouseCursorPosition", r"IOPM\w+",
    r"IORegistryEntrySet\w*", r"setDesktopImageURL", r"setPersistentDomain", r"forceTerminate", r"kill", r"killpg",
    r"ptrace", r"task_for_pid", r"fork", r"vfork", r"execv\w*", r"execl\w*", r"popen", r"system\s*\(",
    # Reaching code by name, which no scan could follow.
    r"dlopen", r"dlsym", r"NSClassFromString", r"NSSelectorFromString", r"objc_getClass", r"objc_lookUpClass",
    r"sel_registerName",
    # Watching other apps' keys, starting again at login, other apps' settings, opening other apps, screenshots,
    # taking over the screen.
    r"addGlobalMonitorForEvents\w*", r"enableRelaunchOnLogin", r"CFPreferencesSet\w*", r"UserDefaults\s*\(\s*suiteName",
    r"LSOpen\w*", r"LSRegisterURL", r"launchApplication\w*", r"openApplication\w*", r"\.recycle\(", r"SCScreenshotManager",
    r"enterFullScreenMode",
    # Writing data to files: the app writes no file of its own (its settings go through UserDefaults).
    r"\.write\(\s*to", r"write\(\s*toFile", r"FileHandle\s*\(\s*for(Writing|Updating)\w*", r"createFile\s*\(",
    r"fopen", r"fwrite", r"OutputStream", r"NSOutputStream",
    # Opening anything with NSWorkspace, except the one line that opens the Screen Recording settings.
    r"NSWorkspace\.shared\.open\(",
]
# Lines allowed although they match: the Screen Recording settings, opened when the person asks.
ALLOWED = {
    'if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }',
}
IMPORTS = ["ServiceManagement", "SystemExtensions", "Security", "SecurityFoundation", "SecurityInterface",
           "OpenDirectory", "Collaboration", "EndpointSecurity", "NetworkExtension", "Network", "WebKit", "IOKit",
           "AVFoundation", "ScriptingBridge", "OSAKit", "LocalAuthentication", "AuthenticationServices"]
WORDS = ["launchctl", "LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools", "StartupItems", "LoginItems",
         "RunAtLoad", "KeepAlive", "ProgramArguments", "BundleProgram", "SMPrivilegedExecutables", "sudo", "osascript",
         "dscl", "sysadminctl", "dseditgroup", "pwpolicy", "createhomedir", "kickstart", "tccutil", "spctl", "csrutil",
         "systemsetup", "mobileconfig", "administrator privileges"]
PATH = re.compile(r'"(/(Library|System|usr|bin|sbin|etc|private|var|opt|Applications)/[^"]*)"')


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
        if is_string_start(src, j) and (src[j] == '"' or src[j] == "#"):
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


def strip_comments(src):
    """Drops // and /* */ comments (which nest in Swift), keeping string literals, and line breaks, as they are."""
    out, i, n = [], 0, len(src)
    while i < n:
        if is_string_start(src, i):
            j = string_end(src, i)
            out.append(src[i:j]); i = j
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
            out.append("\n" * src.count("\n", i, j)); i = j
        else:
            out.append(src[i]); i += 1
    return "".join(out)


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


def compiled_lines(code):
    """The lines the Testing build compiles (unknown conditions: both branches)."""
    stack, out = [], []   # each: [this branch active, a branch already taken, condition known]
    for line in code.split("\n"):
        s = line.strip()
        active = all(f[0] for f in stack)
        directive = True
        if s.startswith("#if "):
            v = condition(s[4:])
            stack.append([v is not False, v is True, v is not None])
        elif s.startswith("#elseif "):
            f = stack[-1]
            v = condition(s[8:])
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
        out.append(line if active and not directive else "")   # one entry per line, so line numbers stay right
    return out


API = re.compile(r"(?<![\w.])(?:" + "|".join(a if a.endswith(r"\(") else a + r"\b" for a in APIS) + r")"
                 r"|(?<=\w)\.recycle\(|(?<=\.)write\(\s*to\b")
IMP = re.compile(r"^\s*(@\w+\s+)*import\s+(" + "|".join(IMPORTS) + r")\b")
WORD = re.compile(r"\b(" + "|".join(re.escape(w) for w in WORDS) + r")\b", re.IGNORECASE)


def scan_text(path, text):
    found = []
    for k, line in enumerate(compiled_lines(strip_comments(text)), 1):
        if line.strip() in ALLOWED:
            continue
        for rx, what in ((API, "API"), (IMP, "import"), (WORD, "word")):
            for hit in rx.finditer(line):
                found.append("%s:%d: %s %r" % (path, k, what, hit.group(0).strip()))
        for hit in PATH.finditer(line):
            found.append("%s:%d: system path %r" % (path, k, hit.group(1)))
    return found


PROBE = r'''import Foundation
import ServiceManagement
// A comment naming launchctl, SMAppService and Process() is not code.
/* nested /* block */ naming osascript */
#if !SAFESIGHTMAC_TESTING
let skipped = "/Library/LaunchDaemons"
#else
let p = Process()
#endif
#if DEBUG
let unknown = "/bin/launchctl"
#endif
#if SAFESIGHTMAC_LAB
let lab = "sudo"
#elseif SAFESIGHTMAC_TESTING
func f() { try? SMAppService.mainApp.register(); _ = "kickstart" }
#endif
let tricky = "a \(f("//")) b"; let x = dlopen(nil, 0)
let raw = #"a "quoted" // not a comment"#; let c = NSClassFromString("X")
let url = "x // y"; try data.write(to: url)
NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Other.app"))
if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
'''
PROBE_EXPECTED = {(2, "import"), (8, "API"), (11, "word"), (11, "system path"), (16, "API"), (16, "word"), (18, "API"),
                  (19, "API"), (20, "API"), (21, "API"), (21, "system path")}


def self_test():
    kinds = ("system path", "import", "API", "word")
    got = {(int(f.split(":")[1]), next(k for k in kinds if f.split(": ", 1)[1].startswith(k + " ")))
           for f in scan_text("probe", PROBE)}
    if got != PROBE_EXPECTED:
        print("FAIL: the source scanner's self-test: missing %s, unexpected %s" % (sorted(PROBE_EXPECTED - got), sorted(got - PROBE_EXPECTED)))
        return 1
    print("Source scanner self-test: a made-up file's comments, compiled-out code and allowed line are told apart")
    return 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    root, modules = sys.argv[1], sys.argv[2:]
    found, files = [], 0
    for m in modules:
        for dirpath, _, names in os.walk(os.path.join(root, m)):
            for name in sorted(names):
                if not name.endswith(".swift"):
                    continue
                files += 1
                path = os.path.join(dirpath, name)
                found += scan_text(path, open(path, encoding="utf-8").read())
    for f in found:
        print("FAIL: " + f)
    if found:
        return 1
    print("Sources: %d files in %d modules, as the Testing build compiles them, name none of it" % (files, len(modules)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
