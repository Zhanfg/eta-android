package dev.gboard.enhancer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import de.robv.android.xposed.XposedBridge
import java.util.concurrent.atomic.AtomicBoolean

internal data class RuntimeConfig(
    val writingTools: Boolean = true,
    val regionBypass: Boolean = true,
    val modelUnlock: Boolean = true,
    val experimental: Boolean = false,
    val forcedCountry: String = "US",
    val backend: String = "GBOARD_SERVER",
)

internal object RuntimeConfigStore {
    private val ready = AtomicBoolean(false)
    @Volatile private var snapshot = RuntimeConfig()
    private val uri = Uri.parse("content://dev.gboard.enhancer.config")

    fun current(): RuntimeConfig = snapshot

    fun initialize(context: Context) {
        if (!ready.compareAndSet(false, true)) return
        refresh(context)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent?) {
                if (intent?.action == MainActivity.ACTION_CONFIG_CHANGED) refresh(c)
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, IntentFilter(MainActivity.ACTION_CONFIG_CHANGED), Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                context.registerReceiver(receiver, IntentFilter(MainActivity.ACTION_CONFIG_CHANGED))
            }
        } catch (t: Throwable) {
            XposedBridge.log("GboardEnhancer: config receiver failed: $t")
        }
    }

    private fun refresh(context: Context) {
        try {
            val b = context.contentResolver.call(uri, "snapshot", null, null) ?: return
            snapshot = RuntimeConfig(
                writingTools = b.getBoolean("writingTools", true),
                regionBypass = b.getBoolean("regionBypass", true),
                modelUnlock = b.getBoolean("modelUnlock", true),
                experimental = b.getBoolean("experimental", false),
                forcedCountry = b.getString("forcedCountry", "US") ?: "US",
                backend = b.getString("backend", "GBOARD_SERVER") ?: "GBOARD_SERVER",
            )
            XposedBridge.log("GboardEnhancer: runtime config refreshed (event-driven)")
        } catch (t: Throwable) {
            XposedBridge.log("GboardEnhancer: config snapshot failed: $t")
        }
    }
}
