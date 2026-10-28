package app.relayfast

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingPrepare: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "relayfast/vpn_state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                VpnBus.sink = events
                events?.success(VpnBus.state)
            }

            override fun onCancel(arguments: Any?) {
                VpnBus.sink = null
            }
        })

        MethodChannel(messenger, "relayfast/vpn").setMethodCallHandler { call, result ->
            when (call.method) {
                "state" -> result.success(VpnBus.state)

                "prepare" -> {
                    requestNotificationPermission()
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        pendingPrepare?.success(false)
                        pendingPrepare = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_VPN)
                    }
                }

                "start" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("bad_args", "config is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val dir = File(filesDir, "run").apply { mkdirs() }
                        File(dir, "config.json").writeText(config)
                        val split = org.json.JSONObject()
                        split.put("mode", call.argument<String>("splitMode") ?: "off")
                        val apps = org.json.JSONArray()
                        (call.argument<List<String>>("splitApps") ?: emptyList()).forEach { apps.put(it) }
                        split.put("apps", apps)
                        File(dir, "split.json").writeText(split.toString())
                        val intent = Intent(this, VpnSvc::class.java).setAction(VpnSvc.ACTION_START)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("start_failed", e.message, null)
                    }
                }

                "reload" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("bad_args", "config is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val dir = File(filesDir, "run").apply { mkdirs() }
                        File(dir, "config.json").writeText(config)
                        startService(Intent(this, VpnSvc::class.java).setAction(VpnSvc.ACTION_RELOAD))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("reload_failed", e.message, null)
                    }
                }

                "stats" -> {
                    if (VpnSvc.coreRunning) TrafficMeter.pollIfStale(this, 800) else TrafficMeter.totals(this)
                    result.success(
                        mapOf(
                            "up" to TrafficMeter.speedUp,
                            "down" to TrafficMeter.speedDown,
                            "sessUp" to TrafficMeter.sessUp,
                            "sessDown" to TrafficMeter.sessDown,
                            "totUp" to TrafficMeter.totUp,
                            "totDown" to TrafficMeter.totDown,
                        )
                    )
                }

                "resetTraffic" -> {
                    TrafficMeter.reset(this)
                    result.success(true)
                }

                "ping" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("bad_args", "config is required", null)
                        return@setMethodCallHandler
                    }
                    val app = applicationContext
                    val url = call.argument<String>("url")
                    Thread {
                        val ms = XrayCore.ping(app, config, url)
                        runOnUiThread { result.success(ms) }
                    }.start()
                }

                "check" -> {
                    val url = call.argument<String>("url")
                    if (!VpnSvc.coreRunning) {
                        result.success(-1L)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val ms = XrayCore.check(url)
                        runOnUiThread { result.success(ms) }
                    }.start()
                }

                "apps" -> {
                    Thread {
                        val pm = packageManager
                        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                        val list = pm.queryIntentActivities(intent, 0)
                            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
                            .filter { it.first != packageName }
                            .distinctBy { it.first }
                            .sortedBy { it.second.lowercase() }
                            .map { mapOf("package" to it.first, "name" to it.second) }
                        runOnUiThread { result.success(list) }
                    }.start()
                }

                "setServerName" -> {
                    runCatching {
                        val dir = File(filesDir, "run").apply { mkdirs() }
                        File(dir, "name.txt").writeText(call.argument<String>("name") ?: "")
                    }
                    result.success(null)
                }

                "cacheDir" -> result.success(cacheDir.absolutePath)

                "installApk" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            // Нужно разрешить установку из этого приложения
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                            result.success("permission")
                        } else {
                            val file = File(call.argument<String>("path") ?: "")
                            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                            startActivity(
                                Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success("ok")
                        }
                    } catch (e: Exception) {
                        result.success("error: ${e.message}")
                    }
                }

                "batteryIgnored" -> {
                    val pm = getSystemService(PowerManager::class.java)
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }

                "requestBattery" -> {
                    try {
                        startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:$packageName"))
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        // На некоторых прошивках диалога нет — открываем общий список.
                        try {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            result.success(true)
                        } catch (e2: Exception) {
                            result.success(false)
                        }
                    }
                }

                "vpnSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "stop" -> {
                    startService(Intent(this, VpnSvc::class.java).setAction(VpnSvc.ACTION_STOP))
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            pendingPrepare?.success(resultCode == Activity.RESULT_OK)
            pendingPrepare = null
        }
    }

    companion object {
        private const val REQ_VPN = 7001
        private const val REQ_NOTIFICATIONS = 7002
    }
}
