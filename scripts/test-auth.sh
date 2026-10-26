#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | tail -1)/Contents/Developer"
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx swiftc -parse-as-library App/Keychain.swift App/ClaudeAuth.swift App/Claude.swift App/OpenAI.swift App/Providers.swift Tests/ClaudeAuthTests.swift -o "$work/test-auth"
"$work/test-auth"
