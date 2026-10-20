#!/bin/zsh
# one time, with the iphone plugged in by cable and unlocked:
#   1. makes a pairing file so the phone can talk to its own lockdownd later
#   2. copies the developer disk image out of xcode (has testmanagerd + XCTest)
#   3. builds the app + runner for the phone and installs both
# after this the mac isn't needed.
set -e
cd "$(dirname "$0")/.."
root=$PWD
dev=App/Resources/Device

# xcode-select might point at the command line tools
if ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | tail -1)/Contents/Developer"
fi
export PATH="$HOME/.cargo/bin:$PATH"

udid=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && !/unavailable/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[[ -z "$udid" ]] && { echo "no iphone found. plug it in, unlock it, trust this mac."; exit 1; }
echo "phone: $udid"

echo "\n== pairing file"
mkdir -p $dev
(cd setup && cargo build --release -q)
setup/target/release/pairing $dev/pairing.plist

echo "\n== developer disk image"
ddi=/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore
[[ -d $ddi ]] || { echo "no ddi at $ddi. open xcode once so it installs the platform files."; exit 1; }
# the manifest says which dmg is the personalized one
dmg=$(/usr/bin/python3 -I -c "
import plistlib,sys
m=plistlib.load(open(sys.argv[1],'rb'))
for b in m['BuildIdentities']:
    p=b['Manifest'].get('PersonalizedDMG',{}).get('Info',{}).get('Path')
    if p: print(p); break
" $ddi/BuildManifest.plist)
mkdir -p $dev/DDI
cp $ddi/$dmg $dev/DDI/Image.dmg
cp $ddi/Firmware/$dmg.trustcache $dev/DDI/Image.dmg.trustcache
cp $ddi/BuildManifest.plist $dev/DDI/BuildManifest.plist
echo "copied $dmg"

echo "\n== build"
xcodegen generate -q
xcodebuild -project Agent.xcodeproj -scheme Agent -destination "platform=iOS,id=$udid" \
  -derivedDataPath build -allowProvisioningUpdates -quiet build-for-testing

echo "\n== install"
products=build/Build/Products/Debug-iphoneos
xcrun devicectl device install app --device $udid $products/Agent.app
xcrun devicectl device install app --device $udid $products/Runner-Runner.app

cat <<'MSG'

done. on the phone:
  1. Settings > Privacy & Security > Developer Mode stays on
  2. open Agent, tap the model name, paste your Anthropic API key
  3. iPhone Control > Turn On. allow the VPN, then enter your passcode for "XCTest"
  4. you can unplug now
MSG
