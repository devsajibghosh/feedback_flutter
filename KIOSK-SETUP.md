# Kiosk setup (device owner)

This app enters Android Lock Task Mode by itself on launch (FIX-06 §2). If
the device is provisioned as **device owner**, Lock Task Mode is silent and
the visitor cannot exit the app at all — no confirmation dialog, no
back+overview escape gesture. This is the intended deployment for the ward
kiosk.

If the device is *not* provisioned as device owner, the app still calls
`startLockTask()`, but Android falls back to ordinary screen pinning: a
confirmation banner appears once, and it can be escaped by holding Back and
Overview together. That fallback is acceptable for testing, not for the
real deployment.

## Prerequisite — factory reset

**Device owner can only be set on a device with no accounts configured.**
This is an Android platform restriction, not something this app can work
around. If the tablet has ever signed into a Google account (or any other
account), you must factory-reset it first and skip account setup entirely
during the out-of-box setup wizard (there is usually a "Skip" option — do
not sign in).

## Steps

1. Factory-reset the device (skip above if it's already a bare install with
   no accounts).
2. Enable Developer Options and USB debugging (Settings → About →tap
   "Build number" 7 times → Developer Options → USB debugging).
3. Connect the device to a computer with `adb` installed and authorize the
   connection when prompted on-device.
4. Install the app:
   ```
   adb install -r feedback.apk
   ```
5. Set this app as device owner:
   ```
   adb shell dpm set-device-owner com.codestation23.feedback/.FeedbackDeviceAdminReceiver
   ```
   A successful run prints `Success: Device owner set to package
   com.codestation23.feedback`. If it instead reports that an account is
   present, or that the device already has a device owner or profile owner,
   go back to the factory-reset step — there is no way to set device owner
   over an existing account.
6. Disconnect from `adb` and launch the app once by hand. From then on it
   pins itself into Lock Task Mode on every launch, and the boot receiver
   relaunches it automatically after any power cycle — no further manual
   steps.

## Verifying it worked

- Open the app, then try to leave it (Home button, Recents, holding
  Back+Overview). None of these should do anything — the app should stay in
  the foreground with no confirmation banner.
- Reboot the device with the app running. It should come back on screen by
  itself within a few seconds, with no lock-screen or home-screen visible in
  between.

## Removing device owner (for re-provisioning or returning the device)

```
adb shell dpm remove-active-admin com.codestation23.feedback/.FeedbackDeviceAdminReceiver
```

This only works while still connected via `adb` with USB debugging enabled
— if Lock Task Mode is already blocking access to Settings, use `adb shell`
directly rather than trying to reach Developer Options on-device.
