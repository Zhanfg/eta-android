package dev.gboard.enhancer

import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dev.gboard.enhancer/config"
        private const val PREFS = "config"
        const val ACTION_CONFIG_CHANGED = "dev.gboard.enhancer.CONFIG_CHANGED"
        const val TARGET = "com.google.android.inputmethod.latin"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "loadConfig" -> result.success(loadConfig())
                "saveConfig" -> {
                    @Suppress("UNCHECKED_CAST")
                    saveConfig((call.arguments as? Map<String, Any?>).orEmpty())
                    result.success(true)
                }
                "nativeDiagnostics" -> result.success(nativeDiagnostics())
                else -> result.notImplemented()
            }
        }
    }

    private fun loadConfig(): Map<String, Any> {
        val p = getSharedPreferences(PREFS, MODE_PRIVATE)
        return mapOf(
            "writingTools" to p.getBoolean("writingTools", true),
            "regionBypass" to p.getBoolean("regionBypass", true),
            "modelUnlock" to p.getBoolean("modelUnlock", true),
            "experimental" to p.getBoolean("experimental", false),
            "forcedCountry" to (p.getString("forcedCountry", "US") ?: "US"),
            "backend" to (p.getString("backend", "GBOARD_SERVER") ?: "GBOARD_SERVER"),
        )
    }

    private fun saveConfig(map: Map<String, Any?>) {
        val p = getSharedPreferences(PREFS, MODE_PRIVATE)
        p.edit()
            .putBoolean("writingTools", map["writingTools"] as? Boolean ?: true)
            .putBoolean("regionBypass", map["regionBypass"] as? Boolean ?: true)
            .putBoolean("modelUnlock", map["modelUnlock"] as? Boolean ?: true)
            .putBoolean("experimental", map["experimental"] as? Boolean ?: false)
            .putString("forcedCountry", ((map["forcedCountry"] as? String) ?: "US").uppercase().take(2))
            .putString("backend", (map["backend"] as? String) ?: "GBOARD_SERVER")
            .apply()

        sendBroadcast(Intent(ACTION_CONFIG_CHANGED).setPackage(TARGET))
    }

    private fun packageVersion(name: String): String? = try {
        packageManager.getPackageInfo(name, 0).versionName
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    private fun nativeDiagnostics(): Map<String, Any?> {
        val gboard = packageVersion(TARGET)
        val gms = packageVersion("com.google.android.gms")
        val aicore = packageVersion("com.google.android.aicore")
        return mapOf(
            "gboardVersion" to gboard,
            "gboardInstalled" to (gboard != null),
            "gmsInstalled" to (gms != null),
            "gmsVersion" to gms,
            "aicoreInstalled" to (aicore != null),
            "aicoreVersion" to aicore,
        )
    }
}
