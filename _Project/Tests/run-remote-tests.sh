#!/bin/zsh
# Compiles the pure-Foundation Nebula Remote sources for macOS and runs their tests.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/remote-tests
xcrun clang -fobjc-arc -framework Foundation -I Browser \
  Browser/BrowserRemoteHTTP.m Browser/BrowserRemoteState.m Tests/BrowserRemoteTests.m -o "$OUT"
"$OUT"
