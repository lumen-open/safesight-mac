#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Assembles an UNSIGNED SafeSight Mac.app from the release build, with the watcher's models copied
# inside it (Resources/models: the practice state's model folder, SD-223 (b)). It writes only under
# .build/, installs nothing and adds no login item. Signing and notarizing are the founder's (step 0).
# Usage: tools/make-app.sh BUNDLE_ID MODELS_DIR
set -eu
cd "$(dirname "$0")/.."
bundle_id="${1:?bundle identifier, for example <rd>.safesightmac.app}"
models="${2:?models folder holding the three converted model packages}"
swift build -c release --product safesight-mac >/dev/null
bin=$(swift build -c release --show-bin-path)
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/SafeSightMacCore/BuildInfo.swift)
app=.build/SafeSightMac.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/models"
cp "$bin/safesight-mac" "$app/Contents/MacOS/"
sed -e "s/BUNDLE_ID/$bundle_id/" -e "s/VERSION/$version/g" packaging/Info.plist > "$app/Contents/Info.plist"
for p in marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage \
         bumble-private-detector/bumble-private-detector.fp32.mlpackage; do
  mkdir -p "$app/Contents/Resources/models/$(dirname "$p")"
  cp -R "$models/$p" "$app/Contents/Resources/models/$p"
done
# The copied files must match the hash list sealed in the build.
(cd "$app/Contents/Resources/models" && shasum -a 256 -c ../../../../../models/watcher-models.sha256 >/dev/null) \
  || { echo "copied models do not match models/watcher-models.sha256"; exit 1; }
echo "Built $app (unsigned). Sign and notarize it before giving it to anyone."
