package cc.axymorrsen.opencodemobile

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID

class OpenCodeMobileApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(NotificationBridge.GOAL_CHANNEL, "Background goals", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(NotificationBridge.ACTION_CHANNEL, "Approvals and failures", NotificationManager.IMPORTANCE_HIGH))
    }
}

class OcdClient(private val context: Context) {
    private fun tokenFile() = context.createDeviceProtectedStorageContext().filesDir.resolve("ocd.token")

    fun call(method: String, params: JSONObject = JSONObject()): JSONObject {
        val token = tokenFile().readText().trim()
        val request = JSONObject()
            .put("id", UUID.randomUUID().toString())
            .put("method", method)
            .put("params", params)
            .put("token", token)
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", 17665), 2500)
            socket.soTimeout = 5000
            val out = BufferedWriter(OutputStreamWriter(socket.getOutputStream()))
            out.write(request.toString())
            out.newLine()
            out.flush()
            val response = JSONObject(BufferedReader(InputStreamReader(socket.getInputStream())).readLine())
            if (response.has("error")) error(response.getJSONObject("error").optString("message", "RPC failed"))
            return response.getJSONObject("result")
        }
    }

    fun ping(): Boolean = runCatching { call("ping").optBoolean("pong") }.getOrDefault(false)
}

object NotificationBridge {
    const val GOAL_CHANNEL = "goal_live"
    const val ACTION_CHANNEL = "goal_action"
    private const val GOAL_ID = 27001

    private fun requestPromotedOngoingCompat(builder: Notification.Builder) {
        // Android 16 API 36.1 added setRequestPromotedOngoing(). Compile against API 36 so the
        // APK remains buildable on the base Android 16 SDK, then use the method when the device
        // framework actually exposes it. Missing 36.1 API safely falls back to a normal ongoing
        // progress notification.
        runCatching {
            Notification.Builder::class.java
                .getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType!!)
                .invoke(builder, true)
        }
    }

    fun refresh(context: Context) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val snapshot = runCatching { OcdClient(context).call("notification.snapshot") }.getOrNull() ?: return
        val nm = context.getSystemService(NotificationManager::class.java)
        if (!snapshot.optBoolean("active")) {
            nm.cancel(GOAL_ID)
            return
        }
        val progress = snapshot.optInt("progress", 0).coerceIn(0, 100)
        val state = snapshot.optString("state", "running")
        val builder = Notification.Builder(context, GOAL_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("OpenCode Goal")
            .setContentText("${snapshot.optString("stage", "running")} · $progress% · $state")
            .setOnlyAlertOnce(true)
            .setOngoing(state !in setOf("completed", "failed", "cancelled"))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(100, progress, false)
        requestPromotedOngoingCompat(builder)
        if (state == "completed") builder.setTimeoutAfter(60_000)
        if (state == "failed") builder.setTimeoutAfter(5 * 60_000)
        nm.notify(GOAL_ID, builder.build())
    }
}

class NotificationWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread {
            try { NotificationBridge.refresh(context.createDeviceProtectedStorageContext()) }
            finally { pending.finish() }
        }.start()
    }
}

class GoalRuntimeService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OpenCodeMobile:Goal")
            .apply { setReferenceCounted(false) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val hold = intent?.getBooleanExtra("hold_wakelock", false) == true
        if (hold && wakeLock?.isHeld != true) wakeLock?.acquire(30 * 60_000L)
        if (!hold && wakeLock?.isHeld == true) wakeLock?.release()
        startForeground(
            27002,
            Notification.Builder(this, NotificationBridge.GOAL_CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("OpenCode background goal")
                .setContentText("Runtime bridge active")
                .setOngoing(true)
                .build()
        )
        return START_STICKY
    }

    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = null
}

class MainActivity : ComponentActivity() {
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        setContent {
            val context = LocalContext.current
            val dark = isSystemInDarkTheme()
            val colors = if (Build.VERSION.SDK_INT >= 31) {
                if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            } else if (dark) darkColorScheme() else lightColorScheme()
            MaterialTheme(colorScheme = colors) { WorkspaceScreen() }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WorkspaceScreen() {
    val context = LocalContext.current
    val client = remember { OcdClient(context) }
    val scope = rememberCoroutineScope()
    var online by remember { mutableStateOf(false) }
    var path by remember { mutableStateOf("/storage/emulated/0/Git") }
    var message by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { online = withContext(Dispatchers.IO) { client.ping() } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("OpenCode Mobile") },
                actions = {
                    AssistChip(
                        onClick = { scope.launch { online = withContext(Dispatchers.IO) { client.ping() } } },
                        label = { Text(if (online) "Runtime online" else "Runtime offline") }
                    )
                }
            )
        }
    ) { padding ->
        Column(
            Modifier.padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Workspace", style = MaterialTheme.typography.headlineMedium)
            Text("Open an Android-local repository in place. Linux build/cache state stays in the sidecar.")
            OutlinedTextField(
                value = path,
                onValueChange = { path = it },
                label = { Text("Android / root path") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                enabled = online,
                modifier = Modifier.fillMaxWidth(),
                onClick = {
                    scope.launch {
                        message = runCatching {
                            withContext(Dispatchers.IO) {
                                client.call("workspace.register", JSONObject().put("host_path", path))
                            }
                        }.fold(
                            onSuccess = { "Workspace registered: ${it.optString("linux_path")}" },
                            onFailure = { it.message ?: "Failed" }
                        )
                    }
                }
            ) { Text("Open workspace") }
            message?.let { Text(it) }
        }
    }
}
