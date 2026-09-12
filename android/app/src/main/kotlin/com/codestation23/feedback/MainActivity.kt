package com.codestation23.feedback

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kiosk mode (§4.9): tries true Lock Task Mode when this app has been set
 * as device owner, otherwise falls back to plain screen pinning — both go
 * through the same `startLockTask()` call, Android picks which one based on
 * device-owner status. Every step is wrapped so a device/OS quirk here can
 * never crash the app.
 */
class MainActivity : FlutterActivity() {
    private val kioskChannel = "com.codestation23.feedback/kiosk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, kioskChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "enterKioskMode") {
                    enterKioskMode()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun enterKioskMode() {
        try {
            val dpm = getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val adminComponent = ComponentName(this, FeedbackDeviceAdminReceiver::class.java)
            if (dpm.isDeviceOwnerApp(packageName)) {
                dpm.setLockTaskPackages(adminComponent, arrayOf(packageName))
            }
        } catch (e: Exception) {
            // Not a device owner, or DPM unavailable on this device — fall
            // through to startLockTask(), which still works as screen pinning.
        }

        try {
            startLockTask()
        } catch (e: Exception) {
            // Lock task mode unavailable on this device/OS version.
        }
    }
}
