package com.codestation23.feedback

import android.app.admin.DeviceAdminReceiver

/**
 * Registered purely so `DevicePolicyManager.setLockTaskPackages` has a valid
 * admin component to call on devices where this app has been provisioned as
 * device owner (§4.9). Not used at all on a normal sideloaded install —
 * [MainActivity] checks `isDeviceOwnerApp` first and simply skips this path
 * otherwise.
 */
class FeedbackDeviceAdminReceiver : DeviceAdminReceiver()
