#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# No part both reads the screen and has network access. Today no part has networking code at all, and this checks
# it three ways:
#  1. no Swift source names a networking API;
#  2. the modules on the screen path read no URL that could be remote, start no other program and load no code by
#     name, except the reviewed uses listed in tools/no-network-allow.txt (local files only);
#  3. the built release products link no networking framework and import no socket, name lookup or URL loading
#     function or class.
# A grep, otool or nm that cannot run fails the check; it never passes by default.
#
# Usage: tools/check-no-network.sh                  checks the sources, then builds and checks the release products
#        tools/check-no-network.sh --sources DIR [--allow FILE]
#                                                   checks the Swift files under DIR as if all were on the screen path
#        tools/check-no-network.sh --binary FILE... checks these binaries only
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
allow="$here/no-network-allow.txt"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-network.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

# grep that prints matches and returns 0 when it finds some and 1 when it finds none. Anything else (a file it could
# not read, a bad pattern) stops the check with exit 2.
search() {
  rc=0
  grep "$@" || rc=$?
  [ "$rc" -le 1 ] || { echo "FAIL: grep could not run (exit $rc)"; exit 2; }
  return "$rc"
}

# Networking APIs, anywhere in the Swift sources.
net='URLSession|URLRequest|NSURLConnection|NSURLSession|NSURLRequest|NSURLDownload|import Network|NWConnection|NWListener|NWPathMonitor|NWBrowser'
net="$net"'|CFSocket|CFStreamCreatePairWithSocket|CFHTTPMessage|getaddrinfo|gethostbyname|import WebKit|WKWebView|SCNetworkReachability|URL\(string: *"(https?|wss?|ftp):'
# On the screen path: reading a URL (a remote one would fetch it), starting a program, loading code by name.
risky='(Data|NSData|String|NSString)\(contentsOf|contentsOfURL|Process\(|NSTask|posix_spawn|dlopen|dlsym|NSClassFromString|objc_getClass|objc_lookUpClass'
# The modules a screen-reading process is built from (both apps). The harness and the hello tool read no screen.
screen_modules="DetectorCore Preprocess RegionFinder SafeSightMacWatcher SafeSightMacCapture SafeSightMacCover SafeSightMacApp SafeSightMacCore SafeSightMacTestingEdition"

check_sources() { # $1: file listing every Swift source; $2: file listing the screen-path ones
  [ -s "$1" ] || { echo "FAIL: no Swift sources found"; exit 2; }
  # shellcheck disable=SC2046
  if search -HnE "$net" $(cat "$1"); then
    echo "FAIL: a source file names a networking API. The watcher and the app may not have network access."; fail=1
  fi
  [ -s "$2" ] || { echo "FAIL: no screen-path sources found"; exit 2; }
  # shellcheck disable=SC2046
  search -HnE "$risky" $(cat "$2") > "$tmp/risky.txt" || true
  [ -r "$allow" ] || { echo "FAIL: cannot read $allow"; exit 2; }
  grep -vE '^[[:space:]]*(#|$)' "$allow" > "$tmp/allow.txt" || true
  : > "$tmp/used.txt"
  while IFS= read -r m; do
    f=${m%%:*}; rest=${m#*:}; text=${rest#*:}
    key="$f: $(printf '%s' "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if grep -Fxq -- "$key" "$tmp/allow.txt"; then
      printf '%s\n' "$key" >> "$tmp/used.txt"
    else
      echo "$m"
      echo "FAIL: a screen-path source reads a URL, starts a program or loads code by name, and tools/no-network-allow.txt doesn't list it"
      fail=1
    fi
  done < "$tmp/risky.txt"
  # An entry that matches nothing any more is removed, so the list only ever holds uses someone has looked at.
  while IFS= read -r a; do
    grep -Fxq -- "$a" "$tmp/used.txt" || { echo "FAIL: tools/no-network-allow.txt lists a line that is no longer there: $a"; fail=1; }
  done < "$tmp/allow.txt"
}

check_binaries() { # the binaries to check, as arguments
  [ "$#" -gt 0 ] || { echo "FAIL: no binaries to check"; exit 2; }
  for b in "$@"; do
    [ -f "$b" ] || { echo "FAIL: no binary at $b"; exit 2; }
    otool -L "$b" > "$tmp/libs.txt" || { echo "FAIL: otool could not read $b"; exit 2; }
    nm -u "$b" > "$tmp/imports.txt" || { echo "FAIL: nm could not read $b"; exit 2; }
    if search -E '/Network\.framework|/CFNetwork\.framework|/NetworkExtension\.framework|/WebKit\.framework' "$tmp/libs.txt"; then
      echo "FAIL: $(basename "$b") links a networking framework"; fail=1
    fi
    calls='^_(socket|connect|bind|listen|accept|sendto|recvfrom|getaddrinfo|getnameinfo|gethostbyname2?|gethostbyaddr)$|^_nw_|^_CFSocket|^_CFStreamCreatePairWithSocket|^_CFHTTP|^_SCNetworkReachability'
    calls="$calls"'|URLSession|NSURLConnection|NSURLRequest|URLRequest|NSURLDownload|_OBJC_CLASS_\$_WKWebView'
    if search -E "$calls" "$tmp/imports.txt"; then
      echo "FAIL: $(basename "$b") imports a socket, name lookup or URL loading function or class"; fail=1
    fi
  done
  echo "Binary check: $# product(s) link no networking framework and import no networking function"
}

case "${1:-}" in
  --sources)
    dir="${2:?folder of Swift files}"
    [ "${3:-}" = "--allow" ] && allow="${4:?allow-list file}"
    find "$dir" -name '*.swift' | sort > "$tmp/all.txt"
    cp "$tmp/all.txt" "$tmp/screen.txt"
    check_sources "$tmp/all.txt" "$tmp/screen.txt"
    ;;
  --binary)
    shift
    check_binaries "$@"
    ;;
  "")
    cd "$root"
    git ls-files 'Sources/*.swift' > "$tmp/all.txt" || { echo "FAIL: git ls-files failed"; exit 2; }
    : > "$tmp/screen.txt"
    for m in $screen_modules; do
      [ -d "Sources/$m" ] || { echo "FAIL: the screen-path module Sources/$m is missing; update this list"; exit 2; }
      git ls-files "Sources/$m/*.swift" >> "$tmp/screen.txt"
    done
    check_sources "$tmp/all.txt" "$tmp/screen.txt"
    [ "$fail" = 0 ] && echo "Source check: no source names a networking API, and the screen path reads only reviewed local files"
    unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
    swift build -c release >/dev/null
    bin=$(swift build -c release --show-bin-path)
    check_binaries "$bin/safesight-mac" "$bin/safesightmac-harness" "$bin/safesightmac-hello"
    ;;
  *) echo "usage: tools/check-no-network.sh [--sources DIR [--allow FILE] | --binary FILE...]"; exit 2 ;;
esac

[ "$fail" = 0 ] || { echo "FAIL"; exit 1; }
echo "Network check: no networking code, and no networking in what is built"
