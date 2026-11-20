#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Assembles an UNSIGNED SafeSight Mac.app from the release build, with the watcher's models inside it
# (Resources/models: the practice state's model folder, SD-223 (b)), compiled. The model packages are checked
# against the hash list sealed in the build, then compiled with Core ML's compiler, so the app never compiles at
# a new place at every start (each new place grew Core ML's own cache by about 200 MB). The compiled files are
# listed in Resources/models/compiled.sha256, which begins with a stamp of the sealed list; the app checks both.
# It writes only under .build/ and a temporary folder it removes, installs nothing and adds no login item.
# Signing and notarizing are the founder's (step 0).
#
# With --testing it assembles the Testing edition instead (docs/TESTING-EDITION.md): "SafeSight Mac Testing.app"
# under .build-testing/, built with SAFESIGHTMAC_TESTING=1, named and identified as its own app (the identifier
# must end in .testing), and signed ad hoc with one entitlement, the App Sandbox (packaging/Testing.entitlements),
# so that it runs sandboxed on the Mac that built it. Ad hoc is not Developer ID: it is not notarized, and it is
# for the builder's own Mac or a test Mac, never to hand out.
#
# Usage: tools/make-app.sh BUNDLE_ID MODELS_DIR
#        tools/make-app.sh --testing BUNDLE_ID MODELS_DIR
#        tools/make-app.sh --testing --no-models BUNDLE_ID OUT_DIR
#            (for tools/check-testing-edition.sh only: an app with no models covers every display whole)
#        tools/make-app.sh --testing --lab BUNDLE_ID MODELS_DIR
#            (developers' test Macs only: "SafeSight Mac Testing LAB.app", a lab Testing build that covers the synthetic
#            stand-in and keeps a lab event log in its container; the identifier must end in .lab.testing. It is never
#            handed to helpers; tools/check-no-standin.sh proves the release and normal Testing builds hold no stand-in)
set -eu
cd "$(dirname "$0")/.."
# Never a lab build, whatever the shell has set: the stand-in and lab switches stay out of every app.
unset SAFESIGHTMAC_LAB KESTREL_LAB

testing=0
lab=0
models_wanted=1
[ "${1:-}" = "--testing" ] && { testing=1; shift; }
[ "$testing" = 1 ] && [ "${1:-}" = "--no-models" ] && { models_wanted=0; shift; }
[ "$testing" = 1 ] && [ "$models_wanted" = 1 ] && [ "${1:-}" = "--lab" ] && { lab=1; shift; }
bundle_id="${1:?bundle identifier, for example <rd>.safesightmac.app (or <rd>.safesightmac.testing with --testing)}"
if [ "$models_wanted" = 1 ]; then
  models="${2:?models folder holding the three converted model packages}"
else
  out_dir="${2:?output folder}"
fi
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/SafeSightMacCore/BuildInfo.swift)

if [ "$testing" = 1 ]; then
  case "$bundle_id" in
    *.testing) ;;
    *) echo "The Testing edition's identifier must end in .testing (for example <rd>.safesightmac.testing),"
       echo "so it never shares a permission, settings or a sandbox with the full app."; exit 2 ;;
  esac
  if [ "$lab" = 1 ]; then
    case "$bundle_id" in
      *.lab.testing) ;;
      *) echo "A lab Testing build's identifier must end in .lab.testing, so it never shares anything with a normal one."; exit 2 ;;
    esac
    # Its own scratch folder: a lab build never shares build products with the normal Testing build.
    scratch=.build-testing-lab
    SAFESIGHTMAC_LAB=1 SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --product safesight-mac >/dev/null
    bin=$(SAFESIGHTMAC_LAB=1 SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --show-bin-path)
    app="$scratch/SafeSight Mac Testing LAB.app"
  else
    scratch=.build-testing
    SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --product safesight-mac >/dev/null
    bin=$(SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --show-bin-path)
    app="${out_dir:-$scratch}/SafeSight Mac Testing.app"
  fi
  plist=packaging/Testing-Info.plist
else
  unset SAFESIGHTMAC_TESTING
  swift build -c release --product safesight-mac >/dev/null
  bin=$(swift build -c release --show-bin-path)
  app=.build/SafeSightMac.app
  plist=packaging/Info.plist
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/safesight-mac" "$app/Contents/MacOS/"
# What goes into the app is checked, not only what the build folder holds: no lab stand-in and no lab event log. A lab
# Testing build takes the explicit lab path instead, which requires it to be a lab build.
if [ "$lab" = 1 ]; then
  tools/check-no-standin.sh --lab "$app/Contents/MacOS/safesight-mac" \
    || { rm -rf "$app"; echo "the lab app is not a lab build; nothing was assembled"; exit 1; }
else
  tools/check-no-standin.sh "$app/Contents/MacOS/safesight-mac" \
    || { rm -rf "$app"; echo "the built app contains the lab stand-in; nothing was assembled"; exit 1; }
fi
sed -e "s/BUNDLE_ID/$bundle_id/" -e "s/VERSION/$version/g" "$plist" > "$app/Contents/Info.plist"
# A lab build says so in its name wherever macOS shows it (System Settings' Screen Recording list, Finder).
if [ "$lab" = 1 ]; then
  sed -i '' -e 's#<string>SafeSight Mac Testing</string>#<string>SafeSight Mac Testing LAB</string>#' "$app/Contents/Info.plist"
fi
if [ "$models_wanted" = 1 ]; then
  here=$(pwd)
  packages=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-packages.XXXXXX")
  trap 'rm -rf "$packages"' EXIT
  dest="$app/Contents/Resources/models"
  mkdir -p "$dest"
  for p in marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage \
           bumble-private-detector/bumble-private-detector.fp32.mlpackage; do
    mkdir -p "$packages/$(dirname "$p")"
    cp -R "$models/$p" "$packages/$p"
  done
  # The packages must hold only the files the hash list sealed in the build names, and match it, before anything is
  # compiled from them.
  tools/check-model-files.sh models/watcher-models.sha256 "$packages" \
    || { echo "the model packages hold files models/watcher-models.sha256 doesn't list"; exit 1; }
  (cd "$packages" && shasum -a 256 -c "$here/models/watcher-models.sha256" >/dev/null) \
    || { echo "the model packages do not match models/watcher-models.sha256"; exit 1; }
  for p in marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage \
           bumble-private-detector/bumble-private-detector.fp32.mlpackage; do
    mkdir -p "$dest/$(dirname "$p")"
    xcrun coremlcompiler compile "$packages/$p" "$dest/$(dirname "$p")" >/dev/null
  done
  # The stamp is the sealed list's entries, one "sha256  path" line each, hashed (WatcherModels.stamp does the same).
  stamp=$(awk 'NF == 2 { printf "%s  %s\n", tolower($1), $2 }' models/watcher-models.sha256 | shasum -a 256 | cut -d' ' -f1)
  (cd "$dest" && {
    echo "# from $stamp"
    find . -type f -path '*.mlmodelc/*' | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done
  } > compiled.sha256)
fi

if [ "$testing" = 1 ]; then
  # Ad hoc, with the hardened runtime and the App Sandbox: macOS applies the sandbox when the app starts.
  codesign --force --sign - --options runtime --entitlements packaging/Testing.entitlements "$app"
  codesign --verify --strict "$app"
  echo "Built $app (ad hoc signed, sandboxed, not notarized). For this Mac or a test Mac only."
  if [ "$lab" = 1 ]; then echo "A LAB build: it covers the synthetic stand-in and keeps a lab event log. Never hand it to anyone."; fi
else
  echo "Built $app (unsigned). Sign and notarize it before giving it to anyone."
fi
