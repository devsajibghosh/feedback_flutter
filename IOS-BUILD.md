# iOS build → TestFlight

Everything iOS-side is already in the repo (`ios/` project, Podfile, Info.plist,
app icons). The only thing that must come from the person building is their
Apple Developer signing.

## Already configured

| Item | Value |
|---|---|
| Bundle ID | `com.codestation23.feedback` |
| Display name | Feedback Machine |
| Version | from `pubspec.yaml` → `version: 1.0.0+1` (name+build) |
| Min iOS | 12.0 (Podfile + Xcode project) |
| Devices | iPhone + iPad, all orientations, full screen, status bar hidden |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` (HTTPS only) — TestFlight won't ask |
| App icon | all sizes generated, 1024px has no alpha (App Store requirement) |

## Requirements on the Mac

- Xcode (latest stable) + command line tools
- Flutter **3.24.5** stable (the version this project is built with)
- CocoaPods (`sudo gem install cocoapods` or `brew install cocoapods`)
- An Apple Developer account (paid) with access to App Store Connect

## One-time setup

1. **App Store Connect** → My Apps → **+** New App → Bundle ID
   `com.codestation23.feedback` (register it under Certificates, IDs &
   Profiles → Identifiers first if it isn't listed).
   If that ID is taken on your account, pick another and change
   `PRODUCT_BUNDLE_IDENTIFIER` in Xcode → Runner → Signing & Capabilities.
2. Open `ios/Runner.xcworkspace` in Xcode (the **.xcworkspace**, not .xcodeproj)
   → Runner target → **Signing & Capabilities** → tick *Automatically manage
   signing* → choose your **Team**.

## Build and upload

```sh
flutter clean
flutter pub get
flutter build ipa --release
```

`pod install` runs automatically. The output is
`build/ios/ipa/*.ipa`; upload it with the **Transporter** app, or open
`build/ios/archive/Runner.xcarchive` in Xcode → Organizer → Distribute App →
App Store Connect → Upload.

After processing (~10–30 min) the build appears under **TestFlight** in App
Store Connect; add internal testers there.

## Every new upload

Bump the build number in `pubspec.yaml` (`1.0.0+1` → `1.0.0+2`, …) or pass
`--build-number=N` — App Store Connect rejects a duplicate build number.

## Notes

- Android "Lock Task" kiosk mode has no iOS equivalent in code; the method
  channel call simply no-ops on iOS. For a locked kiosk on iPad use
  **Settings → Accessibility → Guided Access**.
- The screen stays awake via `wakelock_plus` on iOS too.
