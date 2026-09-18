package dev.gboard.enhancer

import android.app.Application
import android.content.Context
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.lang.reflect.Field

class GboardHook : IXposedHookLoadPackage {
    override fun handleLoadPackage(p: XC_LoadPackage.LoadPackageParam) {
        if (p.packageName != MainActivity.TARGET) return
        installConfigBootstrap()
        if (!install1831FastPath(p)) {
            XposedBridge.log("GboardEnhancer: acps#g not found; no unsafe guessing performed")
        }
    }

    private fun installConfigBootstrap() {
        try {
            XposedHelpers.findAndHookMethod(
                Application::class.java,
                "attach",
                Context::class.java,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val context = param.args[0] as? Context ?: return
                        RuntimeConfigStore.initialize(context.applicationContext ?: context)
                    }
                }
            )
        } catch (t: Throwable) {
            XposedBridge.log("GboardEnhancer: Application.attach hook failed: $t")
        }
    }

    // Verified for Gboard 18.3.1.977415014: Lacps;->g()Ljava/lang/Object;, name Lacps;->a.
    private fun install1831FastPath(p: XC_LoadPackage.LoadPackageParam): Boolean = try {
        val cls = XposedHelpers.findClass("acps", p.classLoader)
        val nameField: Field = cls.getDeclaredField("a").apply { isAccessible = true }
        XposedHelpers.findAndHookMethod(cls, "g", object : XC_MethodHook() {
            override fun afterHookedMethod(param: MethodHookParam) {
                val receiver = param.thisObject ?: return
                val original = param.result ?: return
                val flagName = nameField.get(receiver) as? String ?: return
                val replacement = FlagOverrideEngine.apply(flagName, original, RuntimeConfigStore.current())
                if (replacement !== original && replacement != original) param.result = replacement
            }
        })
        XposedBridge.log("GboardEnhancer: installed 18.3.1 in-memory flag hook")
        true
    } catch (t: Throwable) {
        XposedBridge.log("GboardEnhancer: flag hook failed: $t")
        false
    }
}
