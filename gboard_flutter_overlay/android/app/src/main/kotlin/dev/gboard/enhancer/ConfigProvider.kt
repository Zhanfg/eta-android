package dev.gboard.enhancer

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle

class ConfigProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        if (method != "snapshot") return Bundle.EMPTY
        val c = context ?: return Bundle.EMPTY
        val p = c.getSharedPreferences("config", 0)
        return Bundle().apply {
            putBoolean("writingTools", p.getBoolean("writingTools", true))
            putBoolean("regionBypass", p.getBoolean("regionBypass", true))
            putBoolean("modelUnlock", p.getBoolean("modelUnlock", true))
            putBoolean("experimental", p.getBoolean("experimental", false))
            putString("forcedCountry", p.getString("forcedCountry", "US") ?: "US")
            putString("backend", p.getString("backend", "GBOARD_SERVER") ?: "GBOARD_SERVER")
        }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
