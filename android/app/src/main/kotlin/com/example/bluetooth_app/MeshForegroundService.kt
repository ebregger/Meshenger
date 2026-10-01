package com.example.bluetooth_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel

/** Bridges the notification's stop action to the active Flutter mesh session. */
object MeshForegroundServiceEvents {
  private val mainHandler = Handler(Looper.getMainLooper())
  private var eventSink: EventChannel.EventSink? = null
  private var stopRequestedWhileDetached = false

  fun setEventSink(sink: EventChannel.EventSink?) {
    eventSink = sink
    if (sink != null && stopRequestedWhileDetached) {
      stopRequestedWhileDetached = false
      emitStopRequest(sink)
    }
  }

  fun clearDetachedStopRequest() {
    stopRequestedWhileDetached = false
  }

  fun requestMeshStop() {
    val sink = eventSink
    if (sink == null) {
      stopRequestedWhileDetached = true
      return
    }
    emitStopRequest(sink)
  }

  private fun emitStopRequest(sink: EventChannel.EventSink) {
    mainHandler.post {
      sink.success(mapOf("event" to EVENT_MESH_STOP_REQUESTED, "mac" to ""))
    }
  }

  private const val EVENT_MESH_STOP_REQUESTED = "mesh_service_stop_requested"
}

/** Keeps the mesh session's app process at foreground-service priority. */
class MeshForegroundService : Service() {
  private val tag = "MeshFgService"
  private var meshRadioActive = true
  private var debugPartialWakeLock: PowerManager.WakeLock? = null

  override fun onCreate() {
    super.onCreate()
    runningInstance = this
    android.util.Log.i(tag, "onCreate")
    createNotificationChannel()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    android.util.Log.i(tag, "onStartCommand action=${intent?.action} startId=$startId")
    if (intent?.action == ACTION_STOP) {
      MeshForegroundServiceEvents.requestMeshStop()
      stopForeground(STOP_FOREGROUND_REMOVE)
      stopSelf(startId)
      return START_NOT_STICKY
    }

    MeshForegroundServiceEvents.clearDetachedStopRequest()
    meshRadioActive = true
    val notification = buildNotification()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
      )
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
    return START_NOT_STICKY
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onDestroy() {
    android.util.Log.i(tag, "onDestroy")
    releaseDebugWakeLock()
    if (runningInstance === this) runningInstance = null
    super.onDestroy()
  }

  private fun updateMeshRadioState(active: Boolean) {
    meshRadioActive = active
    android.util.Log.i(tag, "mesh radio active=$active")
    getSystemService(NotificationManager::class.java)
      .notify(NOTIFICATION_ID, buildNotification())
  }

  private fun updateDebugWakeLock(enabled: Boolean): Boolean {
    if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) return false
    try {
      if (enabled) {
        if (debugPartialWakeLock?.isHeld != true) {
          debugPartialWakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, DEBUG_WAKE_LOCK_TAG)
            .apply {
              setReferenceCounted(false)
              acquire()
            }
        }
      } else {
        releaseDebugWakeLock()
      }
      android.util.Log.i(tag, "[DEV] partialWakeLockHeld=${debugPartialWakeLock?.isHeld == true}")
      getSystemService(NotificationManager::class.java)
        .notify(NOTIFICATION_ID, buildNotification())
      return true
    } catch (error: Exception) {
      android.util.Log.e(tag, "[DEV] Failed to update partial wake lock", error)
      releaseDebugWakeLock()
      return false
    }
  }

  private fun releaseDebugWakeLock() {
    val wakeLock = debugPartialWakeLock
    debugPartialWakeLock = null
    if (wakeLock?.isHeld == true) {
      try {
        wakeLock.release()
      } catch (error: RuntimeException) {
        android.util.Log.w(tag, "[DEV] Failed to release partial wake lock", error)
      }
    }
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val channel = NotificationChannel(
      CHANNEL_ID,
      "Mesh activity",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "Shows when Meshenger is listening for nearby devices."
      setShowBadge(false)
    }
    getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
  }

  private fun buildNotification(): Notification {
    val immutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      PendingIntent.FLAG_IMMUTABLE
    } else {
      0
    }
    val contentIntent = PendingIntent.getActivity(
      this,
      REQUEST_OPEN_APP,
      Intent(this, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      },
      PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag,
    )
    val stopIntent = PendingIntent.getService(
      this,
      REQUEST_STOP_MESH,
      Intent(this, MeshForegroundService::class.java).setAction(ACTION_STOP),
      PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag,
    )
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_ID)
    } else {
      Notification.Builder(this)
    }

    return builder
      .setSmallIcon(R.drawable.ic_stat_meshenger)
      .setContentTitle("Meshenger is active")
      .setContentText(
        when {
          !meshRadioActive -> "Bluetooth is off. Mesh will resume when available"
          debugPartialWakeLock?.isHeld == true -> "Test mode: CPU awake while screen is off"
          else -> "Listening for nearby devices"
        },
      )
      .setContentIntent(contentIntent)
      .setCategory(Notification.CATEGORY_SERVICE)
      .setVisibility(Notification.VISIBILITY_PRIVATE)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setShowWhen(false)
      .addAction(0, "Stop mesh", stopIntent)
      .build()
  }

  companion object {
    const val ACTION_START = "com.example.bluetooth_app.action.START_MESH"
    const val ACTION_STOP = "com.example.bluetooth_app.action.STOP_MESH"
    private const val CHANNEL_ID = "mesh_activity"
    private const val NOTIFICATION_ID = 6201
    private const val REQUEST_OPEN_APP = 6202
    private const val REQUEST_STOP_MESH = 6203
    private const val DEBUG_WAKE_LOCK_TAG = "MeshengerDebugBleTestWakeLock"

    @Volatile
    private var runningInstance: MeshForegroundService? = null

    fun isRunning(): Boolean = runningInstance != null

    fun setMeshRadioActive(active: Boolean): Boolean {
      val service = runningInstance ?: return false
      service.updateMeshRadioState(active)
      return true
    }

    fun isDebugWakeLockHeld(): Boolean = runningInstance?.debugPartialWakeLock?.isHeld == true

    fun setDebugWakeLockEnabled(enabled: Boolean): Boolean {
      val service = runningInstance ?: return false
      return service.updateDebugWakeLock(enabled)
    }
  }
}
