package com.nikan.nikonsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager

/**
 * 相机连接保活前台服务：App 退到后台时保持进程与 Wi-Fi 高性能模式，
 * 防止系统休眠导致与相机的 PTP/IP 连接断开。
 */
class KeepAliveService : Service() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var cpuLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL_ID, "相机连接保活", NotificationManager.IMPORTANCE_LOW)
        nm.createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("尼康速传")
            .setContentText("与相机保持连接中")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notification)
        acquireLocks()
        return START_STICKY
    }

    private fun acquireLocks() {
        // 权限异常等情况下不崩溃，保活降级为仅前台服务
        if (wifiLock == null) {
            runCatching {
                val wm = getSystemService(WifiManager::class.java)
                wifiLock = wm?.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "nikonsync:wifi")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        }
        if (cpuLock == null) {
            runCatching {
                val pm = getSystemService(PowerManager::class.java)
                cpuLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nikonsync:cpu")?.apply {
                    setReferenceCounted(false)
                    acquire(4 * 60 * 60 * 1000L) // 最长 4 小时
                }
            }
        }
    }

    private fun releaseLocks() {
        runCatching { wifiLock?.release() }
        runCatching { cpuLock?.release() }
        wifiLock = null
        cpuLock = null
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "keepalive"
        private const val NOTIF_ID = 42

        fun start(ctx: Context) {
            val intent = Intent(ctx, KeepAliveService::class.java)
            runCatching {
                if (android.os.Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(intent)
                else ctx.startService(intent)
            }
        }

        fun stop(ctx: Context) {
            runCatching { ctx.stopService(Intent(ctx, KeepAliveService::class.java)) }
        }
    }
}
