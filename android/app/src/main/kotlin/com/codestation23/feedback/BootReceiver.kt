package com.codestation23.feedback

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Relaunches the app after a reboot (FIX-06 §2, originally §4.9), for the
 * dedicated-kiosk device nobody attends to press a button. Handles both the
 * standard `BOOT_COMPLETED` action and the non-standard `QUICKBOOT_POWERON`
 * some OEM builds (older HTC/Samsung/Amazon firmware) send instead.
 *
 * Early in boot, the package manager and storage may not have settled yet,
 * so the very first `startActivity()` can throw or silently no-op — retried
 * up to [maxAttempts] times, [retryDelayMs] apart, rather than giving up
 * after a single try.
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
        private const val ACTION_HTC_QUICKBOOT_POWERON = "com.htc.intent.action.QUICKBOOT_POWERON"
        private const val RETRY_DELAY_MS = 3000L
        private const val MAX_ATTEMPTS = 5
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != ACTION_QUICKBOOT_POWERON &&
            intent.action != ACTION_HTC_QUICKBOOT_POWERON
        ) {
            return
        }

        attemptLaunch(context.applicationContext, Handler(Looper.getMainLooper()), attempt = 1)
    }

    private fun attemptLaunch(context: Context, handler: Handler, attempt: Int) {
        try {
            val launchIntent = Intent(context, MainActivity::class.java)
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(launchIntent)
        } catch (e: Exception) {
            if (attempt < MAX_ATTEMPTS) {
                handler.postDelayed(
                    { attemptLaunch(context, handler, attempt + 1) },
                    RETRY_DELAY_MS,
                )
            }
        }
    }
}
