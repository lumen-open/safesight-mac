#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Assembles an UNSIGNED SafeSight Mac.app from the release build, with the watcher's models copied
# inside it (Resources/models: the practice state's model folder, SD-223 (b)). It writes only under
# .build/, installs nothing and adds no login item. Signing and notarizing are the founder's (step 0).
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
set -eu
cd "$(dirname "$0")/.."
# Never a lab build, whatever the shell has set: the stand-in and lab switches stay out of every app.
unset SAFESIGHTMAC_LAB KESTREL_LAB

testing=0
models_wanted=1
[ "${1:-}" = "--testing" ] && { testing=1; shift; }
[ "$testing" = 1 ] && [ "${1:-}" = "--no-models" ] && { models_wanted=0; shift; }
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
  scratch=.build-testing
  SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --product safesight-mac >/dev/null
  bin=$(SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path "$scratch" --show-bin-path)
  app="${out_dir:-$scratch}/SafeSight Mac Testing.app"
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
sed -e "s/BUNDLE_ID/$bundle_id/" -e "s/VERSION/$version/g" "$plist" > "$app/Contents/Info.plist"
if [ "$models_wanted" = 1 ]; then
  mkdir -p "$app/Contents/Resources/models"
  for p in marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage \
           bumble-private-detector/bumble-private-detector.fp32.mlpackage; do
    mkdir -p "$app/Contents/Resources/models/$(dirname "$p")"
    cp -R "$models/$p" "$app/Contents/Resources/models/$p"
  done
  # The copied files must match the hash list sealed in the build.
  here=$(pwd)
  (cd "$app/Contents/Resources/models" && shasum -a 256 -c "$here/models/watcher-models.sha256" >/dev/null) \
    || { echo "copied models do not match models/watcher-models.sha256"; exit 1; }
fi

if [ "$testing" = 1 ]; then
  # Ad hoc, with the hardened runtime and the App Sandbox: macOS applies the sandbox when the app starts.
  codesign --force --sign - --options runtime --entitlements packaging/Testing.entitlements "$app"
  codesign --verify --strict "$app"
  echo "Built $app (ad hoc signed, sandboxed, not notarized). For this Mac or a test Mac only."
else
  echo "Built $app (unsigned). Sign and notarize it before giving it to anyone."
fi
