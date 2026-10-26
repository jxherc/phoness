#!/bin/zsh
# one time, with the iphone or ipad unlocked and trusting this mac (a cable is best):
#   1. makes a remote pairing file so the phone can open a tunnel to itself later
#   2. copies the developer disk image out of xcode (has testmanagerd + XCTest)
#   3. builds the app + runner for the phone and installs both
#   4. puts the pairing file into the app's own storage on the phone
# after this the mac isn't needed.
#
# an iphone and an ipad around? DEVICE=ipad ./scripts/setup.sh (or DEVICE=iphone, or UDID=<udid>)
# free apple account (personal team)? FREE_ACCOUNT=1 ./scripts/setup.sh
#   free teams can't sign the built-in vpn, so the build leaves its entitlement out
#   and the app uses LocalDevVPN from the app store instead.
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
# "iphone <udid>" / "ipad <udid>" per connected device, by the product type in the model column
devs=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && !/unavailable/ {
  kind = ($0 ~ /\(iPad[0-9]/) ? "ipad" : ($0 ~ /\(iPhone[0-9]/) ? "iphone" : ""
  for (i = 1; i <= NF; i++) if (kind != "" && $i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print kind, $i
}')
if [[ -n "$UDID" ]]; then
  udid=$UDID
else
  # one device, or the one DEVICE names. never a guess between two
  pool=$(print -r -- "$devs" | awk -v k="${DEVICE:l}" 'NF && (k == "" || $1 == k)')
  n=$(print -r -- "$pool" | awk 'NF' | wc -l | tr -d ' ')
  (( n == 0 )) && { echo "no ${DEVICE:-iphone or ipad} found. plug it in, unlock it, trust this mac."; exit 1; }
  (( n > 1 )) && { echo "more than one device:\n$pool\npick one with DEVICE=iphone, DEVICE=ipad or UDID=<udid>"; exit 1; }
  udid=$(print -r -- "$pool" | awk 'NF {print $2}')
fi
[[ "$(print -r -- "$devs" | awk -v u=$udid '$2 == u {print $1}')" == ipad ]] && name=iPad || name=iPhone
echo "device: $name $udid"

echo "\n== pairing file"
# a paired-host credential for the phone, so it lives outside the app bundle and git.
# older setups wrote a lockdown pairing file here, the tool replaces it
mkdir -p .pairing && chmod 700 .pairing
# ignores itself and everything here, so a clone without the local ignore rules can't commit it
echo '*' > .pairing/.gitignore
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
echo '*' > $dev/DDI/.gitignore
cp $ddi/$dmg $dev/DDI/Image.dmg
cp $ddi/Firmware/$dmg.trustcache $dev/DDI/Image.dmg.trustcache
cp $ddi/BuildManifest.plist $dev/DDI/BuildManifest.plist
echo "copied $dmg"

echo "\n== build"
xcodegen generate -q
extra=()
if [[ "$FREE_ACCOUNT" == 1 ]]; then
  echo "free account: building without the built-in vpn"
  extra=(CODE_SIGN_ENTITLEMENTS=)
fi
xcodebuild -project Agent.xcodeproj -scheme Agent -destination "platform=iOS,id=$udid" \
  -derivedDataPath build -allowProvisioningUpdates -quiet "${extra[@]}" build-for-testing

echo "\n== install"
products=build/Build/Products/Debug-iphoneos
xcrun devicectl device install app --device $udid $products/Agent.app >/dev/null
xcrun devicectl device install app --device $udid $products/Runner-Runner.app >/dev/null
echo "installed Agent and its runner"

echo "\n== pairing file to the app"
# the app keeps this file locked away while the phone is locked, so the copy needs it unlocked
if xcrun devicectl device copy to --device $udid --domain-type appDataContainer --domain-identifier $bundle \
  --source $pairing --destination "Library/Application Support/pairing.plist" -q 2>/dev/null; then
  echo "copied"
else
  echo "couldn't copy it, the $name was probably locked. unlock it and run this again."
  echo "(an app that already had a pairing file keeps using it)"
  exit 1
fi

cat <<MSG

done. on the $name:
  1. Settings > Privacy & Security > Developer Mode stays on
  2. open Agent, tap the model name, add your Anthropic API key (or sign in)
  3. keep wifi on, the $name's remote pairing service needs it
  4. $name Control > Turn On. allow the VPN, then enter your passcode for "XCTest"
  5. you can unplug now
MSG
if [[ "$FREE_ACCOUNT" == 1 ]]; then
  cat <<'MSG'

free account:
  - install LocalDevVPN from the App Store and turn it on before step 3
  - apps signed by a free account stop opening after 7 days. run this script again then
MSG
fi
