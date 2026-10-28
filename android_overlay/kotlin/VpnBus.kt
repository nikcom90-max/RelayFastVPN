package app.relayfast

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Состояние VPN-сервиса для Flutter: stopped | starting | started | stopping | error:<msg>. */
object VpnBus {
    @Volatile
    var state: String = "stopped"
        private set

    @Volatile
    var sink: EventChannel.EventSink? = null

    private val main = Handler(Looper.getMainLooper())

    fun set(newState: String) {
        state = newState
        main.post { sink?.success(newState) }
    }
}
