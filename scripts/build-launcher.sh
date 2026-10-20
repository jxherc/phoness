#!/bin/zsh
# builds the rust launcher for whatever xcode is building (device or simulator).
# xcode runs this before compiling the app.
set -e
cd "$(dirname "$0")/../launcher"

# xcode's env has no cargo on PATH
export PATH="$HOME/.cargo/bin:$PATH"

if [[ "$PLATFORM_NAME" == "iphonesimulator" ]]; then
  target=aarch64-apple-ios-sim
else
  target=aarch64-apple-ios
fi

# xcode's SDKROOT points at the wrong sdk half the time, cargo finds its own
unset SDKROOT LLVM_TARGET_TRIPLE_SUFFIX
# match the app's minimum so ld doesn't complain about the c bits in ring
export IPHONEOS_DEPLOYMENT_TARGET=26.0
cargo build --release --target $target
