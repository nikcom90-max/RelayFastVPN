package app.relayfast

import android.content.Context
import android.os.SystemClock
import android.util.Log
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import java.io.File

/** Обёртка над Xray-core (libv2ray.aar из AndroidLibXrayLite). */
object XrayCore {
    private const val TAG = "RelayFastXray"
    private const val PING_URL = "https://www.gstatic.com/generate_204"

    @Volatile
    private var envReady = false

    val controller: CoreController by lazy {
        Libv2ray.newCoreController(object : CoreCallbackHandler {
            override fun startup(): Long = 0L
            override fun shutdown(): Long = 0L
            override fun onEmitStatus(code: Long, message: String?): Long {
                Log.i(TAG, "core: $message")
                return 0L
            }
        })
    }

    /** Копирует geoip.dat/geosite.dat из assets и сообщает ядру, где их искать. */
    @Synchronized
    fun init(context: Context) {
        if (envReady) return
        val dir = File(context.filesDir, "xray").apply { mkdirs() }
        val updated = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        }.getOrDefault(0L)
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val target = File(dir, name)
            if (target.exists() && target.lastModified() >= updated) continue
            runCatching {
                context.assets.open(name).use { input ->
                    target.outputStream().use { input.copyTo(it) }
                }
            }.onFailure { Log.w(TAG, "asset $name is missing: ${it.message}") }
        }
        Libv2ray.initCoreEnv(dir.path, "")
        envReady = true
    }

    /** Скорость за прошедший интервал: счётчики ядра сбрасываются при чтении. */
    fun pollStats(): Pair<Long, Long> {
        var up = 0L
        var down = 0L
        val raw = runCatching { controller.queryAllOutboundTrafficStats() }.getOrDefault("")
        for (entry in raw.split(';')) {
            val p = entry.split(',')
            if (p.size != 3 || p[0] == "block") continue
            val v = p[2].toLongOrNull() ?: continue
            if (p[1] == "uplink") up += v else if (p[1] == "downlink") down += v
        }
        return up to down
    }

    /** Задержка до сервера в мс, -1 при ошибке. Блокирующий вызов. */
    fun ping(context: Context, config: String, url: String?): Long {
        init(context)
        return try {
            Libv2ray.measureOutboundDelay(config, if (url.isNullOrBlank()) PING_URL else url)
        } catch (t: Throwable) {
            Log.w(TAG, "ping failed: ${t.message}")
            -1L
        }
    }

    /** Проверка уже поднятого туннеля: GET через запущенное ядро. Блокирующий вызов. */
    fun check(url: String?): Long {
        return try {
            controller.measureDelay(if (url.isNullOrBlank()) PING_URL else url)
        } catch (t: Throwable) {
            Log.w(TAG, "check failed: ${t.message}")
            -1L
        }
    }
}


/**
 * Единый счётчик трафика. Счётчики ядра сбрасываются при чтении, поэтому читает
 * только он: и уведомление, и приложение берут цифры отсюда. «Всего» хранится
 * в SharedPreferences и переживает перезапуск приложения.
 */
object TrafficMeter {
    private const val PREFS = "traffic"

    @Volatile var speedUp = 0L
    @Volatile var speedDown = 0L
    @Volatile var sessUp = 0L
    @Volatile var sessDown = 0L
    @Volatile var totUp = 0L
    @Volatile var totDown = 0L

    private var lastPoll = 0L
    private var lastSave = 0L
    private var loaded = false

    @Synchronized
    private fun load(context: Context) {
        if (loaded) return
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        totUp = p.getLong("up", 0L)
        totDown = p.getLong("down", 0L)
        loaded = true
    }

    @Synchronized
    private fun save(context: Context) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putLong("up", totUp).putLong("down", totDown).apply()
        lastSave = SystemClock.elapsedRealtime()
    }

    @Synchronized
    fun totals(context: Context) {
        load(context)
    }

    @Synchronized
    fun startSession(context: Context) {
        load(context)
        sessUp = 0L
        sessDown = 0L
        speedUp = 0L
        speedDown = 0L
        lastPoll = 0L
    }

    @Synchronized
    fun endSession(context: Context) {
        load(context)
        save(context)
        speedUp = 0L
        speedDown = 0L
        lastPoll = 0L
    }

    @Synchronized
    fun reset(context: Context) {
        load(context)
        totUp = 0L
        totDown = 0L
        save(context)
    }

    /** Читает ядро не чаще, чем раз в [minMs]: так два «читателя» не мешают друг другу. */
    @Synchronized
    fun pollIfStale(context: Context, minMs: Long) {
        load(context)
        val now = SystemClock.elapsedRealtime()
        if (lastPoll != 0L && now - lastPoll < minMs) return
        val (u, d) = XrayCore.pollStats()
        val dt = if (lastPoll == 0L) 1.0 else ((now - lastPoll) / 1000.0).coerceIn(0.5, 86400.0)
        lastPoll = now
        speedUp = (u / dt).toLong()
        speedDown = (d / dt).toLong()
        sessUp += u
        sessDown += d
        totUp += u
        totDown += d
        if (now - lastSave > 15_000) save(context)
    }

    fun fmt(bytes: Long): String {
        val units = arrayOf("Б", "КБ", "МБ", "ГБ", "ТБ")
        var v = bytes.toDouble()
        var i = 0
        while (v >= 1024 && i < units.size - 1) {
            v /= 1024
            i++
        }
        return if (i == 0) "${v.toLong()} ${units[i]}" else String.format(java.util.Locale.US, "%.1f %s", v, units[i])
    }
}
