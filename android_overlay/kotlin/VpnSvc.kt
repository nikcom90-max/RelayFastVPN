package app.relayfast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File

/**
 * VpnService: поднимает TUN и отдаёт его дескриптор Xray-core
 * (inbound `tun` в конфиге читает fd, переданный в startLoop).
 * Конфиг лежит в files/run/config.json — его пишет MainActivity.
 */
class VpnSvc : VpnService() {

    companion object {
        const val ACTION_START = "app.relayfast.START"
        const val ACTION_STOP = "app.relayfast.STOP"
        const val ACTION_RELOAD = "app.relayfast.RELOAD"
        private const val TAG = "RelayFastVpn"
        private const val CHANNEL_ID = "vpn_status"
        private const val OLD_CHANNEL_ID = "vpn"
        private const val NOTIFICATION_ID = 1

        @Volatile
        var instance: VpnSvc? = null

        @Volatile
        var coreRunning: Boolean = false
    }

    private var tun: ParcelFileDescriptor? = null
    private val lock = Any()
    private val ui = Handler(Looper.getMainLooper())
    private var screenReceiver: BroadcastReceiver? = null

    /** Раз в 3 с обновляет уведомление (только пока экран включён). */
    private val ticker = object : Runnable {
        override fun run() {
            if (!coreRunning) return
            Thread {
                TrafficMeter.pollIfStale(this@VpnSvc, 1500)
                ui.post { updateNotification() }
            }.start()
            val pm = getSystemService(PowerManager::class.java)
            if (pm.isInteractive) ui.postDelayed(this, 3000)
        }
    }

    private fun startTicker() {
        lastShown = ""
        ui.removeCallbacks(ticker)
        ui.post(ticker)
        if (screenReceiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    ui.removeCallbacks(ticker)
                    if (i?.action == Intent.ACTION_SCREEN_ON && coreRunning) ui.post(ticker)
                }
            }
            val f = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(r, f)
            }
            screenReceiver = r
        }
    }

    private fun stopTicker() {
        ui.removeCallbacks(ticker)
        screenReceiver?.let { runCatching { unregisterReceiver(it) } }
        screenReceiver = null
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // intent == null — система перезапустила службу после того, как убила
        // процесс (экономия батареи); так же стартует «Постоянный VPN» из настроек
        // Android. Конфиг лежит в files/run, поэтому просто поднимаем туннель заново.
        return when (intent?.action) {
            ACTION_STOP -> {
                stopVpn()
                START_NOT_STICKY
            }
            ACTION_RELOAD -> {
                reloadCore()
                START_STICKY
            }
            else -> {
                startForegroundCompat()
                startVpn()
                START_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopVpn()
    }

    override fun onDestroy() {
        instance = null
        stopTicker()
        TrafficMeter.endSession(this)
        if (coreRunning) runCatching { XrayCore.controller.stopLoop() }
        coreRunning = false
        runCatching { tun?.close() }
        tun = null
        super.onDestroy()
    }

    // --- жизненный цикл ядра -------------------------------------------------

    private fun readConfig(): String = File(filesDir, "run/config.json").readText()

    private fun startVpn() {
        if (coreRunning) return
        VpnBus.set("starting")
        Thread {
            try {
                XrayCore.init(this)
                val config = readConfig()
                val pfd = establishTun()
                synchronized(lock) { tun = pfd }
                XrayCore.controller.startLoop(config, pfd.fd)
                if (!XrayCore.controller.isRunning) error("Xray не запустился")
                coreRunning = true
                TrafficMeter.startSession(this)
                ui.post { startTicker() }
                VpnBus.set("started")
            } catch (t: Throwable) {
                Log.e(TAG, "start failed", t)
                runCatching { XrayCore.controller.stopLoop() }
                runCatching { tun?.close() }
                tun = null
                coreRunning = false
                VpnBus.set("error:" + (t.message ?: t.javaClass.simpleName))
                stopForegroundCompat()
                stopSelf()
            }
        }.start()
    }

    /** Смена сервера без пересоздания туннеля. */
    private fun reloadCore() {
        val pfd = tun
        if (!coreRunning || pfd == null) return
        Thread {
            try {
                val config = readConfig()
                XrayCore.controller.stopLoop()
                XrayCore.controller.startLoop(config, pfd.fd)
                if (!XrayCore.controller.isRunning) error("Xray не запустился")
                VpnBus.set("started")
            } catch (t: Throwable) {
                Log.e(TAG, "reload failed", t)
                coreRunning = false
                VpnBus.set("error:" + (t.message ?: t.javaClass.simpleName))
                stopVpn()
            }
        }.start()
    }

    private fun stopVpn() {
        VpnBus.set("stopping")
        Thread {
            runCatching { XrayCore.controller.stopLoop() }
            coreRunning = false
            ui.post { stopTicker() }
            TrafficMeter.endSession(this)
            stopForegroundCompat()
            stopSelf()
            // Дескриптор закрываем после stopSelf и небольшой паузы: иначе
            // иконка VPN может остаться в статус-баре.
            Thread.sleep(100)
            synchronized(lock) {
                runCatching { tun?.close() }
                tun = null
            }
            VpnBus.set("stopped")
        }.start()
    }

    private fun readSplit(): Pair<String, List<String>> {
        return try {
            val f = File(filesDir, "run/split.json")
            if (!f.exists()) return "off" to emptyList()
            val j = org.json.JSONObject(f.readText())
            val arr = j.optJSONArray("apps")
            val list = ArrayList<String>()
            if (arr != null) for (i in 0 until arr.length()) list.add(arr.getString(i))
            j.optString("mode", "off") to list
        } catch (t: Throwable) {
            "off" to emptyList()
        }
    }

    private fun establishTun(): ParcelFileDescriptor {
        if (prepare(this) != null) error("Нет разрешения на VPN")
        val b = Builder()
            .setSession("RelayFastVPN")
            .setMtu(1500)
            .addAddress("10.10.14.1", 30)
            .addAddress("fd10:10:14::1", 126)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)
        // Раздельное туннелирование: bypass — выбранные приложения мимо VPN,
        // only — через VPN только выбранные. Само приложение (и сокеты Xray)
        // всегда идёт мимо туннеля, иначе трафик ядра зациклится.
        var onlyApps = false
        val (mode, apps) = readSplit()
        if (mode == "only" && apps.isNotEmpty()) {
            for (app in apps) {
                try {
                    b.addAllowedApplication(app)
                    onlyApps = true
                } catch (_: Exception) {
                }
            }
        }
        if (!onlyApps) {
            b.addDisallowedApplication(packageName)
            if (mode == "bypass") {
                for (app in apps) {
                    try {
                        b.addDisallowedApplication(app)
                    } catch (_: Exception) {
                    }
                }
            }
        }
        return b.establish() ?: error("VPN не установлен или отозван")
    }

    // --- уведомление ---------------------------------------------------------

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        nm.deleteNotificationChannel(OLD_CHANNEL_ID)
        val ch = NotificationChannel(CHANNEL_ID, "Состояние VPN", NotificationManager.IMPORTANCE_LOW)
        // Показывать на экране блокировки целиком (скорость и трафик).
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
    }

    private fun serverName(): String =
        runCatching { File(filesDir, "run/name.txt").readText().trim() }.getOrDefault("")

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, VpnSvc::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val running = coreRunning
        val speed = "↓ ${TrafficMeter.fmt(TrafficMeter.speedDown)}/с   ↑ ${TrafficMeter.fmt(TrafficMeter.speedUp)}/с"
        val details = "За сеанс: ↓ ${TrafficMeter.fmt(TrafficMeter.sessDown)}   ↑ ${TrafficMeter.fmt(TrafficMeter.sessUp)}\n" +
            "Всего: ${TrafficMeter.fmt(TrafficMeter.totDown + TrafficMeter.totUp)}"
        val server = serverName()
        val bigText = (if (server.isNotEmpty()) "Сервер: $server\n" else "") + "$speed\n$details"
        return builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setSubText(if (server.isNotEmpty()) server else null)
            .setContentTitle(applicationInfo.loadLabel(packageManager).toString() + if (running) " · подключено" else " · подключение…")
            .setContentText(if (running) speed else "Запуск…")
            .setStyle(Notification.BigTextStyle().bigText(if (running) bigText else "Запуск…"))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Отключить", stop).build())
            .build()
    }

    private var lastShown = ""

    private fun updateNotification() {
        if (!coreRunning) return
        // Не перерисовываем уведомление, если цифры не изменились (экономим CPU и батарею)
        val key = "${TrafficMeter.speedDown}/${TrafficMeter.speedUp}/${TrafficMeter.sessDown}/${TrafficMeter.sessUp}/${serverName()}"
        if (key == lastShown) return
        lastShown = key
        runCatching {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
        }
    }

    private fun startForegroundCompat() {
        ensureChannel()
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
    }
}
