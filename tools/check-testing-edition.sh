#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Checks the Testing edition's guarantees on what is actually built (docs/TESTING-EDITION.md), the way
# check-no-standin.sh checks release builds:
#  1. Its app is built from the modules it should be, and no others: no lock, keeper, installer or helper module,
#     and no outside package, can slip in.
#  2. Its binary links no framework and names no function, class or path that could install a launch daemon or
#     agent, a login item, a privileged helper, a system extension or a profile; create an account or change a
#     password; ask for an administrator or use the keychain; run another program or script; reach the network;
#     save a picture of the screen; or take the screen, the keyboard or the pointer away from the person.
#  3. Its bundle is a plain app (nothing in it that macOS would install or start), with the Testing name and an
#     identifier ending in .testing, signed with exactly one entitlement: the App Sandbox.
#  4. The release app contains no part of the Testing edition (no emergency quit), and no Testing build is a lab
#     build.
# Writes only under .build-testing/ and a temporary folder it removes. Installs nothing, runs nothing it builds.
#
# Usage: tools/check-testing-edition.sh            builds the Testing app (without models) and checks it
#        tools/check-testing-edition.sh APP        also checks APP, an assembled "SafeSight Mac Testing.app" (with
#                                                  its models, signed ad hoc or with Developer ID): run it on every
#                                                  copy before it reaches anyone
set -eu
given="${1:-}"
if [ -n "$given" ]; then
  [ -d "$given" ] || { echo "FAIL: no app at $given"; exit 1; }
  given="$(cd "$(dirname "$given")" && pwd)/$(basename "$given")"
fi
cd "$(dirname "$0")/.."
unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
scratch=.build-testing
tmp=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-testing-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# 1. The modules the Testing app is made of, and the folders their sources come from.
SAFESIGHTMAC_TESTING=1 swift package describe --type json > "$tmp/describe.json"
python3 - "$tmp/describe.json" "$tmp/modules.txt" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
targets = {t["name"]: t for t in d["targets"]}
allowed = {"SafeSightMacApp", "SafeSightMacCore", "SafeSightMacWatcher", "SafeSightMacCapture", "SafeSightMacCover",
           "SafeSightMacTestingEdition", "DetectorCore", "Preprocess", "RegionFinder"}
seen, todo = set(), ["SafeSightMacApp"]
while todo:
    n = todo.pop()
    if n in seen: continue
    seen.add(n)
    t = targets[n]
    if t.get("product_dependencies"):
        print("FAIL: %s depends on an outside package: %s" % (n, t["product_dependencies"])); sys.exit(1)
    todo += t.get("target_dependencies", [])
if seen != allowed:
    print("FAIL: the Testing app's modules changed. Added: %s. Missing: %s." % (sorted(seen - allowed), sorted(allowed - seen)))
    print("A module added to the Testing app must be reviewed and listed here, in tools/check-testing-edition.sh.")
    sys.exit(1)
if d.get("dependencies"):
    print("FAIL: the package depends on outside packages: %s" % d["dependencies"]); sys.exit(1)
# What each target is made of: only its declared folder, no build-tool plugin (which could generate code) and no
# resources (which could carry a launchd file). A key describe does not use today, such as one for plugins or
# resources, fails the check until it is looked at.
known = {"c99name", "module_type", "name", "path", "product_memberships", "sources", "target_dependencies", "type"}
plugins = [t["name"] for t in d["targets"] if t.get("type") == "plugin"]
if plugins:
    print("FAIL: the package has build-tool plugins: %s" % plugins); sys.exit(1)
paths = []
for n in sorted(seen):
    t = targets[n]
    extra = sorted(k for k in t if k not in known and t[k])
    if extra:
        print("FAIL: %s declares %s; look at it before the Testing app may use it" % (n, extra)); sys.exit(1)
    path = t.get("path", "")
    if not path or path.startswith("/") or ".." in path.split("/"):
        print("FAIL: %s has the path %r, outside the package" % (n, path)); sys.exit(1)
    paths.append(path)
open(sys.argv[2], "w").write("\n".join(paths) + "\n")
print("Modules: the Testing app is built from %d known modules and no outside package" % len(seen))
EOF

# Their sources, as the Testing build compiles them (short string literals never reach the binary's strings). The
# scanner first checks itself on a made-up file.
python3 tools/testing_edition_scan.py --self-test || fail=1
# shellcheck disable=SC2046
python3 tools/testing_edition_scan.py $(cat "$tmp/modules.txt") || fail=1

# The screen path is the release app's, line for line: the detector, its rules and thresholds, capture and the cover
# drawing are the same sources in both apps. In those modules only the keeper check may depend on the edition; the
# Testing line reaches the covers as a parameter. And the release app is built from the same modules, less one.
screen="Sources/DetectorCore Sources/Preprocess Sources/RegionFinder Sources/SafeSightMacWatcher Sources/SafeSightMacCapture Sources/SafeSightMacCover"
# shellcheck disable=SC2086
drift=$(grep -rlE 'SAFESIGHTMAC_TESTING|BuildInfo\.edition' $screen | grep -v '^Sources/SafeSightMacWatcher/PracticeState\.swift$' || true)
[ -z "$drift" ] || bad "the screen path depends on the edition in: $drift"
swift package describe --type json > "$tmp/describe-release.json"
python3 - "$tmp/describe.json" "$tmp/describe-release.json" <<'EOF' || fail=1
import json, sys
def closure(path):
    targets = {t["name"]: t for t in json.load(open(path))["targets"]}
    seen, todo = set(), ["SafeSightMacApp"]
    while todo:
        n = todo.pop()
        if n not in seen:
            seen.add(n); todo += targets[n].get("target_dependencies", [])
    return seen
testing, release = closure(sys.argv[1]), closure(sys.argv[2])
if testing - {"SafeSightMacTestingEdition"} != release:
    print("FAIL: the two apps' modules differ by more than SafeSightMacTestingEdition: %s" % sorted(testing ^ release)); sys.exit(1)
print("Same screen path: both apps build the same %d modules, and the Testing app adds only its own" % len(release))
EOF

# 2. The binary.
SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --product safesight-mac >/dev/null
tools/make-app.sh --testing --no-models org.example.safesightmac.testing "$tmp" >"$tmp/make.txt" 2>&1 \
  || { cat "$tmp/make.txt"; echo "FAIL: the Testing app could not be assembled"; exit 1; }
app="${given:-$tmp/SafeSight Mac Testing.app}"
bin="$app/Contents/MacOS/safesight-mac"
[ -x "$bin" ] || { echo "FAIL: no Testing app was assembled"; exit 1; }

# Frameworks and libraries it may never link.
otool -L "$bin" > "$tmp/libs.txt"
libs='ServiceManagement|SystemExtensions|/Security\.framework|SecurityFoundation|SecurityInterface|OpenDirectory|Collaboration|DirectoryService|NetworkExtension|/Network\.framework|CFNetwork|WebKit|EndpointSecurity|DriverKit|/IOKit\.framework|ConfigurationProfiles|ManagedClient|LocalAuthentication|AuthenticationServices|ScriptingBridge|OSAKit|AppleScriptObjC|/AVFoundation\.framework|Photos|Contacts|EventKit|CoreWLAN|CoreBluetooth|CoreLocation'
if grep -E "$libs" "$tmp/libs.txt"; then bad "it links a framework that can install, authorise, reach the network or record"; fi

# Functions and classes it may never call (nm -u: what the binary imports).
nm -u "$bin" > "$tmp/imports.txt"
calls='^_SMAppService|_OBJC_CLASS_\$_SMAppService|^_SMJob|^_SMLoginItem|^_SMCopyAllJob|^_LSSharedFileList|^_kLSSharedFileList'
calls="$calls"'|^_Authorization|_OBJC_CLASS_\$_SFAuthorization|^_SecKeychain|^_SecItem|^_SecTrustSettingsSet|^_SecCertificateAddToKeychain|^_SecAccess'
calls="$calls"'|_OBJC_CLASS_\$_OSSystemExtension|^_KextManager|^_es_new_client|^_CSIdentity|_OBJC_CLASS_\$_OD(Node|Record|Session|Query)|_OBJC_CLASS_\$_CB(User)?Identity'
calls="$calls"'|^_set(e|re|res)?[ug]id$|^_initgroups$|^_[lf]?chown$|^_posix_spawnp?$|^_exec(l|lp|le|v|ve|vp|vP)$|^_v?fork$|^_system$|^_popen$|^_kill(pg)?$|^_ptrace$|^_task_for_pid$'
calls="$calls"'|_OBJC_CLASS_\$_NSTask$|_OBJC_CLASS_\$_NSAppleScript|_OBJC_CLASS_\$_NSUser(Unix|AppleScript|Automator)?(Script)?Task|_OBJC_CLASS_\$_OSAScript|^_AESendMessage|^_AECreateAppleEvent|_OBJC_CLASS_\$_SBApplication'
calls="$calls"'|^_xpc_connection_create|_OBJC_CLASS_\$_NSXPCConnection|_OBJC_CLASS_\$_NSXPCListener'
calls="$calls"'|^_socket$|^_connect$|^_bind$|^_listen$|^_accept$|^_sendto$|^_getaddrinfo$|^_gethostbyname|_OBJC_CLASS_\$_NSURL(Session|Connection|Request)|^_CFSocket|^_CFStreamCreatePairWithSocket|^_nw_|^_SCNetworkReachability|^_CFHTTP|_OBJC_CLASS_\$_WKWebView'
calls="$calls"'|^_CGImageDestination|_OBJC_CLASS_\$_AVAssetWriter|_OBJC_CLASS_\$_SCRecordingOutput|_OBJC_CLASS_\$_NSPasteboard|^_CGWindowListCreateImage|^_CGDisplayCreateImage'
calls="$calls"'|^_CGDisplayCapture|^_CGCaptureAllDisplays|^_CGShieldingWindow|^_SetSystemUIMode|^_CGAssociateMouseAndMouseCursorPosition|^_CGDisplayHideCursor|^_CGWarpMouseCursorPosition'
calls="$calls"'|^_CGEventTapCreate|^_CGEventPost|^_CGBeginDisplayConfiguration|^_CGSetDisplayTransfer|^_CGDisplaySetDisplayMode|^_IOPM|^_IORegistryEntrySet|^_SACLockScreen'
calls="$calls"'|^_dlopen$|^_dlsym$|^_NSClassFromString$|^_NSSelectorFromString$|^_objc_getClass$|^_objc_lookUpClass$|^_sel_registerName$|^_sel_getUid$'
calls="$calls"'|^_LSOpen|^_LSRegisterURL|^_LSSetDefault|^_CFPreferencesSet|_OBJC_CLASS_\$_SCScreenshotManager|^_fopen$|^_fwrite$'
calls="$calls"'|^_CFBundleGetFunctionPointer|^_CFBundleGetDataPointer|^_CFBundleLoadExecutable|^_launch_msg$|^_bootstrap_look_up|^_NSLookupSymbol|^_NSAddressOfSymbol'
if grep -E "$calls" "$tmp/imports.txt"; then bad "it imports a function or class that could install, authorise, spawn, connect, record or take over the screen"; fi

# Words and paths it may never hold: launchd and helper places, system folders, commands, and the Objective-C
# methods for kiosk mode, the desktop picture, other apps' settings, killing apps and saving pictures.
strings -a "$bin" > "$tmp/strings.txt"
words='launchctl|LaunchDaemons|LaunchAgents|PrivilegedHelperTools|StartupItems|LoginItems|SMPrivilegedExecutables|SMAuthorizedClients|RunAtLoad|KeepAlive|ProgramArguments|BundleProgram'
words="$words"'|sudo|osascript|dscl|sysadminctl|dseditgroup|pwpolicy|createhomedir|kickstart|tccutil|spctl|csrutil|systemsetup|mobileconfig|administrator privileges'
if grep -niwE "$words" "$tmp/strings.txt"; then bad "it holds a word that belongs to installing or running commands"; fi
# Objective-C methods, matched anywhere in a name: kiosk mode, the desktop picture, other apps' settings, killing or
# opening apps, watching keys, starting again at login, full-screen takeover, saving pictures and files.
methods='setPresentationOptions|setDesktopImageURL|setPersistentDomain|forceTerminate|representationUsingType|TIFFRepresentation'
methods="$methods"'|writeToFile|writeToURL|enableRelaunchOnLogin|addGlobalMonitorForEvents|enterFullScreenMode|launchApplication'
methods="$methods"'|openApplicationAtURL|withApplicationAtURL|recycleURLs|duplicateURLs|setDefaultApplicationAtURL'
methods="$methods"'|classNamed:|loadAndReturnError:|principalClass'
if grep -nE "$methods" "$tmp/strings.txt"; then bad "it names a method that changes things outside the app or saves files"; fi
if grep -ciE 'standin|labforced|checkerstandin|labtilescores|LabTile|LabEventLog|lab-events' "$tmp/strings.txt" >/dev/null; then bad "it holds the lab stand-in or the lab event log"; fi
paths='(^|[^~A-Za-z0-9_])/(Library|System|usr|bin|sbin|etc|private|var|opt|Applications)/'
if grep -nE "$paths" "$tmp/strings.txt"; then bad "it names a system path (it may write only inside its own sandbox container)"; fi
grep -q 'Testing edition: no lock. Quit any time with' "$tmp/strings.txt" || bad "the Testing line is missing: is this the Testing build?"
grep -q '_RegisterEventHotKey' "$tmp/imports.txt" || bad "the emergency quit (RegisterEventHotKey) is missing"

# 3. The bundle: shape, Info.plist, signature and entitlements. Its models, when it has them, may only be the three
# compiled models, their list and the sealed manifest.
(cd "$app" && find . -mindepth 1 | sort) > "$tmp/all.txt"
grep -v '^\./Contents/Resources/models' "$tmp/all.txt" > "$tmp/shape.txt" || true
grep '^\./Contents/Resources/models' "$tmp/all.txt" > "$tmp/models.txt" || true
printf '%s\n' ./Contents ./Contents/Info.plist ./Contents/MacOS ./Contents/MacOS/safesight-mac ./Contents/Resources \
  ./Contents/_CodeSignature ./Contents/_CodeSignature/CodeResources | sort > "$tmp/shape-want.txt"
diff -u "$tmp/shape-want.txt" "$tmp/shape.txt" || bad "the bundle holds something other than the app itself (no Library, PlugIns, XPCServices, Helpers or Frameworks)"
# Today's three models are named on purpose: this is stricter than reading the names from the sealed manifest. A
# maintainer who brings their own models widens this list by name, in a reviewed change.
models_ok='^\./Contents/Resources/models(/compiled\.sha256|/bundle-manifest\.json|/(marqo-vit-tiny-384|nsfwjs-mobilenet-v2|bumble-private-detector)'
models_ok="$models_ok"'(/(marqo-vit-tiny-384|nsfwjs-mobilenet-v2|bumble-private-detector\.fp32)\.mlmodelc(/.*)?)?)?$'
if grep -vE "$models_ok" "$tmp/models.txt"; then
  bad "the models folder holds something other than the three compiled models, their list and the manifest"
fi
plutil -convert json -o "$tmp/info.json" "$app/Contents/Info.plist"
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$tmp/ent.plist" || true
plutil -convert json -o "$tmp/ent.json" "$tmp/ent.plist" 2>/dev/null || echo '{}' > "$tmp/ent.json"
codesign -dv "$app" > "$tmp/sig.txt" 2>&1 || true
python3 - "$tmp/info.json" "$tmp/ent.json" "$tmp/sig.txt" <<'EOF' || fail=1
import json, sys
info, ent, sig = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), open(sys.argv[3]).read()
ok = True
want = {"CFBundleExecutable", "CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName", "CFBundlePackageType",
        "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "LSUIElement", "NSHumanReadableCopyright"}
if set(info) != want:
    print("FAIL: Info.plist keys changed. Added: %s. Missing: %s." % (sorted(set(info) - want), sorted(want - set(info)))); ok = False
if not info.get("CFBundleIdentifier", "").endswith(".testing"):
    print("FAIL: the identifier does not end in .testing"); ok = False
if info.get("CFBundleName") != "SafeSight Mac Testing" or info.get("CFBundleDisplayName") != "SafeSight Mac Testing":
    print("FAIL: the app is not named SafeSight Mac Testing"); ok = False
if info.get("LSUIElement") is not True:
    print("FAIL: it would get a Dock icon"); ok = False
if ent != {"com.apple.security.app-sandbox": True}:
    print("FAIL: its entitlements are %s, not exactly the App Sandbox" % ent); ok = False
if not ("Signature=adhoc" in sig or "Authority=Developer ID Application" in sig) or "runtime" not in sig:
    print("FAIL: not signed (ad hoc or Developer ID) with the hardened runtime:\n" + sig); ok = False
if ok:
    print("Bundle: a plain app named SafeSight Mac Testing (%s); one entitlement: %s" % (info["CFBundleIdentifier"], ", ".join(ent)))
sys.exit(0 if ok else 1)
EOF
codesign --verify --strict "$app" || bad "the signature does not verify"

# 4. The release app has no part of the Testing edition.
swift build -c release --product safesight-mac >/dev/null
rel="$(swift build -c release --show-bin-path)/safesight-mac"
if nm -u "$rel" | grep -E '_RegisterEventHotKey|_InstallEventHandler'; then bad "the release app contains the emergency quit"; fi
if nm "$rel" | grep -q 'SafeSightMacTestingEdition'; then bad "the release app links the Testing edition module"; fi

if [ "$fail" = 0 ]; then
  echo "Testing edition check: no lock, installer, account, admin, launchd, login-item, helper, extension, profile,"
  echo "process, network, recording or screen-takeover API; sandboxed with one entitlement; release app unchanged"
else
  echo "FAIL"; exit 1
fi
