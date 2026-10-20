#!/bin/zsh
# one time, with the iphone unlocked and trusting this mac (a cable is best):
#   1. makes a pairing file so the phone can talk to its own lockdownd later
#   2. copies the developer disk image out of xcode (has testmanagerd + XCTest)
#   3. builds the app + runner for the phone and installs both
#   4. puts the pairing file into the app's own storage on the phone
# after this the mac isn't needed.
#
# more than one phone? UDID=<udid> ./scripts/setup.sh
set -e
cd "$(dirname "$0")/.."
dev=App/Resources/Device

# xcode-select might point at the command line tools. prefer the plain Xcode.app,
# then whatever else is in /Applications
if ! xcodebuild -version >/dev/null 2>&1; then
  for x in /Applications/Xcode.app /Applications/Xcode*.app(N); do
    if DEVELOPER_DIR=$x/Contents/Developer xcodebuild -version >/dev/null 2>&1; then
      export DEVELOPER_DIR=$x/Contents/Developer
      break
    fi
  done
fi
xcodebuild -version >/dev/null 2>&1 || { echo "no working xcode found."; exit 1; }
echo "xcode: $(xcodebuild -version | head -1)"
export PATH="$HOME/.cargo/bin:$PATH"

bundle=$(awk '/AGENT_BUNDLE_ID:/ {print $2; exit}' project.yml)
udid=${UDID:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && !/unavailable/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}
[[ -z "$udid" ]] && { echo "no iphone found. plug it in, unlock it, trust this mac."; exit 1; }
echo "phone: $udid"

echo "\n== pairing file"
# a full paired-host credential for the phone, so it lives outside the app bundle and git
mkdir -p .pairing && chmod 700 .pairing
pairing=.pairing/$udid.plist
(cd setup && cargo build --release --locked -q)
setup/target/release/pairing $pairing $udid
# older setups bundled it into the app, don't anymore
rm -f $dev/pairing.plist

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
[[ -n "$dmg" ]] || { echo "xcode's disk image has no personalized dmg, this xcode isn't supported."; exit 1; }
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
xcrun devicectl device install app --device $udid $products/Agent.app >/dev/null
xcrun devicectl device install app --device $udid $products/Runner-Runner.app >/dev/null
echo "installed Agent and its runner"

echo "\n== pairing file to the app"
xcrun devicectl device copy to --device $udid --domain-type appDataContainer --domain-identifier $bundle \
  --source $pairing --destination "Library/Application Support/pairing.plist" -q
echo "copied"

cat <<'MSG'

done. on the phone:
  1. Settings > Privacy & Security > Developer Mode stays on
  2. open Agent, tap the model name, add your Anthropic API key (or sign in)
  3. iPhone Control > Turn On. allow the VPN, then enter your passcode for "XCTest"
  4. you can unplug now
MSG
