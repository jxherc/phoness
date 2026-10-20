# xctest on device, lessons

- xctest waits for an app to be idle before each action. an app with a running animation never is, and a tap can hang for a minute. the runner swizzles the wait away. match the real method signature exactly: `waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:` takes three BOOLs (`v28@0:8B16B20B24`), a wrong block type made launches hang.
- creating a new XCUIApplication per call redoes setup. cache one per bundle id.
- BGTaskScheduler isn't available in the simulator. without background time the app gets suspended the moment it opens another app, and its in-flight request to the runner times out. that looked like a runner hang.
- the runner links XCTest from /System/Developer/Library/Frameworks, which the personalized ddi provides. xcode 27's ddi has XCTest 25227 in both the personalized dmg and the cryptex.
- `XCUIDevice.shared.system.openURL` is `open(_:)` in swift.
- there's no public "which app is in front". the runner checks `.state == .runningForeground` over the last app and then the known list.
- usbmuxd lists every device paired to the mac, ipads too, and wifi ones come and go. the pairing tool has to match the udid, never take the first one.
