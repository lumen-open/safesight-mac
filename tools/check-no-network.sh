#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# No part both reads the screen and has network access. The cover-only build has no networking at
# all: this fails if any Swift source names a networking API.
set -eu
cd "$(dirname "$0")/.."
pattern='URLSession|URLRequest|NSURLConnection|import Network|NWConnection|NWListener|NWPathMonitor|CFSocket|CFStreamCreatePairWithSocket|getaddrinfo|import WebKit|WKWebView|SCNetworkReachability|URL\(string: *"https?:'
if git ls-files 'Sources/*.swift' | xargs grep -nE "$pattern"; then
  echo "A source file names a networking API. The watcher and the app may not have network access."; exit 1
fi
echo "Network check: no source names a networking API"
