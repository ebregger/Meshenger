package com.example.bluetooth_app

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.Build
import android.os.Bundle
import android.os.BatteryManager
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.annotation.RequiresApi
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private enum class HeldLinkWriteResult { NOT_AVAILABLE, COMPLETED, FAILED }

  private val TAG = "NativeMeshService"

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
      window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
      Log.i(TAG, "[DEV] keepScreenOn=true")
    }
  }

  private var eventSink: EventChannel.EventSink? = null
  private var bluetoothGattServer: BluetoothGattServer? = null
  private var advertiser: BluetoothLeAdvertiser? = null
  private var advertiseCallback: AdvertiseCallback? = null
  private var advertiseSettings: AdvertiseSettings? = null
  private var currentAdvertiserHash: ByteArray = byteArrayOf(1)
  private var currentNodeIdPrefix: ByteArray = byteArrayOf(0, 0, 0, 0)
  // Hybrid API state
  private var advertisingSetCallback: AdvertisingSetCallback? = null
  private var currentAdvertisingSet: AdvertisingSet? = null
  private val MESH_MFG_ID = 0xFFE0
  private val MESH_MAGIC: ByteArray = byteArrayOf(0x4D, 0x45, 0x53, 0x48) // 'M''E''S''H'
  private val MESH_DIAL_CAPABILITY_MARKER = 0xD1.toByte()

  private val gattExecutor = Executors.newSingleThreadExecutor()
  private val deadMacs = java.util.concurrent.ConcurrentHashMap<String, Long>()
  private val failureCounts = java.util.concurrent.ConcurrentHashMap<String, Int>()
  private var pendingHashUpdateHandler: Handler? = null
  private val advertiserUpdateCallbackHandler = Handler(Looper.getMainLooper())
  private var pendingScanResponseUpdateSet: AdvertisingSet? = null
  private var pendingScanResponseUpdateHashHex: String? = null
  private var pendingScanResponseUpdateTimeout: Runnable? = null
  // Tracks MACs that are currently connected to our GATT server.
  // Used to guard cancelConnection() — calling it on an already-disconnected
  // device triggers another onConnectionStateChange(DISCONNECTED) callback,
  // creating an infinite cascade that floods the log and bricks the BLE stack.
  private val connectedServerClients = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
  /// Inbound clients that enabled NOTIFY on our CCCD (safe to push deltas).
  private val notifyReadyServerClients = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
  private val serverClientLock = Any()
  private val serverClientConnectedAtMs = java.util.concurrent.ConcurrentHashMap<String, Long>()
  private val serverClientLastActivityAtMs = java.util.concurrent.ConcurrentHashMap<String, Long>()
  private val serverConnectionIds = java.util.concurrent.ConcurrentHashMap<String, String>()
  private val serverClientEvicting = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
  // Allow a peer time to discover the service and subscribe before treating an
  // unready connection as stale. Recent GATT activity refreshes this deadline.
  private val pendingInboundStaleAfterMs = 12_000L
  // Drops silent inbound clients even when nobody is trying to connect, so a
  // zombie link cannot keep the single slot advertised as busy forever.
  private val inboundIdleHandler = Handler(Looper.getMainLooper())
  private val inboundIdleSweep = Runnable { sweepIdleInboundClients() }
  // Set to true during resetNativeServer() to suppress re-entrant disconnect callbacks.
  @Volatile private var isResettingServer = false
  @Volatile private var serverServiceReady = false
  // Connection collision mutex: only one outbound GATT attempt may run at a time.
  private val isOutboundClientBusy = java.util.concurrent.atomic.AtomicBoolean(false)
  private val activeInboundServers = java.util.concurrent.atomic.AtomicInteger(0)
  private val maxInboundServerClients = 1
  // Dart sets this during push-on-write so we reject a second inbound (GATT 133).
  @Volatile private var currentOutboundGatt: BluetoothGatt? = null
  @Volatile private var heldClientGatt: BluetoothGatt? = null
  @Volatile private var heldWriteChar: BluetoothGattCharacteristic? = null
  @Volatile private var heldClientTraceAttemptId: String? = null
  @Volatile private var heldChunkSize: Int = 20
  @Volatile private var heldClientLeaseStartedAtMs: Long = 0L
  @Volatile private var heldClientReleaseReason: String? = null
  private val clientIoLock = Object()
  // Android GATT permits one client write operation at a time. Keep offer
  // chunks and reply ACKs on one fair queue so an ACK cannot collide with the
  // chunk callback that is currently completing.
  private val clientGattWriteLock = java.util.concurrent.locks.ReentrantLock(true)
  private val clientReplyAckExecutor = Executors.newSingleThreadExecutor()
  @Volatile private var clientIoOk: Boolean? = null
  @Volatile private var heldNotifyLatch: CountDownLatch? = null
  @Volatile private var heldNotifyResult: Boolean? = null
  private val heldWriteCallbackTimeoutMs = 1500L
  private val outboundCancelGeneration = AtomicLong(0)
  // Reuse one Handler so removeCallbacks() can cancel the lease posted earlier.
  private val heldClientHandler = Handler(Looper.getMainLooper())
  private val heldClientRelease = Runnable {
    val g = heldClientGatt
    if (g != null) {
      val now = System.currentTimeMillis()
      val leaseStartedAt = heldClientLeaseStartedAtMs
      val heldMac = try { g.device.address } catch (_: Throwable) { null }
      traceBle(
        "CLIENT_HELD_LINK_RELEASED",
        mac = heldMac,
        attemptId = heldClientTraceAttemptId,
        fields = mapOf(
          "REASON" to (heldClientReleaseReason ?: "unknown"),
          "LEASE_AGE_MS" to if (leaseStartedAt > 0L) now - leaseStartedAt else null,
          "IDLE_MS" to heldClientIdleMs,
          "MAX_LEASE_MS" to heldClientMaxLeaseMs,
        ),
      )
      emitHeldLinkState("held_link_unavailable", heldMac)
      requestClientConnectionPriority(
        g,
        BluetoothGatt.CONNECTION_PRIORITY_BALANCED,
        "held_link_release",
        heldClientTraceAttemptId,
      )
    }
    heldClientGatt = null
    heldWriteChar = null
    heldClientTraceAttemptId = null
    heldClientLeaseStartedAtMs = 0L
    heldClientReleaseReason = null
    try { g?.disconnect() } catch (_: Throwable) {}
  }
  @Volatile private var heldClientIdleMs = 4000L
  @Volatile private var heldClientMaxLeaseMs = 15000L

  private val SERVICE_UUID = UUID.fromString("c7e4f1a2-9b3d-4a8e-a1f6-2d5e8b9c0a4f")
  private val CHARACTERISTIC_UUID =
    UUID.fromString("6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a")
  // New: Server→Client notification characteristic for single-connection bidirectional sync.
  private val NOTIFY_CHARACTERISTIC_UUID =
    UUID.fromString("b9168cf8-4d57-466d-a6f6-4be440ce8025")
  // 0x2902 Client Characteristic Configuration Descriptor UUID
  private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

  // Lock + state for the Server→Client notifyCharacteristicChanged flow.
  private val serverReplyExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
  private val serverNotifyLock = Object()
  @Volatile private var lastNotifyOk: Boolean? = null
  @Volatile private var lastNotifyMac: String? = null
  @Volatile private var notifyStartedAtMs: Long = 0L
  private data class ServerReplyFeedback(
    val accepted: Boolean,
    val missingChunkIndices: List<Int> = emptyList(),
    val retryAll: Boolean = false,
  )
  private data class PendingFramedServerReply(
    val transferId: Int,
    val feedback: java.util.concurrent.LinkedBlockingQueue<ServerReplyFeedback>,
  )
  private class PendingClientReplyFeedbackWrite(
    val latch: CountDownLatch,
  ) {
    @Volatile var status: Int? = null
  }
  private data class IncomingReplyTransfer(
    val macAddress: String,
    val transferId: Int,
    val gatt: BluetoothGatt,
    val attemptId: String,
    val completeReceipt: (Boolean) -> Unit,
  )
  private val pendingServerReplyAcks = java.util.concurrent.ConcurrentHashMap<String, PendingFramedServerReply>()
  private val pendingClientReplyFeedbackWrites = java.util.concurrent.ConcurrentHashMap<BluetoothGatt, PendingClientReplyFeedbackWrite>()
  private val incomingReplyTransfers = java.util.concurrent.ConcurrentHashMap<String, IncomingReplyTransfer>()
  private val replyAckTimeoutMs = 2000L
  private val heldReplyTimeoutMs = replyAckTimeoutMs * 2 + 1000L
  private val replyStartFrameType = 0xD0
  private val replyDataFrameType = 0xD1
  private val replyEndFrameType = 0xD2
  private val replyAckFrameType = 0xA1
  private val replyMissingFrameType = 0xA2
  private val replyMissingAllFrameType = 0xA3
  private val replyDataFrameHeaderBytes = 3
  private val maxReplyMissingIndicesPerFrame = 7
  // Per-client MTU negotiated on the server side so we know the notify chunk size.
  private val serverMtuMap = java.util.concurrent.ConcurrentHashMap<String, Int>()

  private fun writeFrameInt(target: ByteArray, offset: Int, value: Int) {
    target[offset] = (value ushr 24).toByte()
    target[offset + 1] = (value ushr 16).toByte()
    target[offset + 2] = (value ushr 8).toByte()
    target[offset + 3] = value.toByte()
  }

  private fun readFrameInt(source: ByteArray, offset: Int): Int =
    ((source[offset].toInt() and 0xFF) shl 24) or
      ((source[offset + 1].toInt() and 0xFF) shl 16) or
      ((source[offset + 2].toInt() and 0xFF) shl 8) or
      (source[offset + 3].toInt() and 0xFF)

  private fun readFrameU16(source: ByteArray, offset: Int): Int =
    ((source[offset].toInt() and 0xFF) shl 8) or
      (source[offset + 1].toInt() and 0xFF)

  private fun appendFrameU16(target: ByteArray, offset: Int, value: Int) {
    target[offset] = (value ushr 8).toByte()
    target[offset + 1] = value.toByte()
  }

  private fun framedReplyKey(macAddress: String, transferId: Int): String =
    "${macAddress.uppercase()}:$transferId"

  private fun buildReplyDataFrame(chunkIndex: Int, bytes: ByteArray): ByteArray {
    val frame = ByteArray(replyDataFrameHeaderBytes + bytes.size)
    frame[0] = replyDataFrameType.toByte()
    appendFrameU16(frame, 1, chunkIndex)
    System.arraycopy(bytes, 0, frame, replyDataFrameHeaderBytes, bytes.size)
    return frame
  }

  private fun buildReplyStartFrame(
    transferId: Int,
    chunkCount: Int,
    payload: ByteArray,
  ): ByteArray {
    val frame = ByteArray(15)
    frame[0] = replyStartFrameType.toByte()
    writeFrameInt(frame, 1, transferId)
    appendFrameU16(frame, 5, chunkCount)
    writeFrameInt(frame, 7, payload.size)
    val crc = java.util.zip.CRC32().apply { update(payload) }.value.toInt()
    writeFrameInt(frame, 11, crc)
    return frame
  }

  private fun buildReplyEndFrame(
    transferId: Int,
    chunkCount: Int,
    payload: ByteArray,
  ): ByteArray {
    val frame = ByteArray(15)
    frame[0] = replyEndFrameType.toByte()
    writeFrameInt(frame, 1, transferId)
    appendFrameU16(frame, 5, chunkCount)
    writeFrameInt(frame, 7, payload.size)
    val crc = java.util.zip.CRC32().apply { update(payload) }.value.toInt()
    writeFrameInt(frame, 11, crc)
    return frame
  }

  private fun parseReplyFeedback(bytes: ByteArray): Pair<Int, ServerReplyFeedback>? {
    if (bytes.size < 5) return null
    val transferId = readFrameInt(bytes, 1)
    if (transferId <= 0) return null
    return when (bytes[0].toInt() and 0xFF) {
      replyAckFrameType -> if (bytes.size == 5) {
        transferId to ServerReplyFeedback(accepted = true)
      } else {
        null
      }
      replyMissingAllFrameType -> if (bytes.size == 5) {
        transferId to ServerReplyFeedback(accepted = false, retryAll = true)
      } else {
        null
      }
      replyMissingFrameType -> {
        if (bytes.size < 6) return null
        val count = bytes[5].toInt() and 0xFF
        if (count == 0 || count > maxReplyMissingIndicesPerFrame || bytes.size != 6 + count * 2) {
          return null
        }
        val indices = List(count) { index -> readFrameU16(bytes, 6 + index * 2) }
        transferId to ServerReplyFeedback(accepted = false, missingChunkIndices = indices)
      }
      else -> null
    }
  }

  private val REQUEST_BLUETOOTH_PERMS = 4312

  private fun traceBle(
    event: String,
    mac: String? = null,
    attemptId: String? = null,
    fields: Map<String, Any?> = emptyMap(),
    connectionId: String? = null,
  ) {
    val values = mutableListOf(
      "EVENT:$event",
      "MONO_MS:${SystemClock.elapsedRealtime()}",
      "WALL_MS:${System.currentTimeMillis()}",
    )
    if (!mac.isNullOrBlank()) values.add("TARGET_MAC:$mac")
    if (!attemptId.isNullOrBlank()) values.add("ATTEMPT_ID:$attemptId")
    if (!connectionId.isNullOrBlank()) values.add("CONNECTION_ID:$connectionId")
    for ((key, value) in fields) {
      if (value != null) values.add("$key:$value")
    }
    Log.d(TAG, "[BLE_TRACE] ${values.joinToString(" | ")}")
  }

  private fun emitHeldLinkState(
    event: String,
    mac: String? = null,
    releaseInMs: Long? = null,
  ) {
    Handler(Looper.getMainLooper()).post {
      val payload = hashMapOf<String, Any?>(
        "event" to event,
        "mac" to (mac ?: ""),
      )
      if (releaseInMs != null) payload["releaseInMs"] = releaseInMs
      eventSink?.success(payload)
    }
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    requestBluetoothPermissionsIfNeeded()

    val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.featherfawks.mesh/ble")
    val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.featherfawks.mesh/ble_events")

    eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        MeshForegroundServiceEvents.setEventSink(events)
      }

      override fun onCancel(arguments: Any?) {
        eventSink = null
        MeshForegroundServiceEvents.setEventSink(null)
      }
    })

    methodChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "start_mesh_foreground_service" -> {
          startMeshForegroundService(result)
        }
        "stop_mesh_foreground_service" -> {
          Log.i(TAG, "Stopping mesh foreground service from Flutter")
          stopService(Intent(this, MeshForegroundService::class.java))
          result.success(null)
        }
        "set_mesh_foreground_service_active" -> {
          val active = call.argument<Boolean>("active") ?: true
          result.success(MeshForegroundService.setMeshRadioActive(active))
        }
        "get_debug_wake_lock_state" -> {
          val isDebuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
          result.success(isDebuggable && MeshForegroundService.isDebugWakeLockHeld())
        }
        "set_debug_wake_lock" -> {
          if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
            result.error("DEBUG_ONLY", "The test wake lock is only available in debug builds", null)
          } else {
            val enabled = call.argument<Boolean>("enabled") == true
            result.success(MeshForegroundService.setDebugWakeLockEnabled(enabled))
          }
        }
        "start_server" -> {
          startNativeServer(call, result)
        }
        "reset_server" -> {
          resetNativeServer(result)
        }
        "update_hash" -> {
          updateAdvertiserHash(call, result)
        }
        "uses_extended_connectable_advertising" -> {
          result.success(usesExtendedConnectableAdvertising())
        }
        "force_toggle_bluetooth" -> {
          forceToggleBluetooth(result)
        }
        "send_payload" -> {
          sendPayloadToPeer(call, result)
        }
        "reply_payload" -> {
          replyPayloadToPeer(call, result)
        }
        "reply_feedback" -> {
          sendReplyFeedback(call, result)
        }
        "connected_server_macs" -> {
          result.success(ArrayList(notifyReadyServerClients.keys.filter { notifyReadyServerClients[it] == true }))
        }
        "active_server_macs" -> {
          result.success(ArrayList(connectedServerClients.keys))
        }
        "inbound_server_state" -> {
          result.success(
            mapOf(
              "active" to ArrayList(connectedServerClients.keys),
              "ready" to ArrayList(
                notifyReadyServerClients.keys.filter { notifyReadyServerClients[it] == true },
              ),
            ),
          )
        }
        "has_held_client_for_mac" -> {
          val macAddress = call.argument<String>("macAddress")
          val held = heldClientGatt
          result.success(
            !isResettingServer &&
              !isOutboundClientBusy.get() &&
              !macAddress.isNullOrBlank() &&
              held != null &&
              held.device.address.equals(macAddress, ignoreCase = true) &&
              heldWriteChar != null,
          )
        }
        "get_reusable_held_client_mac" -> {
          val held = heldClientGatt
          result.success(
            if (
              !isResettingServer &&
              !isOutboundClientBusy.get() &&
              held != null &&
              heldWriteChar != null
            ) held.device.address else null,
          )
        }
        "has_inbound_clients" -> {
          result.success(connectedServerClients.isNotEmpty())
        }
        "set_link_lease" -> {
          val requestedIdle = call.argument<Number>("idleMs")?.toLong() ?: 4000L
          val requestedMax = call.argument<Number>("maxMs")?.toLong() ?: 15000L
          heldClientIdleMs = requestedIdle.coerceIn(1000L, 10000L)
          heldClientMaxLeaseMs =
            requestedMax.coerceIn(heldClientIdleMs, 60000L)
          Log.d(
            TAG,
            "[GATT] Adaptive lease idle=${heldClientIdleMs}ms max=${heldClientMaxLeaseMs}ms"
          )
          result.success(null)
        }
        "cancel_outbound" -> {
          cancelOutboundClient()
          result.success(null)
        }
        "disconnect_inbound" -> {
          disconnectInboundClients()
          result.success(null)
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun startMeshForegroundService(result: MethodChannel.Result) {
    if (MeshForegroundService.isRunning()) {
      Log.i(TAG, "Mesh foreground service is already running")
      MeshForegroundService.setMeshRadioActive(true)
      result.success(true)
      return
    }
    val serviceIntent = Intent(this, MeshForegroundService::class.java)
      .setAction(MeshForegroundService.ACTION_START)
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        startForegroundService(serviceIntent)
      } else {
        startService(serviceIntent)
      }
      result.success(true)
    } catch (error: Exception) {
      Log.e(TAG, "Failed to start mesh foreground service", error)
      result.error(
        "FOREGROUND_SERVICE_START_FAILED",
        error.message ?: "Android could not start the mesh foreground service",
        null,
      )
    }
  }

  override fun onPause() {
    super.onPause()
    Log.d(TAG, "[DIAGNOSTIC] APP_STATE:BACKGROUND")
  }

  override fun onResume() {
    super.onResume()
    Log.d(TAG, "[DIAGNOSTIC] APP_STATE:FOREGROUND")
  }

  @SuppressLint("MissingPermission")
  private fun forceToggleBluetooth(result: MethodChannel.Result) {
    val adapter = BluetoothAdapter.getDefaultAdapter() ?: run {
      result.error("no_adapter", "Bluetooth adapter not available", null)
      return
    }

    if (android.os.Build.VERSION.SDK_INT >= 31) {
      // Android 12+ requires a specific system intent to toggle BT;
      // manual enable/disable is restricted for third-party apps.
      result.success(false) 
      return
    }

    try {
      Log.w(TAG, "!!! [HARD RESET] Manually power-cycling Bluetooth adapter...")
      adapter.disable()
      // Wait for the adapter to actually turn off before turning it back on.
      Handler(Looper.getMainLooper()).postDelayed({
        adapter.enable()
        Log.w(TAG, "!!! [HARD RESET] Bluetooth adapter re-enabled.")
        result.success(true)
      }, 2000)
    } catch (t: Throwable) {
      Log.e(TAG, "Failed to power-cycle Bluetooth", t)
      result.error("reset_failed", t.message, null)
    }
  }

  private fun requestBluetoothPermissionsIfNeeded() {
    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return
    val needed = arrayOf(
      Manifest.permission.BLUETOOTH_CONNECT,
      Manifest.permission.BLUETOOTH_ADVERTISE,
      Manifest.permission.BLUETOOTH_SCAN
    )

    val missing = needed.filter {
      ActivityCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
    }

    if (missing.isNotEmpty()) {
      ActivityCompat.requestPermissions(
        this,
        missing.toTypedArray(),
        REQUEST_BLUETOOTH_PERMS
      )
    }
  }

  @SuppressLint("MissingPermission")
  private fun startNativeServer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    try {
      if (bluetoothGattServer != null) {
        result.success(null)
        return
      }

      serverServiceReady = false

      val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
      val adapter = bluetoothManager.adapter
      val startupHandler = Handler(Looper.getMainLooper())
      val startupResultCompleted = AtomicBoolean(false)
      var serviceRegistrationTimeout: Runnable? = null

      fun finishStartupAfterServiceRegistration(status: Int) {
        startupHandler.post {
          if (!startupResultCompleted.compareAndSet(false, true)) return@post
          serviceRegistrationTimeout?.let(startupHandler::removeCallbacks)

          if (status != BluetoothGatt.GATT_SUCCESS) {
            serverServiceReady = false
            traceBle(
              "SERVER_SERVICE_REGISTRATION_FAILED",
              fields = mapOf("STATUS" to status),
            )
            try { bluetoothGattServer?.close() } catch (_: Throwable) {}
            bluetoothGattServer = null
            result.error("service_add_failed", "GATT service registration failed with status $status", null)
            return@post
          }

          val registeredServices = bluetoothGattServer?.services.orEmpty()
          traceBle(
            "SERVER_SERVICE_READY",
            fields = mapOf(
              "SERVICE_COUNT" to registeredServices.size,
              "SERVICE_UUIDS" to registeredServices.joinToString(",") { it.uuid.toString() },
            ),
          )
          serverServiceReady = true
          isResettingServer = false
          try {
            // addService() only queues registration with Android. Advertising here,
            // before onServiceAdded(), lets peers connect while the GATT database is
            // still unavailable and can leave their service discovery callback hanging.
            advertiser = adapter.bluetoothLeAdvertiser
            if (advertiser == null) {
              serverServiceReady = false
              try { bluetoothGattServer?.close() } catch (_: Throwable) {}
              bluetoothGattServer = null
              result.error("advertiser_unavailable", "BluetoothLeAdvertiser is null", null)
              return@post
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
              startModernAdvertising(currentAdvertiserHash)
            } else {
              startLegacyAdvertising(currentAdvertiserHash)
            }

            // Return our own BLE address so Dart can filter self-advertisements from scan results.
            val ownAddress = try { adapter.address } catch (_: Throwable) { "" }
            Log.d(TAG, "[SERVER] Own BLE address: $ownAddress")
            result.success(ownAddress)
          } catch (t: Throwable) {
            serverServiceReady = false
            try { bluetoothGattServer?.close() } catch (_: Throwable) {}
            bluetoothGattServer = null
            result.error("server_error", t.message ?: "Unknown error", null)
          }
        }
      }

      val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
          super.onServiceAdded(status, service)
          if (service.uuid != SERVICE_UUID) return
          traceBle(
            "SERVER_SERVICE_ADDED_CALLBACK",
            fields = mapOf("STATUS" to status, "UUID" to service.uuid.toString()),
          )
          finishStartupAfterServiceRegistration(status)
        }

        override fun onCharacteristicWriteRequest(
          device: BluetoothDevice,
          requestId: Int,
          characteristic: BluetoothGattCharacteristic,
          preparedWrite: Boolean,
          responseNeeded: Boolean,
          offset: Int,
          value: ByteArray?
        ) {
          var responseStatus = BluetoothGatt.GATT_SUCCESS
          try {
            if (characteristic.uuid != CHARACTERISTIC_UUID) return
            if (
              isResettingServer || !serverServiceReady ||
              connectedServerClients[device.address] != true
            ) {
              responseStatus = BluetoothGatt.GATT_FAILURE
              traceBle("SERVER_WRITE_REJECTED_UNADMITTED", device.address)
              return
            }
            val bytes = value ?: ByteArray(0)
            val now = SystemClock.elapsedRealtime()
            serverClientLastActivityAtMs[device.address] = now
            val firstByte = bytes.firstOrNull()?.toInt()?.and(0xFF)
            val pending = pendingServerReplyAcks[device.address]
            if (
              pending != null &&
                (firstByte == replyAckFrameType ||
                  firstByte == replyMissingFrameType ||
                  firstByte == replyMissingAllFrameType)
            ) {
              val parsed = parseReplyFeedback(bytes)
              val matched = parsed != null && pending != null &&
                pending.transferId == parsed.first
              traceBle(
                if (matched) {
                  if (parsed!!.second.accepted) "SERVER_REPLY_ACK_RECEIVED" else "SERVER_REPLY_NACK_RECEIVED"
                } else {
                  "SERVER_REPLY_FEEDBACK_REJECTED"
                },
                device.address,
                connectionId = serverConnectionIds[device.address],
                fields = mapOf(
                  "BYTES" to bytes.size,
                  "TRANSFER_ID" to parsed?.first,
                  "MATCHED" to matched,
                  "MISSING_COUNT" to parsed?.second?.missingChunkIndices?.size,
                  "RETRY_ALL" to parsed?.second?.retryAll,
                ),
              )
              if (matched) pending?.feedback?.offer(parsed!!.second)
              else responseStatus = BluetoothGatt.GATT_FAILURE
              return
            }
            traceBle(
              "SERVER_WRITE_CHUNK",
              device.address,
              connectionId = serverConnectionIds[device.address],
              fields = mapOf(
                "BYTES" to bytes.size,
                "OFFSET" to offset,
                "EOF" to bytes.contentEquals("||EOF||".toByteArray()),
              ),
            )
            deadMacs.remove(device.address)
            failureCounts.remove(device.address)
            Handler(Looper.getMainLooper()).post {
              // Include sender MAC so Dart can reply even if scan routing isn't ready.
            val payload: HashMap<String, Any> = hashMapOf(
              "mac" to device.address,
              "bytes" to bytes
            )
            serverConnectionIds[device.address]?.let {
              payload["connectionId"] = it
            }
            eventSink?.success(payload)
            }
          } catch (t: Throwable) {
            responseStatus = BluetoothGatt.GATT_FAILURE
            Log.e(TAG, "Failed pushing payload to Flutter", t)
          } finally {
            if (responseNeeded && bluetoothGattServer != null) {
              bluetoothGattServer?.sendResponse(
                device,
                requestId,
                responseStatus,
                offset,
                value ?: ByteArray(0)
              )
            }
          }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
          super.onMtuChanged(device, mtu)
          if (connectedServerClients[device.address] != true) {
            traceBle("SERVER_MTU_IGNORED_UNADMITTED", device.address, fields = mapOf("MTU" to mtu))
            return
          }
          Log.d(TAG, "[SERVER] onMtuChanged: mtu=$mtu for device=${device.address}")
          serverMtuMap[device.address] = mtu
          serverClientLastActivityAtMs[device.address] = SystemClock.elapsedRealtime()
          traceBle(
            "SERVER_MTU_CHANGED",
            device.address,
            connectionId = serverConnectionIds[device.address],
            fields = mapOf("MTU" to mtu),
          )
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
          super.onNotificationSent(device, status)
          synchronized(serverNotifyLock) {
            lastNotifyOk = (status == BluetoothGatt.GATT_SUCCESS)
            lastNotifyMac = device.address
            serverNotifyLock.notifyAll()
          }
          val startedAt = notifyStartedAtMs
          traceBle(
            "SERVER_NOTIFY_CALLBACK",
            device.address,
            connectionId = serverConnectionIds[device.address],
            fields = mapOf(
              "STATUS" to status,
              "DURATION_MS" to if (startedAt > 0L) SystemClock.elapsedRealtime() - startedAt else null,
            ),
          )
        }

        override fun onDescriptorWriteRequest(
          device: BluetoothDevice,
          requestId: Int,
          descriptor: BluetoothGattDescriptor,
          preparedWrite: Boolean,
          responseNeeded: Boolean,
          offset: Int,
          value: ByteArray?
        ) {
          super.onDescriptorWriteRequest(device, requestId, descriptor, preparedWrite, responseNeeded, offset, value)
          if (
            isResettingServer || !serverServiceReady ||
            connectedServerClients[device.address] != true
          ) {
            traceBle("SERVER_CCCD_REJECTED_UNADMITTED", device.address)
            if (responseNeeded) {
              bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, value ?: ByteArray(0))
            }
            return
          }
          Log.d(TAG, "[SERVER] CCCD write from ${device.address} value=${value?.toList()}")
          if (responseNeeded) {
            bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value ?: ByteArray(0))
          }
          if (descriptor.uuid == CCCD_UUID && value != null) {
            serverClientLastActivityAtMs[device.address] = SystemClock.elapsedRealtime()
            val notificationEnabled = value.isNotEmpty() && (value[0].toInt() and 0x01) != 0
            val indicationEnabled = value.isNotEmpty() && (value[0].toInt() and 0x02) != 0
            if (indicationEnabled) {
              notifyReadyServerClients[device.address] = true
              val connectedAt = serverClientConnectedAtMs[device.address] ?: SystemClock.elapsedRealtime()
              traceBle(
                "SERVER_CCCD_READY",
                device.address,
                connectionId = serverConnectionIds[device.address],
                fields = mapOf(
                  "CONNECT_TO_READY_MS" to SystemClock.elapsedRealtime() - connectedAt,
                  "NOTIFICATIONS_ENABLED" to notificationEnabled,
                  "INDICATIONS_ENABLED" to indicationEnabled,
                ),
              )
              Handler(Looper.getMainLooper()).post {
                eventSink?.success(
                  hashMapOf(
                    "event" to "server_ready",
                    "mac" to device.address,
                    "connectionId" to (serverConnectionIds[device.address] ?: ""),
                    "indicationsEnabled" to indicationEnabled,
                  )
                )
              }
            } else {
              notifyReadyServerClients.remove(device.address)
              traceBle(
                "SERVER_CCCD_DISABLED",
                device.address,
                connectionId = serverConnectionIds[device.address],
              )
              Handler(Looper.getMainLooper()).post {
                eventSink?.success(
                  hashMapOf(
                    "event" to "server_not_ready",
                    "mac" to device.address,
                    "connectionId" to (serverConnectionIds[device.address] ?: ""),
                  ),
                )
              }
            }
          }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
          super.onConnectionStateChange(device, status, newState)
          // During reset/startup, reject links before their server-side GATT database
          // is ready. A peer may still have a connect attempt in flight even after its
          // scan has stopped; leaving that link attached can make Android 15 receive a
          // primary-service request without returning an ATT response.
          if (isResettingServer || !serverServiceReady) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
              traceBle(
                "SERVER_CONNECTION_REJECTED_BEFORE_SERVICE_READY",
                device.address,
                fields = mapOf(
                  "STATUS" to status,
                  "RESETTING" to isResettingServer,
                  "SERVICE_READY" to serverServiceReady,
                ),
              )
              try { bluetoothGattServer?.cancelConnection(device) } catch (_: Throwable) {}
            }
            return
          }
          if (newState == BluetoothProfile.STATE_CONNECTED) {
            val now = SystemClock.elapsedRealtime()
            val newConnectionId = UUID.randomUUID().toString().take(8)
            var rejectedReason: String? = null
            var stalePendingMacToCancel: String? = null
            var connectionId = newConnectionId
            var activeConns = 0
            synchronized(serverClientLock) {
              if (connectedServerClients.containsKey(device.address)) return
              val currentInbound = connectedServerClients.size
              if (currentInbound >= maxInboundServerClients) {
                val stalePendingMac = connectedServerClients.keys.firstOrNull { mac ->
                  val lastActivity = serverClientLastActivityAtMs[mac]
                    ?: serverClientConnectedAtMs[mac]
                    ?: now
                  notifyReadyServerClients[mac] != true &&
                    !serverClientEvicting.containsKey(mac) &&
                    now - lastActivity >= pendingInboundStaleAfterMs
                }
                if (stalePendingMac == null) {
                  rejectedReason = "inbound_cap_$currentInbound"
                } else {
                  serverClientEvicting[stalePendingMac] = true
                  stalePendingMacToCancel = stalePendingMac
                  rejectedReason = "stale_pending_slot_releasing"
                }
              }
              if (rejectedReason == null) {
                connectedServerClients[device.address] = true
                serverClientConnectedAtMs[device.address] = now
                serverClientLastActivityAtMs[device.address] = now
                serverConnectionIds[device.address] = newConnectionId
                connectionId = newConnectionId
              }
              activeConns = connectedServerClients.size
              activeInboundServers.set(activeConns)
            }

            stalePendingMacToCancel?.let { staleMac ->
              Log.w(
                TAG,
                "[DIAGNOSTIC] TARGET_MAC:$staleMac | EVENT:CONNECTION_EVICTION_REQUESTED | REASON:unready_idle_timeout"
              )
              traceBle(
                "SERVER_PENDING_EVICTION_REQUESTED",
                staleMac,
                fields = mapOf("REASON" to "unready_idle_timeout"),
              )
              try {
                val staleDevice = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(staleMac)
                if (staleDevice != null) bluetoothGattServer?.cancelConnection(staleDevice)
              } catch (_: Throwable) {}
            }

            if (rejectedReason != null) {
              Log.w(
                TAG,
                "[DIAGNOSTIC] TARGET_MAC:${device.address} | EVENT:CONNECTION_REJECTED | REASON:$rejectedReason"
              )
              traceBle(
                "SERVER_CONNECTION_REJECTED",
                device.address,
                fields = mapOf("REASON" to rejectedReason, "ACTIVE" to activeConns),
              )
              try {
                bluetoothGattServer?.cancelConnection(device)
              } catch (_: Throwable) {}
              return
            }

            Log.d(TAG, "[SERVER] Client connected: ${device.address}. Active inbound connections: $activeConns")
            traceBle(
              "SERVER_CONNECTED",
              device.address,
              connectionId = connectionId,
              fields = mapOf("ACTIVE" to activeConns),
            )
            if (activeConns > 1) {
              Log.w(TAG, "[DIAGNOSTIC] SERVER COLLISION WARNING! Multiple concurrent clients connected ($activeConns). This may cause GATT 133 panics.")
            }
            updateServerBusyState()
            scheduleInboundIdleSweep()
            Handler(Looper.getMainLooper()).post {
              eventSink?.success(
                hashMapOf(
                  "event" to "server_connect",
                  "mac" to device.address,
                  "connectionId" to connectionId,
                ),
              )
            }
          } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            var activeConnsBefore = 0
            var activeConnsAfter = 0
            var connectionId: String? = null
            var wasConnected = false
            synchronized(serverClientLock) {
              activeConnsBefore = connectedServerClients.size
              wasConnected = connectedServerClients.remove(device.address) != null
              notifyReadyServerClients.remove(device.address)
              serverClientConnectedAtMs.remove(device.address)
              serverClientLastActivityAtMs.remove(device.address)
              connectionId = serverConnectionIds.remove(device.address)
              serverClientEvicting.remove(device.address)
              serverMtuMap.remove(device.address)
              activeConnsAfter = connectedServerClients.size
              activeInboundServers.set(activeConnsAfter)
            }
            if (wasConnected) {
              pendingServerReplyAcks.remove(device.address)?.let { pending ->
                traceBle("SERVER_REPLY_ACK_CANCELLED_DISCONNECT", device.address, connectionId = connectionId)
                pending.feedback.offer(ServerReplyFeedback(accepted = false))
              }
              Log.d(TAG, "[SERVER] Client disconnected: ${device.address} status=$status. Active inbound connections now: $activeConnsAfter")
              traceBle(
                "SERVER_DISCONNECTED",
                device.address,
                connectionId = connectionId,
                fields = mapOf("STATUS" to status, "ACTIVE" to activeConnsAfter),
              )
              Handler(Looper.getMainLooper()).post {
                eventSink?.success(
                  hashMapOf(
                    "event" to "server_disconnect",
                    "mac" to device.address,
                    "connectionId" to (connectionId ?: ""),
                  ),
                )
              }
              if (status != 0 && activeConnsBefore > 1) {
                Log.e(TAG, "[DIAGNOSTIC] SERVER COLLISION ERROR! Disconnection with status=$status while having $activeConnsBefore active connections.")
              }
              updateServerBusyState()
              try { bluetoothGattServer?.cancelConnection(device) } catch (_: Throwable) {}
            }
          }
        }
      }

      bluetoothGattServer = bluetoothManager.openGattServer(this, callback)
        ?: run {
          result.error("server_unavailable", "openGattServer returned null", null)
          return
        }

      val hashBytes = coercePayloadBytes(call.argument<Any?>("hash"))
      if (hashBytes != null && hashBytes.isNotEmpty()) {
        currentAdvertiserHash = hashBytes
      }
      val nodeId = call.argument<String>("nodeId")
      if (nodeId != null && nodeId.length >= 4) {
        currentNodeIdPrefix = nodeId.substring(0, 4).toByteArray()
      }

      // Queue the GATT service registration. Android confirms that the service is
      // actually available through onServiceAdded(); advertising waits for that callback.
      val writeNoResponseCharacteristic = BluetoothGattCharacteristic(
        CHARACTERISTIC_UUID,
        // Support both write-with-response (client reliability) and no-response.
        // Still strictly PERMISSION_WRITE (no reads, no encryption requirements).
        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_WRITE,
        BluetoothGattCharacteristic.PERMISSION_WRITE
      )

      // New: NOTIFY characteristic so Server can push Delta payload back to Client
      // over the existing open connection, eliminating the GATT 257 reconnect race.
      val notifyCharacteristic = BluetoothGattCharacteristic(
        NOTIFY_CHARACTERISTIC_UUID,
        BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE,
        BluetoothGattCharacteristic.PERMISSION_READ
      )
      val cccd = BluetoothGattDescriptor(
        CCCD_UUID,
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
      )
      notifyCharacteristic.addDescriptor(cccd)

      val service = BluetoothGattService(
        SERVICE_UUID,
        BluetoothGattService.SERVICE_TYPE_PRIMARY
      )
      service.addCharacteristic(writeNoResponseCharacteristic)
      service.addCharacteristic(notifyCharacteristic)

      val added = bluetoothGattServer?.addService(service) ?: false
      if (!added) {
        serverServiceReady = false
        startupResultCompleted.set(true)
        try { bluetoothGattServer?.close() } catch (_: Throwable) {}
        bluetoothGattServer = null
        result.error("service_add_failed", "Failed to add GATT service", null)
        return
      }

      serviceRegistrationTimeout = Runnable {
        if (!startupResultCompleted.compareAndSet(false, true)) return@Runnable
        serverServiceReady = false
        traceBle("SERVER_SERVICE_REGISTRATION_TIMEOUT", fields = mapOf("TIMEOUT_MS" to 5000))
        try { bluetoothGattServer?.close() } catch (_: Throwable) {}
        bluetoothGattServer = null
        result.error("service_add_timeout", "Timed out waiting for Android to register the GATT service", null)
      }
      startupHandler.postDelayed(serviceRegistrationTimeout!!, 5000)
    } catch (t: Throwable) {
      serverServiceReady = false
      result.error("server_error", t.message ?: "Unknown error", null)
    }
  }

  @SuppressLint("MissingPermission")
  private fun resetNativeServer(result: MethodChannel.Result) {
    Log.d(TAG, "[SERVER] Resetting GATT server to release leaked connection slots...")
    // Raise the guard flag BEFORE close() so the DISCONNECTED callbacks fired
    // by close() are silently swallowed instead of cascading into cancelConnection() calls.
    isResettingServer = true
    serverServiceReady = false
    outboundCancelGeneration.incrementAndGet()
    val outboundGatt = currentOutboundGatt
    currentOutboundGatt = null
    try { outboundGatt?.disconnect() } catch (_: Throwable) {}
    try { outboundGatt?.close() } catch (_: Throwable) {}
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        advertisingSetCallback?.let { cb ->
          try { advertiser?.stopAdvertisingSet(cb) } catch (_: Throwable) {}
        }
        advertisingSetCallback = null
        currentAdvertisingSet = null
      }
      advertiser?.let { adv ->
        advertiseCallback?.let { cb ->
          try { adv.stopAdvertising(cb) } catch (_: Throwable) {}
        }
      }
      // close() unregisters this GATT server and releases its hosted services.
      // Calling clearServices() immediately before close() queues a second, async
      // database mutation. On Android 15 we observed service discovery requests
      // reach the peripheral with no ATT response after a rapid clear/close/reopen.
      bluetoothGattServer?.close()
    } catch (_: Throwable) {}
    bluetoothGattServer = null
    connectedServerClients.clear()
    notifyReadyServerClients.clear()
    serverClientConnectedAtMs.clear()
    serverClientLastActivityAtMs.clear()
    serverConnectionIds.clear()
    serverClientEvicting.clear()
    serverMtuMap.clear()
    pendingServerReplyAcks.values.forEach { it.feedback.offer(ServerReplyFeedback(accepted = false)) }
    pendingServerReplyAcks.clear()
    deadMacs.clear()
    isOutboundClientBusy.set(false)
    activeInboundServers.set(0)
    Handler(Looper.getMainLooper()).post {
      eventSink?.success(hashMapOf("event" to "server_reset"))
    }
    try {
      heldClientHandler.removeCallbacks(heldClientRelease)
    } catch (_: Throwable) {}
    val held = heldClientGatt
    heldClientGatt = null
    heldClientTraceAttemptId = null
    heldClientLeaseStartedAtMs = 0L
    try { held?.close() } catch (_: Throwable) {}
    // Let Android finish unregistering the old server before reusing its serverIf.
    // startAdvertising() opens and registers the replacement as soon as this result
    // completes, so return asynchronously after a short teardown settling window.
    // Keep the reset guard active until the replacement service is registered; the
    // stress runner pauses scans on all peers before reaching this point.
    Handler(Looper.getMainLooper()).postDelayed({
      traceBle("SERVER_RESET_SETTLED", fields = mapOf("WAIT_MS" to 500))
      Log.d(TAG, "[SERVER] GATT server reset complete.")
      result.success(null)
    }, 500L)
  }

  @SuppressLint("MissingPermission")
  private fun releaseHeldClientNow(reason: String = "explicit") {
    heldClientHandler.removeCallbacks(heldClientRelease)
    val g = heldClientGatt
    if (g != null) {
      val now = System.currentTimeMillis()
      val leaseStartedAt = heldClientLeaseStartedAtMs
      val heldMac = try { g.device.address } catch (_: Throwable) { null }
      traceBle(
        "CLIENT_HELD_LINK_RELEASED",
        mac = heldMac,
        attemptId = heldClientTraceAttemptId,
        fields = mapOf(
          "REASON" to reason,
          "LEASE_AGE_MS" to if (leaseStartedAt > 0L) now - leaseStartedAt else null,
          "IDLE_MS" to heldClientIdleMs,
          "MAX_LEASE_MS" to heldClientMaxLeaseMs,
        ),
      )
      emitHeldLinkState("held_link_unavailable", heldMac)
    }
    heldClientGatt = null
    heldWriteChar = null
    heldClientTraceAttemptId = null
    heldClientLeaseStartedAtMs = 0L
    heldClientReleaseReason = null
    try { g?.disconnect() } catch (_: Throwable) {}
    try { g?.close() } catch (_: Throwable) {}
  }

  @SuppressLint("MissingPermission")
  private fun requestClientConnectionPriority(
    gatt: BluetoothGatt,
    priority: Int,
    reason: String,
    attemptId: String? = null,
  ) {
    val priorityName = when (priority) {
      BluetoothGatt.CONNECTION_PRIORITY_HIGH -> "high"
      BluetoothGatt.CONNECTION_PRIORITY_BALANCED -> "balanced"
      BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER -> "low_power"
      else -> priority.toString()
    }
    try {
      val started = gatt.requestConnectionPriority(priority)
      traceBle(
        "CLIENT_CONNECTION_PRIORITY_REQUESTED",
        try { gatt.device.address } catch (_: Throwable) { null },
        attemptId,
        mapOf(
          "PRIORITY" to priorityName,
          "REASON" to reason,
          "STARTED" to started,
        ),
      )
    } catch (t: Throwable) {
      traceBle(
        "CLIENT_CONNECTION_PRIORITY_FAILED",
        try { gatt.device.address } catch (_: Throwable) { null },
        attemptId,
        mapOf(
          "PRIORITY" to priorityName,
          "REASON" to reason,
          "DETAIL" to t.javaClass.simpleName,
        ),
      )
    }
  }

  private fun scheduleHeldClientRelease(g: BluetoothGatt) {
    if (heldClientGatt !== g) return
    val now = System.currentTimeMillis()
    if (heldClientLeaseStartedAtMs == 0L) {
      heldClientLeaseStartedAtMs = now
    }
    val hardRemaining =
      (heldClientLeaseStartedAtMs + heldClientMaxLeaseMs - now).coerceAtLeast(0L)
    val delayMs = minOf(heldClientIdleMs, hardRemaining)
    val releaseReason = if (hardRemaining <= heldClientIdleMs) "max_lease" else "idle_timeout"
    heldClientReleaseReason = releaseReason
    traceBle(
      "CLIENT_HELD_LINK_LEASE_SCHEDULED",
      mac = try { g.device.address } catch (_: Throwable) { null },
      attemptId = heldClientTraceAttemptId,
      fields = mapOf(
        "IDLE_MS" to heldClientIdleMs,
        "MAX_LEASE_MS" to heldClientMaxLeaseMs,
        "LEASE_AGE_MS" to (now - heldClientLeaseStartedAtMs),
        "HARD_REMAINING_MS" to hardRemaining,
        "RELEASE_IN_MS" to delayMs,
        "RELEASE_REASON" to releaseReason,
      ),
    )
    emitHeldLinkState(
      "held_link_ready",
      try { g.device.address } catch (_: Throwable) { null },
      delayMs,
    )
    heldClientHandler.removeCallbacks(heldClientRelease)
    heldClientHandler.postDelayed(heldClientRelease, delayMs)
    Log.d(
      TAG,
      "[GATT] Held-link lease refresh idle=${delayMs}ms hardRemaining=${hardRemaining}ms"
    )
  }

  @SuppressLint("MissingPermission")
  private fun writeOnHeldClient(
    requestedMac: String,
    payload: ByteArray,
    result: MethodChannel.Result,
    attemptId: String,
  ): HeldLinkWriteResult {
    val g = heldClientGatt ?: return HeldLinkWriteResult.NOT_AVAILABLE
    val characteristic = heldWriteChar ?: return HeldLinkWriteResult.NOT_AVAILABLE
    val heldMac = try { g.device.address } catch (_: Throwable) { null }
    if (!HeldLinkTargetPolicy.matches(heldMac, requestedMac)) {
      traceBle(
        "CLIENT_HELD_LINK_TARGET_MISMATCH",
        heldMac,
        attemptId,
        mapOf("REQUESTED_MAC" to requestedMac),
      )
      return HeldLinkWriteResult.NOT_AVAILABLE
    }
    if (!isOutboundClientBusy.compareAndSet(false, true)) {
      emitHeldLinkState(
        "held_link_busy",
        try { g.device.address } catch (_: Throwable) { null },
      )
      Handler(Looper.getMainLooper()).post {
        result.error("gatt_busy", "Held client write already in flight", null)
      }
      return HeldLinkWriteResult.COMPLETED
    }
    emitHeldLinkState(
      "held_link_busy",
      try { g.device.address } catch (_: Throwable) { null },
    )
    heldClientHandler.removeCallbacks(heldClientRelease)
    heldClientTraceAttemptId = attemptId
    val notifyLatch = CountDownLatch(1)
    heldNotifyLatch = notifyLatch
    heldNotifyResult = null
    var writeFailureReason: String? = null
    var writeFailureWaitMs = 0L
    try {
      fun writeBlocking(bytes: ByteArray): Boolean {
        synchronized(clientIoLock) { clientIoOk = null }
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          g.writeCharacteristic(
            characteristic,
            bytes,
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
          ) == BluetoothGatt.GATT_SUCCESS
        } else {
          @Suppress("DEPRECATION")
          characteristic.value = bytes
          @Suppress("DEPRECATION")
          g.writeCharacteristic(characteristic)
        }
        if (!started) {
          writeFailureReason = "write_not_started"
          return false
        }
        val startedAtMs = SystemClock.elapsedRealtime()
        val deadlineMs = startedAtMs + heldWriteCallbackTimeoutMs
        var writeSucceeded: Boolean
        synchronized(clientIoLock) {
          while (clientIoOk == null && SystemClock.elapsedRealtime() < deadlineMs) {
            clientIoLock.wait(50L)
          }
          writeSucceeded = clientIoOk == true
        }
        writeFailureWaitMs = SystemClock.elapsedRealtime() - startedAtMs
        if (!writeSucceeded) {
          writeFailureReason = if (writeFailureWaitMs >= heldWriteCallbackTimeoutMs) {
            "write_callback_timeout"
          } else {
            "write_callback_failed"
          }
        }
        return writeSucceeded
      }
      val chunkSize = heldChunkSize.coerceIn(20, 512)
      var offset = 0
      Log.d(TAG, "[GATT] Reusing held client link ${payload.size}B chunk=$chunkSize")
      traceBle(
        "CLIENT_HELD_LINK_REUSE",
        attemptId = attemptId,
        fields = mapOf("BYTES" to payload.size, "CHUNK_SIZE" to chunkSize),
      )
      clientGattWriteLock.lock()
      try {
        while (offset < payload.size) {
          val length = minOf(chunkSize, payload.size - offset)
          if (!writeBlocking(payload.copyOfRange(offset, offset + length))) {
            Log.w(TAG, "[GATT] Held-link write failed — releasing for reconnect")
            traceBle(
              "CLIENT_HELD_LINK_WRITE_FAILED",
              try { g.device.address } catch (_: Throwable) { null },
              attemptId,
              mapOf(
                "REASON" to writeFailureReason,
                "WAIT_MS" to writeFailureWaitMs,
                "BYTES" to length,
                "OFFSET" to offset,
              ),
            )
            releaseHeldClientNow("held_write_failed")
            return HeldLinkWriteResult.FAILED
          }
          offset += length
        }
        if (!writeBlocking("||EOF||".toByteArray())) {
          Log.w(TAG, "[GATT] Held-link EOF failed — releasing for reconnect")
          traceBle(
            "CLIENT_HELD_LINK_WRITE_FAILED",
            try { g.device.address } catch (_: Throwable) { null },
            attemptId,
            mapOf(
              "REASON" to writeFailureReason,
              "WAIT_MS" to writeFailureWaitMs,
              "BYTES" to 7,
              "OFFSET" to payload.size,
            ),
          )
          releaseHeldClientNow("held_eof_write_failed")
          return HeldLinkWriteResult.FAILED
        }
      } finally {
        clientGattWriteLock.unlock()
      }
      if (!notifyLatch.await(heldReplyTimeoutMs, TimeUnit.MILLISECONDS)) {
        Log.w(TAG, "[GATT] Held-link notify timeout — releasing for reconnect")
        traceBle(
          "CLIENT_HELD_LINK_WRITE_FAILED",
          try { g.device.address } catch (_: Throwable) { null },
          attemptId,
          mapOf("REASON" to "notify_timeout", "WAIT_MS" to heldReplyTimeoutMs),
        )
        releaseHeldClientNow("held_notify_timeout")
        return HeldLinkWriteResult.FAILED
      }
      if (heldNotifyResult != true) {
        traceBle(
          "CLIENT_HELD_LINK_WRITE_FAILED",
          try { g.device.address } catch (_: Throwable) { null },
          attemptId,
          mapOf("REASON" to "reply_ack_failed"),
        )
        releaseHeldClientNow("held_reply_ack_failed")
        return HeldLinkWriteResult.FAILED
      }
      Handler(Looper.getMainLooper()).post { result.success(null) }
      heldClientGatt = g
      traceBle("CLIENT_HELD_LINK_COMPLETE", attemptId = attemptId)
      return HeldLinkWriteResult.COMPLETED
    } catch (t: Throwable) {
      Log.e(TAG, "[GATT] Held-link exception ${t.message} — releasing")
      traceBle(
        "CLIENT_HELD_LINK_FAILED",
        attemptId = attemptId,
        fields = mapOf(
          "DETAIL" to t.javaClass.simpleName,
          "REASON" to "exception",
        ),
      )
      releaseHeldClientNow("held_write_exception")
      return HeldLinkWriteResult.FAILED
    } finally {
      if (heldNotifyLatch === notifyLatch) heldNotifyLatch = null
      if (heldNotifyLatch == null) heldNotifyResult = null
      isOutboundClientBusy.set(false)
    }
  }

  @SuppressLint("MissingPermission")
  private fun cancelOutboundClient() {
    outboundCancelGeneration.incrementAndGet()
    val g = currentOutboundGatt
    currentOutboundGatt = null
    try { g?.disconnect() } catch (_: Throwable) {}
    try { g?.close() } catch (_: Throwable) {}
    isOutboundClientBusy.set(false)
    Log.d(TAG, "[GATT] cancel_outbound released client slot")
  }

  @SuppressLint("MissingPermission")
  private fun disconnectInboundClients() {
    val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    val macs = synchronized(serverClientLock) {
      val currentMacs = connectedServerClients.keys.toList()
      connectedServerClients.clear()
      notifyReadyServerClients.clear()
      serverClientConnectedAtMs.clear()
      serverClientLastActivityAtMs.clear()
      serverConnectionIds.clear()
      serverClientEvicting.clear()
      serverMtuMap.clear()
      activeInboundServers.set(0)
      currentMacs
    }
    for (mac in macs) {
      try {
        val device = bm.adapter.getRemoteDevice(mac)
        bluetoothGattServer?.cancelConnection(device)
      } catch (_: Throwable) {}
      Handler(Looper.getMainLooper()).post {
        eventSink?.success(
          hashMapOf(
            "event" to "server_disconnect",
            "mac" to mac,
            "connectionId" to "",
          ),
        )
      }
    }
    updateServerBusyState()
    Log.d(TAG, "[SERVER] disconnect_inbound cleared ${macs.size} client(s)")
  }

  private fun scheduleInboundIdleSweep() {
    inboundIdleHandler.removeCallbacks(inboundIdleSweep)
    inboundIdleHandler.postDelayed(inboundIdleSweep, InboundIdlePolicy.sweepIntervalMs)
  }

  @SuppressLint("MissingPermission")
  private fun sweepIdleInboundClients() {
    val now = SystemClock.elapsedRealtime()
    val zombies = mutableListOf<String>()
    var remaining = 0
    synchronized(serverClientLock) {
      for (mac in connectedServerClients.keys) {
        val lastActivity = serverClientLastActivityAtMs[mac]
          ?: serverClientConnectedAtMs[mac]
          ?: now
        val evict = InboundIdlePolicy.shouldEvict(
          notifyReady = notifyReadyServerClients[mac] == true,
          idleMs = now - lastActivity,
          alreadyEvicting = serverClientEvicting.containsKey(mac),
        )
        if (evict) {
          serverClientEvicting[mac] = true
          zombies.add(mac)
        }
      }
      remaining = connectedServerClients.size
    }
    for (mac in zombies) {
      Log.w(TAG, "[DIAGNOSTIC] TARGET_MAC:$mac | EVENT:CONNECTION_EVICTION_REQUESTED | REASON:idle_sweep")
      traceBle("SERVER_IDLE_EVICTION_REQUESTED", mac, fields = mapOf("REASON" to "idle_sweep"))
      try {
        val device = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(mac)
        if (device != null) bluetoothGattServer?.cancelConnection(device)
      } catch (_: Throwable) {}
      // A dead link may never deliver STATE_DISCONNECTED; free the slot anyway.
      inboundIdleHandler.postDelayed({
        var released = false
        var connectionId: String? = null
        synchronized(serverClientLock) {
          if (connectedServerClients.remove(mac) != null) {
            notifyReadyServerClients.remove(mac)
            serverClientConnectedAtMs.remove(mac)
            serverClientLastActivityAtMs.remove(mac)
            connectionId = serverConnectionIds.remove(mac)
            serverClientEvicting.remove(mac)
            serverMtuMap.remove(mac)
            activeInboundServers.set(connectedServerClients.size)
            released = true
          }
        }
        if (released) {
          traceBle("SERVER_IDLE_SLOT_RELEASED", mac, connectionId = connectionId)
          updateServerBusyState()
          Handler(Looper.getMainLooper()).post {
            eventSink?.success(
              hashMapOf(
                "event" to "server_disconnect",
                "mac" to mac,
                "connectionId" to (connectionId ?: ""),
              ),
            )
          }
        }
      }, 3_000L)
    }
    if (remaining > 0) scheduleInboundIdleSweep()
  }

  @SuppressLint("MissingPermission")
  private fun updateServerBusyState() {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentAdvertisingSet != null) {
          try {
              currentAdvertisingSet?.setAdvertisingData(
                buildActivePrimaryAdvertisingData(currentAdvertiserHash),
              )
          } catch (_: Throwable) {}
      }
  }

  @SuppressLint("MissingPermission")
  private fun updateAdvertiserHash(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val newHash = coercePayloadBytes(call.argument<Any?>("hash"))
    if (newHash == null || newHash.isEmpty()) {
      result.error("bad_args", "hash is required", null)
      return
    }
    currentAdvertiserHash = newHash

    val nodeId = call.argument<String>("nodeId")
    if (nodeId != null && nodeId.length >= 4) {
      currentNodeIdPrefix = nodeId.substring(0, 4).toByteArray()
    }

    if (advertiser == null) {
      Log.d(TAG, "[ADV] Hash update stored (advertiser not yet started)")
      result.success(null)
      return
    }

    // Keep legacy advertising on its proven stop/restart path. AdvertisingSet exposes a
    // scan-response update callback, so try updating the changing hash without stopping the
    // advertiser; some legacy-mode HALs have ignored repeat updates, so a missing/failed callback
    // falls back to the restart path below.
    pendingHashUpdateHandler?.removeCallbacksAndMessages(null)
    val handler = Handler(Looper.getMainLooper())
    pendingHashUpdateHandler = handler
    handler.postDelayed({
      val hex = currentAdvertiserHash.joinToString("") { "%02x".format(it) }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentAdvertisingSet != null) {
        val set = currentAdvertisingSet
        if (set == null) {
          restartModernAdvertisingForHash(hex, "advertising_set_missing")
          return@postDelayed
        }
        if (pendingScanResponseUpdateSet != null) {
          restartModernAdvertisingForHash(hex, "previous_update_still_pending")
          return@postDelayed
        }

        if (usesExtendedConnectableAdvertising()) {
          Log.d(TAG, "[ADV] Updating extended connectable advertising data hex=$hex")
          try {
            set.setAdvertisingData(
              buildConnectableExtendedAd(currentAdvertiserHash),
            )
          } catch (e: Throwable) {
            restartModernAdvertisingForHash(
              hex,
              "extended_advertising_update_exception:${e.javaClass.simpleName}",
            )
          }
          return@postDelayed
        }

        Log.d(TAG, "[ADV] Updating Modern AdvertisingSet scan response in place hex=$hex...")
        val timeout = Runnable {
          if (pendingScanResponseUpdateSet === set &&
              pendingScanResponseUpdateHashHex == hex) {
            clearPendingScanResponseUpdate()
            restartModernAdvertisingForHash(hex, "scan_response_callback_timeout")
          }
        }
        pendingScanResponseUpdateSet = set
        pendingScanResponseUpdateHashHex = hex
        pendingScanResponseUpdateTimeout = timeout
        advertiserUpdateCallbackHandler.postDelayed(timeout, 1200)
        try {
          set.setScanResponseData(
            buildScanResponseData(currentAdvertiserHash, currentNodeIdPrefix),
          )
        } catch (e: Throwable) {
          clearPendingScanResponseUpdate()
          restartModernAdvertisingForHash(hex, "scan_response_update_exception:${e.javaClass.simpleName}")
        }
      } else {
        val adv = advertiser ?: return@postDelayed
        val cb = advertiseCallback ?: return@postDelayed
        val settings = advertiseSettings ?: return@postDelayed
        Log.d(TAG, "[ADV] Restarting Legacy Advertiser for hash update hex=$hex...")
        try { adv.stopAdvertising(cb) } catch (_: Throwable) {}
        adv.startAdvertising(settings, buildPrimaryAd(currentAdvertiserHash), buildScanResponseData(currentAdvertiserHash, currentNodeIdPrefix), cb)
        Log.d(TAG, "[ADV] (Legacy) Advertiser hash updated to $hex (debounced)")
      }
    }, 3000)


    result.success(null)
  }

  private fun clearPendingScanResponseUpdate() {
    pendingScanResponseUpdateTimeout?.let {
      advertiserUpdateCallbackHandler.removeCallbacks(it)
    }
    pendingScanResponseUpdateTimeout = null
    pendingScanResponseUpdateSet = null
    pendingScanResponseUpdateHashHex = null
  }

  @SuppressLint("MissingPermission")
  private fun restartModernAdvertisingForHash(hex: String, reason: String) {
    Log.w(TAG, "[ADV] Restarting Modern AdvertisingSet after in-place update $reason hex=$hex")
    clearPendingScanResponseUpdate()
    try {
      val callback = advertisingSetCallback
      if (callback != null) advertiser?.stopAdvertisingSet(callback)
    } catch (e: Throwable) {
      Log.e(TAG, "[ADV] stopAdvertisingSet error: ${e.message}")
    }
    currentAdvertisingSet = null
    startModernAdvertising(currentAdvertiserHash)
  }

  /** Primary Ad: Service UUID triggers hardware filter. Kept minimal to fit all OEM 31-byte budgets. */
  private fun buildPrimaryAd(hashPayload: ByteArray): AdvertiseData {
    // For legacy mode, the hash goes into the scan response because
    // Flags (3) + 128-bit UUID (18) + Manufacturer Data (20) = 41 bytes (exceeds 31).
    return AdvertiseData.Builder()
      .setIncludeTxPowerLevel(false)
      .setIncludeDeviceName(false)
      .addServiceUuid(ParcelUuid(SERVICE_UUID))
      .addManufacturerData(0xFFE1, buildTelemetryBytes())
      .build()
  }

  private fun usesExtendedConnectableAdvertising(): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

  private fun buildActivePrimaryAdvertisingData(hashPayload: ByteArray): AdvertiseData =
    if (usesExtendedConnectableAdvertising()) {
      buildConnectableExtendedAd(hashPayload)
    } else {
      buildPrimaryAd(hashPayload)
    }

  private fun buildConnectableExtendedAd(hashPayload: ByteArray): AdvertiseData {
    return AdvertiseData.Builder()
      .setIncludeTxPowerLevel(false)
      .setIncludeDeviceName(false)
      .addServiceUuid(ParcelUuid(SERVICE_UUID))
      .addManufacturerData(0xFFE1, buildTelemetryBytes())
      .addManufacturerData(
        MESH_MFG_ID,
        buildMeshManufacturerPayload(hashPayload, currentNodeIdPrefix),
      )
      .build()
  }

  private fun buildTelemetryBytes(): ByteArray {
      val telemetry = ByteArray(4)
      // Keep the stable node prefix in the primary advertisement. The full
      // database hash and prefix remain in the scan response, which can arrive
      // later; this prefix lets both peers elect the same dialer and filter our
      // own resolvable address during that gap.
      val prefixText = String(currentNodeIdPrefix, Charsets.UTF_8).take(4)
      val prefixValue = prefixText.toIntOrNull(16) ?: 0
      telemetry[0] = ((prefixValue shr 8) and 0xFF).toByte()
      telemetry[1] = (prefixValue and 0xFF).toByte()
      
      val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
      val activeNetwork = connectivityManager.activeNetwork
      val networkCapabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
      val isGateway = networkCapabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true

      val batteryStatus: Intent? = IntentFilter(Intent.ACTION_BATTERY_CHANGED).let { ifilter ->
          applicationContext.registerReceiver(null, ifilter)
      }
      val level: Int = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
      val scale: Int = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
      val batteryPct = if (scale > 0) level * 100f / scale else 100f
      val isLowBattery = batteryPct < 15f

      val isLegacy = Build.VERSION.SDK_INT < Build.VERSION_CODES.O
      val isIOS = false
      // Match the advertised bit to the actual inbound limit. With a one-client
      // cap, the previous >=2 threshold never reported busy and peers kept colliding.
      val isBusy = activeInboundServers.get() >= maxInboundServerClients
      val hopDistance = 0 

      var flags = 0
      if (isGateway) flags = flags or (1 shl 0)
      if (isLowBattery) flags = flags or (1 shl 1)
      if (isLegacy) flags = flags or (1 shl 2)
      if (isIOS) flags = flags or (1 shl 3)
      if (isBusy) flags = flags or (1 shl 4)
      
      val clampedHop = hopDistance.coerceIn(0, 3)
      flags = flags or (clampedHop shl 5)
      // Bits 7 and 8 advertise that this build reports its GATT dial
      // capability and whether its active advertiser uses extended
      // connectable advertising. Peers that do not set bit 7 use the
      // established node-ID election for backwards compatibility.
      flags = flags or (1 shl 7)
      if (usesExtendedConnectableAdvertising()) flags = flags or (1 shl 8)
      // Bit 15 marks bytes 0..1 as the compact node-ID prefix. Older builds
      // ignore this reserved flag bit and continue to read the busy flag.
      flags = flags or (1 shl 15)

      telemetry[2] = (flags and 0xFF).toByte()
      telemetry[3] = ((flags shr 8) and 0xFF).toByte()

      val hex0 = String.format("%02X", telemetry[0].toInt() and 0xFF)
      val hex1 = String.format("%02X", telemetry[1].toInt() and 0xFF)
      Log.d(TAG, "[DIAGNOSTIC] BROADCASTING NODE PREFIX BYTES: 0x$hex0 0x$hex1")

      return telemetry
  }

  private fun buildScanResponseData(hash: ByteArray, prefix: ByteArray? = null): AdvertiseData {
    // Dart's scanner reads the first 8 hash bytes and then the 4-byte node
    // prefix. Keep this wire format fixed even when the database hash grows.
    return AdvertiseData.Builder()
      .addManufacturerData(
        MESH_MFG_ID,
        buildMeshManufacturerPayload(hash, prefix),
      )
      .build()
  }

  private fun buildMeshManufacturerPayload(
    hash: ByteArray,
    prefix: ByteArray?,
  ): ByteArray {
    val hashLength = minOf(hash.size, 8)
    val prefixLength = prefix?.size ?: 0
    // Android 9 receives this mesh manufacturer payload consistently even
    // when it omits the separate FFE1 telemetry manufacturer field from
    // extended advertising scan results. Append a versioned two-byte dial
    // capability trailer; existing readers ignore bytes after the node prefix.
    val capabilityTrailerSize = if (hashLength == 8 && prefixLength == 4) 2 else 0
    val payloadSize = MESH_MAGIC.size + hashLength + prefixLength + capabilityTrailerSize
    val payload = ByteArray(payloadSize)
    System.arraycopy(MESH_MAGIC, 0, payload, 0, MESH_MAGIC.size)
    System.arraycopy(hash, 0, payload, MESH_MAGIC.size, hashLength)
    if (prefix != null) {
      System.arraycopy(prefix, 0, payload, MESH_MAGIC.size + hashLength, prefix.size)
    }
    if (capabilityTrailerSize > 0) {
      val trailerOffset = MESH_MAGIC.size + hashLength + prefixLength
      payload[trailerOffset] = MESH_DIAL_CAPABILITY_MARKER
      var capabilityFlags = 1 // Bit 0 marks these capability flags as known.
      if (usesExtendedConnectableAdvertising()) capabilityFlags = capabilityFlags or (1 shl 1)
      // Some Android scanners omit FFE1 from extended advertising results.
      // Mirror the single-client server state in the mesh payload so peers can
      // avoid cold dials while this GATT server is occupied.
      if (activeInboundServers.get() >= maxInboundServerClients) {
        capabilityFlags = capabilityFlags or (1 shl 2)
      }
      payload[trailerOffset + 1] = capabilityFlags.toByte()
    }
    return payload
  }

  @SuppressLint("MissingPermission")
  @RequiresApi(Build.VERSION_CODES.O)
  private fun startModernAdvertising(hashPayload: ByteArray) {
    val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    val extendedConnectable = usesExtendedConnectableAdvertising()
    val parameters = AdvertisingSetParameters.Builder()
      .setLegacyMode(!extendedConnectable)
      .setConnectable(true)
      .setScannable(!extendedConnectable)
      .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
      .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
      .build()

    val scanResponse = if (extendedConnectable) {
      null
    } else {
      buildScanResponseData(hashPayload, currentNodeIdPrefix)
    }
    val primaryAd = buildActivePrimaryAdvertisingData(hashPayload)
    Log.i(
      TAG,
      "[ADV] Starting AdvertisingSet legacy=${!extendedConnectable} " +
        "connectable=${parameters.isConnectable} scannable=${parameters.isScannable} " +
        "extendedSupported=${adapter.isLeExtendedAdvertisingSupported}",
    )

    advertisingSetCallback = object : AdvertisingSetCallback() {
      override fun onAdvertisingSetStarted(advertisingSet: AdvertisingSet?, txPower: Int, status: Int) {
        if (status == ADVERTISE_SUCCESS) {
          currentAdvertisingSet = advertisingSet
          Log.i(
            TAG,
            "[ADV] AdvertisingSet started legacy=${!extendedConnectable} " +
              "connectable=${parameters.isConnectable} scannable=${parameters.isScannable} " +
              "txPower=$txPower",
          )
        } else {
          Log.e(TAG, "[ADV] Modern AdvertisingSet FAILED status=$status — falling back to legacy advertiser")
          currentAdvertisingSet = null
          Handler(Looper.getMainLooper()).post { startLegacyAdvertising(hashPayload) }
        }
      }
      override fun onAdvertisingSetStopped(advertisingSet: AdvertisingSet?) {
        if (currentAdvertisingSet == advertisingSet) {
          currentAdvertisingSet = null
        }
        Log.d(TAG, "[ADV] Modern AdvertisingSet stopped")
      }
      override fun onScanResponseDataSet(advertisingSet: AdvertisingSet?, status: Int) {
        if (advertisingSet == null || advertisingSet !== pendingScanResponseUpdateSet) {
          Log.d(TAG, "[ADV] Scan-response update callback status=$status without matching request")
          return
        }
        val hex = pendingScanResponseUpdateHashHex ?: "unknown"
        clearPendingScanResponseUpdate()
        if (status == ADVERTISE_SUCCESS) {
          Log.d(TAG, "[ADV] Modern AdvertisingSet scan response updated in place status=$status hex=$hex")
        } else {
          restartModernAdvertisingForHash(hex, "scan_response_status_$status")
        }
      }
      override fun onAdvertisingEnabled(advertisingSet: AdvertisingSet?, enable: Boolean, status: Int) {
        Log.d(TAG, "[ADV] Modern advertising enabled=$enable status=$status")
      }
    }

    try {
      // Legacy mode stays connectable and scannable across the Android 9/15 pair.
      advertiser?.startAdvertisingSet(parameters, primaryAd, scanResponse, null, null, advertisingSetCallback)
    } catch (e: Throwable) {
      Log.e(TAG, "[ADV] startAdvertisingSet threw exception: ${e.message} — falling back to legacy advertiser")
      startLegacyAdvertising(hashPayload)
    }
  }

  @SuppressLint("MissingPermission")
  private fun startLegacyAdvertising(hashPayload: ByteArray) {
    val settings = AdvertiseSettings.Builder()
      .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
      .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
      .setConnectable(true)
      .build()
    Log.i(
      TAG,
      "[ADV] Starting legacy Advertiser API sdk=${Build.VERSION.SDK_INT} " +
        "connectable=true settings=$settings",
    )
    advertiseSettings = settings
    advertiseCallback = object : AdvertiseCallback() {
      override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
        Log.d(TAG, "[ADV] Legacy advertiser started successfully")
      }
      override fun onStartFailure(errorCode: Int) {
        Log.e(TAG, "[ADV] Legacy advertiser failed: $errorCode")
      }
    }
    try {
      advertiser?.startAdvertising(settings, buildPrimaryAd(hashPayload), buildScanResponseData(hashPayload, currentNodeIdPrefix), advertiseCallback)
    } catch (e: android.os.DeadObjectException) {
      Log.w(TAG, "[ADV] DeadObjectException on startAdvertising — re-acquiring advertiser and retrying")
      val bm = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
      advertiser = bm?.adapter?.bluetoothLeAdvertiser
      try {
        advertiser?.startAdvertising(
          settings,
          buildPrimaryAd(hashPayload),
          buildScanResponseData(hashPayload, currentNodeIdPrefix),
          advertiseCallback,
        )
      } catch (e2: Throwable) {
        Log.e(TAG, "[ADV] Retry also failed: ${e2.message}")
      }
    } catch (e: Throwable) {
      Log.e(TAG, "[ADV] startAdvertising threw: ${e.message}")
    }
  }

  @SuppressLint("MissingPermission")
  private fun sendPayloadToPeer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    if (isResettingServer) {
      result.error("server_resetting", "GATT service is being reset", null)
      return
    }
    val macAddress = call.argument<String>("macAddress")
    val isRandom = call.argument<Boolean>("isRandom") ?: false
    val bypassDeadCache = call.argument<Boolean>("bypassDeadCache") ?: false
    val benchmarkMessageIds = (call.argument<List<*>>("benchmarkMessageIds") ?: emptyList<Any?>())
      .mapNotNull { it as? String }
    if (macAddress.isNullOrBlank()) {
      result.error("bad_args", "macAddress is required", null)
      return
    }

    val payload = coercePayloadBytes(call.argument<Any?>("payload"))
    if (payload == null) {
      result.error("bad_args", "payload must be a ByteArray/Uint8List", null)
      return
    }

    val requestCancelGeneration = outboundCancelGeneration.get()
    gattExecutor.submit {
      if (isResettingServer) {
        Handler(Looper.getMainLooper()).post {
          result.error("server_resetting", "GATT service is being reset", null)
        }
        return@submit
      }
      val attemptId = UUID.randomUUID().toString().take(8)
      val attemptStartedAtMs = SystemClock.elapsedRealtime()
      traceBle(
        "CLIENT_ATTEMPT_STARTED",
        macAddress,
        attemptId,
        mapOf(
          "PAYLOAD_BYTES" to payload.size,
          "BYPASS_CACHE" to bypassDeadCache,
          "BENCH_MESSAGE_IDS" to benchmarkMessageIds.joinToString(","),
        ),
      )
      val deadUntil = deadMacs[macAddress]
      if (!bypassDeadCache && deadUntil != null && SystemClock.elapsedRealtime() < deadUntil) {
        traceBle(
          "CLIENT_ATTEMPT_SKIPPED",
          macAddress,
          attemptId,
          mapOf("REASON" to "dead_cache"),
        )
        Handler(Looper.getMainLooper()).post { result.error("timeout", "MAC $macAddress is in dead-cache", null) }
        return@submit
      }
      when (writeOnHeldClient(macAddress, payload, result, attemptId)) {
        HeldLinkWriteResult.COMPLETED -> return@submit
        HeldLinkWriteResult.FAILED -> {
          // This MAC belongs to the failed held link and may be a rotated RPA.
          // Let Flutter refresh it from the scan stream before starting another
          // GATT attempt; retrying the same address here creates a long timeout.
          traceBle(
            "CLIENT_HELD_LINK_RETRY_WITH_FRESH_ADDRESS",
            macAddress,
            attemptId,
            mapOf("REASON" to "held_link_failed"),
          )
          Handler(Looper.getMainLooper()).post {
            result.error(
              "held_link_stale",
              "Held GATT link failed; retry with a fresh scan address",
              null,
            )
          }
          return@submit
        }
        HeldLinkWriteResult.NOT_AVAILABLE -> Unit
      }
      if (bypassDeadCache) {
        deadMacs.remove(macAddress)
        failureCounts.remove(macAddress)
      }

      val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
      val adapter: BluetoothAdapter = bluetoothManager.adapter
      // On Android 12+ (API 31), we MUST specify ADDRESS_TYPE_RANDOM for all BLE peers.
      // Android randomizes MAC addresses for privacy by default (Resolvable Private Addresses).
      // Always use ADDRESS_TYPE_RANDOM if the scanner reports it.
      val addressType = if (isRandom) BluetoothDevice.ADDRESS_TYPE_RANDOM else BluetoothDevice.ADDRESS_TYPE_PUBLIC
      val device = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
        Log.d(TAG, "getRemoteLeDevice mac=$macAddress using type=$addressType (API 31+)")
        adapter.getRemoteLeDevice(macAddress, addressType)
      } else {
        @Suppress("DEPRECATION")
        adapter.getRemoteDevice(macAddress)
      }

      val isCompleted = AtomicBoolean(false)
      val taskLatch = CountDownLatch(1)

      val lock = Object()
      var lastWriteOk: Boolean? = null
      var pendingWriteBytes = 0
      var pendingWriteOffset = 0
      var phase: String = "connecting"
      var gatt: BluetoothGatt? = null

      fun completeSuccessOnMain() {
        if (isCompleted.compareAndSet(false, true)) {
          traceBle(
            "CLIENT_ATTEMPT_COMPLETE",
            macAddress,
            attemptId,
            mapOf("DURATION_MS" to SystemClock.elapsedRealtime() - attemptStartedAtMs),
          )
          Handler(Looper.getMainLooper()).post { result.success(null) }
          taskLatch.countDown()
        }
      }

      fun completeErrorOnMain(code: String, message: String) {
        if (isCompleted.compareAndSet(false, true)) {
          traceBle(
            "CLIENT_ATTEMPT_FAILED",
            macAddress,
            attemptId,
            mapOf(
              "PHASE" to phase,
              "ERROR_CODE" to code,
              "DURATION_MS" to SystemClock.elapsedRealtime() - attemptStartedAtMs,
            ),
          )
          isOutboundClientBusy.set(false)
          try { gatt?.disconnect() } catch (_: Throwable) {}
          try { gatt?.close() } catch (_: Throwable) {}
          Handler(Looper.getMainLooper()).post { result.error(code, message, null) }
          taskLatch.countDown()
        }
      }

      fun finishNotifyReceipt(
        receivedGatt: BluetoothGatt,
        receiptAttemptId: String,
        acknowledgementAccepted: Boolean,
      ) {
        isOutboundClientBusy.set(false)
        if (heldClientGatt === receivedGatt) {
          heldNotifyResult = acknowledgementAccepted
        }
        traceBle(
          if (acknowledgementAccepted) "CLIENT_DELTA_RECEIPT_CONFIRMED"
          else "CLIENT_DELTA_ACK_WRITE_FAILED",
          macAddress,
          receiptAttemptId,
        )
        if (acknowledgementAccepted) {
          if (heldClientGatt === receivedGatt && heldClientLeaseStartedAtMs > 0L) {
            val now = System.currentTimeMillis()
            val previousLeaseAgeMs = now - heldClientLeaseStartedAtMs
            heldClientLeaseStartedAtMs = now
            traceBle(
              "CLIENT_HELD_LINK_LEASE_REFRESHED",
              macAddress,
              receiptAttemptId,
              mapOf(
                "PREVIOUS_LEASE_AGE_MS" to previousLeaseAgeMs,
                "MAX_LEASE_MS" to heldClientMaxLeaseMs,
                "REASON" to "completed_transfer",
              ),
            )
          }
          heldClientGatt = receivedGatt
          heldWriteChar = receivedGatt.getService(SERVICE_UUID)?.getCharacteristic(CHARACTERISTIC_UUID)
            ?: heldWriteChar
          heldClientTraceAttemptId = receiptAttemptId
          scheduleHeldClientRelease(receivedGatt)
        } else if (heldClientGatt === receivedGatt) {
          // The reply ACK failed on the same GATT link that may still be
          // waiting for its final outbound write callback. That link is no
          // longer usable for this round-trip, so release the held writer now
          // instead of making it wait out heldWriteCallbackTimeoutMs.
          synchronized(clientIoLock) {
            if (clientIoOk == null) clientIoOk = false
            clientIoLock.notifyAll()
          }
          emitHeldLinkState(
            "held_link_unavailable",
            try { receivedGatt.device.address } catch (_: Throwable) { null },
          )
          heldClientGatt = null
          heldWriteChar = null
          heldClientTraceAttemptId = null
          heldClientLeaseStartedAtMs = 0L
          heldClientReleaseReason = null
          heldClientHandler.removeCallbacks(heldClientRelease)
        }
        val notifyLatch = heldNotifyLatch
        heldNotifyLatch = null
        notifyLatch?.countDown()
        if (acknowledgementAccepted == false) {
          completeErrorOnMain(
            "reply_ack_failed",
            "Server reply acknowledgement was not accepted",
          )
          try { receivedGatt.disconnect() } catch (_: Throwable) {}
          try { receivedGatt.close() } catch (_: Throwable) {}
        } else {
          completeSuccessOnMain()
        }
      }

      // Track the MTU negotiated by the OS. Android doesn't guarantee 512;
      // the peer may negotiate down to 256 or stay at the 23-byte default.
      // We subtract 3 for the ATT protocol header (opcode + handle = 3 bytes).
      var negotiatedChunkSize: Int = 20 // safe conservative default (23 - 3)

      val connectionWatchdog = Runnable {
        if (isCompleted.compareAndSet(false, true)) {
          isOutboundClientBusy.set(false)
          val count = failureCounts.getOrDefault(macAddress, 0) + 1
          failureCounts[macAddress] = count
          val timeoutMs = Math.min(500 * Math.pow(2.0, count.toDouble()).toLong(), 2000L)
          deadMacs[macAddress] = SystemClock.elapsedRealtime() + timeoutMs
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:timeout")
          traceBle(
            "CLIENT_ATTEMPT_FAILED",
            macAddress,
            attemptId,
            mapOf(
              "PHASE" to phase,
              "ERROR_CODE" to "connect_timeout",
              "DURATION_MS" to SystemClock.elapsedRealtime() - attemptStartedAtMs,
              "PENALTY_MS" to timeoutMs,
            ),
          )
          try { gatt?.disconnect() } catch (_: Throwable) {}
          try { gatt?.close() } catch (_: Throwable) {}
          Handler(Looper.getMainLooper()).post { result.error("timeout", "Timed out waiting for connection", null) }
          taskLatch.countDown()
        }
      }
      val transferWatchdog = Runnable {
        isOutboundClientBusy.set(false)
        Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:transfer_timeout")
        traceBle(
          "CLIENT_ATTEMPT_FAILED",
          macAddress,
          attemptId,
          mapOf(
            "PHASE" to phase,
            "ERROR_CODE" to "transfer_timeout",
            "DURATION_MS" to SystemClock.elapsedRealtime() - attemptStartedAtMs,
          ),
        )
        try { gatt?.disconnect() } catch (_: Throwable) {}
        try { gatt?.close() } catch (_: Throwable) {}
        if (isCompleted.compareAndSet(false, true)) {
          Handler(Looper.getMainLooper()).post { result.error("timeout", "Timed out waiting for writing", null) }
          taskLatch.countDown()
        }
      }
      val mainHandler = Handler(Looper.getMainLooper())
      var mtuRequestStartedAtMs = 0L
      val mtuStageAdvanced = AtomicBoolean(false)
      var mtuFallbackRunnable: Runnable? = null

      fun queueServiceDiscovery(g: BluetoothGatt) {
        phase = "discover_services"
        mainHandler.postDelayed({
          if (!isCompleted.get()) {
            try {
              val started = g.discoverServices()
              traceBle(
                "CLIENT_DISCOVERY_STARTED",
                macAddress,
                attemptId,
                mapOf("STARTED" to started),
              )
            } catch (e: Exception) {
              completeErrorOnMain("SERVICES_EXCEPTION", "Failed to initiate discoverServices")
            }
          }
        }, 50)
      }

      fun recordDefaultMtuFallback(g: BluetoothGatt, reason: String, status: Int? = null) {
        negotiatedChunkSize = 20
        val fields = mutableMapOf<String, Any>(
          "REASON" to reason,
          "WAIT_MS" to if (mtuRequestStartedAtMs == 0L) 0L else SystemClock.elapsedRealtime() - mtuRequestStartedAtMs,
          "CHUNK_SIZE" to negotiatedChunkSize,
        )
        if (status != null) fields["STATUS"] = status
        traceBle("CLIENT_MTU_FALLBACK", macAddress, attemptId, fields)
        Log.w(TAG, "[GATT] Continuing with default MTU chunk size 20 mac=$macAddress reason=$reason")
        queueServiceDiscovery(g)
      }

      fun fallbackToDefaultMtu(g: BluetoothGatt, reason: String, status: Int? = null) {
        if (!mtuStageAdvanced.compareAndSet(false, true)) return
        mtuFallbackRunnable?.let { mainHandler.removeCallbacks(it) }
        recordDefaultMtuFallback(g, reason, status)
      }

      // Start the watchdog when connectGatt is issued, so the short radio-settle
      // delay does not consume the peer's connection budget.

      try {
        val gattCallback = object : BluetoothGattCallback() {
          override fun onConnectionStateChange(g: BluetoothGatt?, status: Int, newState: Int) {
            super.onConnectionStateChange(g, status, newState)
            if (g == null) return

            if (newState == BluetoothProfile.STATE_CONNECTED) {
              isOutboundClientBusy.set(true)
              Log.d(TAG, "[GATT] STATE_CONNECTED mac=$macAddress")
              Log.d(TAG, "[BENCHMARK] TARGET_MAC:$macAddress | EVENT:GATT_CONNECTED | TIMESTAMP:${System.currentTimeMillis()}")
              traceBle(
                "CLIENT_CONNECTED",
                macAddress,
                attemptId,
                mapOf("CONNECT_MS" to SystemClock.elapsedRealtime() - attemptStartedAtMs),
              )
              // Request a low-latency interval while this held client link is
              // carrying chunked transfers. Release restores balanced priority.
              requestClientConnectionPriority(
                g,
                BluetoothGatt.CONNECTION_PRIORITY_HIGH,
                "connected_for_transfer",
                attemptId,
              )
              mainHandler.removeCallbacks(connectionWatchdog)
              // Offer round-trips should finish in a few seconds. A 60s transfer
              // watchdog left urgent push-on-write blocked behind a dead peer.
              mainHandler.postDelayed(transferWatchdog, 15000)
              // Negotiate a larger MTU before discovery when Android supports it.
              // Some debug builds accept requestMtu() but omit onMtuChanged; the
              // bounded fallback keeps discovery moving at the 20-byte default.
              phase = "request_mtu"
              mainHandler.postDelayed({
                if (!isCompleted.get()) {
                  try {
                    mtuRequestStartedAtMs = SystemClock.elapsedRealtime()
                    val ok = g.requestMtu(512)
                    Log.d(TAG, "[GATT] requestMtu initiated: $ok mac=$macAddress")
                    traceBle(
                      "CLIENT_MTU_REQUESTED",
                      macAddress,
                      attemptId,
                      mapOf("REQUESTED_MTU" to 512, "STARTED" to ok),
                    )
                    if (ok) {
                      val fallback = Runnable {
                        if (!isCompleted.get()) {
                          fallbackToDefaultMtu(g, "callback_timeout")
                        }
                      }
                      mtuFallbackRunnable = fallback
                      mainHandler.postDelayed(fallback, 1500L)
                    } else {
                      fallbackToDefaultMtu(g, "request_not_started")
                    }
                  } catch (e: Exception) {
                    Log.w(TAG, "[GATT] requestMtu exception; continuing at default MTU mac=$macAddress", e)
                    fallbackToDefaultMtu(g, "request_exception")
                  }
                }
              }, 50)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
              pendingClientReplyFeedbackWrites.remove(g)?.let { pending ->
                pending.status = BluetoothGatt.GATT_FAILURE
                pending.latch.countDown()
              }
              incomingReplyTransfers.entries
                .filter { it.value.gatt === g }
                .forEach { incomingReplyTransfers.remove(it.key, it.value) }
              if (heldClientGatt === g) {
                synchronized(clientIoLock) {
                  if (clientIoOk == null) clientIoOk = false
                  clientIoLock.notifyAll()
                }
              }
              Log.d(TAG, "[GATT] STATE_DISCONNECTED phase=$phase status=$status mac=$macAddress")
              traceBle(
                "CLIENT_DISCONNECTED",
                macAddress,
                attemptId,
                mapOf("STATUS" to status, "PHASE" to phase),
              )
              isOutboundClientBusy.set(false) // Always release the mutex on disconnect.
              if (!isCompleted.get()) {
                val count = failureCounts.getOrDefault(macAddress, 0) + 1
                failureCounts[macAddress] = count
                val timeoutMs = Math.min(500 * Math.pow(2.0, count.toDouble()).toLong(), 2000L)
                deadMacs[macAddress] = SystemClock.elapsedRealtime() + timeoutMs
                Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
                Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:$status")
                try { g.close() } catch (_: Throwable) {}
                completeErrorOnMain("DISCONNECTED", "Disconnected during phase=$phase status=$status")
              } else {
                // Already completed after receiving and validating the framed reply.
                try { g.close() } catch (_: Throwable) {}
                if (heldClientGatt === g) {
                  emitHeldLinkState(
                    "held_link_unavailable",
                    try { g.device.address } catch (_: Throwable) { null },
                  )
                  heldClientGatt = null
                  heldClientTraceAttemptId = null
                }
              }
            }
          }

          override fun onMtuChanged(g: BluetoothGatt?, mtu: Int, status: Int) {
            super.onMtuChanged(g, mtu, status)
            Log.d(TAG, "[GATT] onMtuChanged mtu=$mtu status=$status mac=$macAddress")
            if (g == null) return
            if (!mtuStageAdvanced.compareAndSet(false, true)) {
              traceBle(
                "CLIENT_MTU_CALLBACK_LATE",
                macAddress,
                attemptId,
                mapOf("MTU" to mtu, "STATUS" to status),
              )
              return
            }
            mtuFallbackRunnable?.let { mainHandler.removeCallbacks(it) }
            if (status == BluetoothGatt.GATT_SUCCESS) {
              // Subtract 3 bytes for the ATT protocol header (1 opcode + 2 handle).
              // Also clamp to 512: Android's GATT stack hard-caps attribute writes at 512 bytes
              // regardless of the negotiated MTU. Some devices report mtu=517 (L2CAP frame size)
              // which would cause writeCharacteristic to throw if we naively use mtu-3=514.
              negotiatedChunkSize = (mtu - 3).coerceIn(20, 512)
              traceBle(
                "CLIENT_MTU_READY",
                macAddress,
                attemptId,
                mapOf("MTU" to mtu, "CHUNK_SIZE" to negotiatedChunkSize, "STATUS" to status),
              )
              Log.d(TAG, "[GATT] Effective chunk size: $negotiatedChunkSize bytes mac=$macAddress")
              queueServiceDiscovery(g)
            } else {
              traceBle(
                "CLIENT_MTU_FAILED",
                macAddress,
                attemptId,
                mapOf("MTU" to mtu, "STATUS" to status),
              )
              recordDefaultMtuFallback(g, "callback_failed", status)
            }
          }

          override fun onServicesDiscovered(g: BluetoothGatt?, status: Int) {
            super.onServicesDiscovered(g, status)
            Log.d(TAG, "[GATT] onServicesDiscovered status=$status mac=$macAddress")
            if (g == null) return

            if (status == BluetoothGatt.GATT_SUCCESS) {
              phase = "services_discovered"
              traceBle(
                "CLIENT_SERVICES_READY",
                macAddress,
                attemptId,
                mapOf("STATUS" to status),
              )
              val service = g.getService(SERVICE_UUID)
              val characteristic = service?.getCharacteristic(CHARACTERISTIC_UUID)

              if (characteristic != null) {
                Thread {
                  try {
                    phase = "subscribe_notify"
                    val notifyChar = service.getCharacteristic(NOTIFY_CHARACTERISTIC_UUID)
                    if (notifyChar == null) {
                      completeErrorOnMain("NOTIFY_CHAR_NOT_FOUND", "Notify characteristic not found")
                      return@Thread
                    }
                    val localNotifyEnabled = g.setCharacteristicNotification(notifyChar, true)
                    val descriptor = notifyChar.getDescriptor(CCCD_UUID)
                    if (descriptor == null) {
                      completeErrorOnMain("CCCD_NOT_FOUND", "Notify CCCD not found")
                      return@Thread
                    }
                    if (!localNotifyEnabled) {
                      completeErrorOnMain("NOTIFY_ENABLE_FAILED", "Failed to enable local notifications")
                      return@Thread
                    }
                    // V2 uses notifications for chunks and an indication for
                    // the final frame, so enable both CCCD modes on every peer.
                    val cccdValue = byteArrayOf(0x03, 0x00)
                    traceBle(
                      "CLIENT_REPLY_CCCD_CONFIG",
                      macAddress,
                      attemptId,
                      mapOf("NOTIFICATIONS_ENABLED" to true, "INDICATIONS_ENABLED" to true),
                    )
                    synchronized(lock) { lastWriteOk = null }
                    val started = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                      g.writeDescriptor(descriptor, cccdValue) == BluetoothGatt.GATT_SUCCESS
                    } else {
                      @Suppress("DEPRECATION")
                      descriptor.value = cccdValue
                      @Suppress("DEPRECATION")
                      g.writeDescriptor(descriptor)
                    }
                    traceBle(
                      "CLIENT_CCCD_WRITE_STARTED",
                      macAddress,
                      attemptId,
                      mapOf("STARTED" to started),
                    )
                    if (!started) {
                      completeErrorOnMain("CCCD_START_FAILED", "Failed to start CCCD write")
                      return@Thread
                    }
                    val deadlineMs = SystemClock.elapsedRealtime() + 8000L
                    synchronized(lock) {
                      while (lastWriteOk == null && SystemClock.elapsedRealtime() < deadlineMs) {
                        lock.wait(250L)
                      }
                    }
                    val subscriptionResult = synchronized(lock) { lastWriteOk }
                    val subscriptionReady = subscriptionResult == true
                    traceBle(
                      if (subscriptionReady) "CLIENT_CCCD_READY" else "CLIENT_CCCD_FAILED",
                      macAddress,
                      attemptId,
                      mapOf(
                        "RESULT" to subscriptionResult,
                        "WAIT_MS" to (8000L - (deadlineMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L)),
                      ),
                    )
                    Log.d(TAG, "[GATT] Subscribed to NOTIFY mac=$macAddress result=$subscriptionResult")
                    if (!subscriptionReady) {
                      completeErrorOnMain("CCCD_FAILED", "CCCD write did not complete successfully")
                      return@Thread
                    }

                    phase = "writing"
                    heldWriteChar = characteristic
                    heldChunkSize = negotiatedChunkSize
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    var offset = 0

                    fun writeBlocking(bytes: ByteArray): Boolean {
                      synchronized(lock) {
                        lastWriteOk = null
                        pendingWriteBytes = bytes.size
                        pendingWriteOffset = offset
                      }
                      traceBle(
                        "CLIENT_WRITE_STARTED",
                        macAddress,
                        attemptId,
                        mapOf("BYTES" to bytes.size, "OFFSET" to offset),
                      )

                      val started: Boolean = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                        val rc = g.writeCharacteristic(characteristic, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                        rc == BluetoothGatt.GATT_SUCCESS
                      } else {
                        @Suppress("DEPRECATION")
                        characteristic.value = bytes
                        @Suppress("DEPRECATION")
                        g.writeCharacteristic(characteristic)
                      }

                      if (!started) return false

                      val deadlineMs = SystemClock.elapsedRealtime() + 8000L
                      synchronized(lock) {
                        while (lastWriteOk == null && SystemClock.elapsedRealtime() < deadlineMs) {
                          lock.wait(250L)
                        }
                        return lastWriteOk == true
                      }
                    }

                    // Use the MTU negotiated with this specific peer, not a hardcoded constant.
                    // Android is not guaranteed to grant 512; it may stay at 23 bytes (default) on some devices.
                    Log.d(TAG, "[GATT] Starting chunked write: ${payload.size} bytes in chunks of $negotiatedChunkSize mac=$macAddress")
                    clientGattWriteLock.lock()
                    try {
                      while (offset < payload.size) {
                        val length = minOf(negotiatedChunkSize, payload.size - offset)
                        val chunk = ByteArray(length)
                        System.arraycopy(payload, offset, chunk, 0, length)
                        val ok = writeBlocking(chunk)
                        if (!ok) {
                          try { g.disconnect() } catch (_: Throwable) {}
                          try { g.close() } catch (_: Throwable) {}
                          completeErrorOnMain("WRITE_FAILED", "Write chunk failed at offset=$offset len=$length")
                          return@Thread
                        }
                        offset += length
                      }

                      val eof = "||EOF||".toByteArray()
                      val eofOk = writeBlocking(eof)
                      if (!eofOk) {
                        try { g.disconnect() } catch (_: Throwable) {}
                        try { g.close() } catch (_: Throwable) {}
                        completeErrorOnMain("WRITE_FAILED", "Write EOF failed")
                        return@Thread
                      }

                      // DO NOT disconnect here. Keep the connection alive so the Server can
                      // push the Delta reply back via NOTIFY. Do NOT completeSuccess yet —
                      // releasing the Flutter future early lets Dart start another dial while
                      // isOutboundClientBusy is still held → gatt_busy storms (Red3 lag).
                      // Success is signaled after the peer validates and acknowledges its reply.
                      Log.d(TAG, "[GATT] Offer sent. Waiting for notify Delta reply mac=$macAddress")
                      traceBle(
                        "CLIENT_OFFER_EOF_SENT",
                        macAddress,
                        attemptId,
                        mapOf("PAYLOAD_BYTES" to payload.size, "CHUNK_SIZE" to negotiatedChunkSize),
                      )
                      failureCounts.remove(macAddress)
                    } finally {
                      clientGattWriteLock.unlock()
                    }
                  } catch (t: Throwable) {
                    try { g.disconnect() } catch (_: Throwable) {}
                    try { g.close() } catch (_: Throwable) {}
                    completeErrorOnMain("SEND_EXCEPTION", t.message ?: "send exception")
                  }
                }.start()
              } else {
                traceBle("CLIENT_CHARACTERISTIC_MISSING", macAddress, attemptId)
                g.disconnect()
                g.close()
                val discovered = try {
                  g.services?.joinToString(separator = ";") { s ->
                    val chars = s.characteristics?.joinToString(separator = ",") { c -> c.uuid.toString() } ?: ""
                    "${s.uuid}[$chars]"
                  } ?: "<no-services>"
                } catch (_: Throwable) {
                  "<services-enum-failed>"
                }
                completeErrorOnMain(
                  "CHAR_NOT_FOUND",
                  "Mesh characteristic not found. discovered=$discovered"
                )
              }
            } else {
              val count = failureCounts.getOrDefault(macAddress, 0) + 1
              failureCounts[macAddress] = count
              val timeoutMs = Math.min(500 * Math.pow(2.0, count.toDouble()).toLong(), 2000L)
              deadMacs[macAddress] = SystemClock.elapsedRealtime() + timeoutMs
              Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
              Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:discovery_failed_$status")
              g.disconnect()
              g.close()
              completeErrorOnMain("DISCOVERY_FAILED", "Failed to discover services")
            }
          }

          override fun onDescriptorWrite(
            g: BluetoothGatt?,
            descriptor: BluetoothGattDescriptor?,
            status: Int
          ) {
            super.onDescriptorWrite(g, descriptor, status)
            Log.d(TAG, "[GATT] onDescriptorWrite status=$status mac=$macAddress")
            traceBle(
              "CLIENT_CCCD_WRITE_RESULT",
              macAddress,
              attemptId,
              mapOf("STATUS" to status, "SUCCESS" to (status == BluetoothGatt.GATT_SUCCESS)),
            )
            synchronized(lock) {
              lastWriteOk = status == BluetoothGatt.GATT_SUCCESS
              lock.notifyAll()
            }
          }

          override fun onCharacteristicWrite(
            g: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
          ) {
            super.onCharacteristicWrite(g, characteristic, status)
            Log.d(TAG, "[GATT] onCharacteristicWrite status=$status mac=$macAddress")
            if (g != null) {
              val feedbackWrite = pendingClientReplyFeedbackWrites[g]
              if (feedbackWrite != null) {
                feedbackWrite.status = status
                feedbackWrite.latch.countDown()
                return
              }
            }
            val writeContext = synchronized(lock) {
              lastWriteOk = status == BluetoothGatt.GATT_SUCCESS
              lock.notifyAll()
              pendingWriteBytes to pendingWriteOffset
            }
            if (heldClientGatt !== g) {
              traceBle(
                "CLIENT_WRITE_RESULT",
                macAddress,
                attemptId,
                mapOf(
                  "STATUS" to status,
                  "SUCCESS" to (status == BluetoothGatt.GATT_SUCCESS),
                  "BYTES" to writeContext.first,
                  "OFFSET" to writeContext.second,
                ),
              )
            }
            synchronized(clientIoLock) {
              clientIoOk = status == BluetoothGatt.GATT_SUCCESS
              clientIoLock.notifyAll()
            }
          }

          // API 33+ (Tiramisu) — preferred override
          override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
          ) {
            handleNotifyChunk(g, characteristic.uuid, value)
          }

          // Pre-API 33 fallback
          @Suppress("DEPRECATION")
          override fun onCharacteristicChanged(
            g: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?
          ) {
            if (g == null || characteristic == null) return
            val value = characteristic.value ?: return
            handleNotifyChunk(g, characteristic.uuid, value)
          }

          private fun handleNotifyChunk(g: BluetoothGatt, charUuid: UUID, value: ByteArray) {
            if (charUuid != NOTIFY_CHARACTERISTIC_UUID) return
            Log.d(TAG, "[GATT-NOTIFY] Received frame ${value.size} bytes from server mac=$macAddress")
            val traceAttemptId = if (heldClientGatt === g) {
              heldClientTraceAttemptId ?: attemptId
            } else {
              attemptId
            }
            val frameType = value.firstOrNull()?.toInt()?.and(0xFF)
            when (frameType) {
              replyStartFrameType, replyEndFrameType -> {
                if (value.size != 15) {
                  traceBle(
                    if (frameType == replyStartFrameType) "CLIENT_REPLY_START_FRAME_INVALID"
                    else "CLIENT_REPLY_END_FRAME_INVALID",
                    macAddress,
                    traceAttemptId,
                    mapOf("BYTES" to value.size),
                  )
                  return
                }
                val transferId = readFrameInt(value, 1)
                val chunkCount = readFrameU16(value, 5)
                val totalBytes = readFrameInt(value, 7)
                val crc32 = readFrameInt(value, 11)
                if (transferId <= 0 || totalBytes < 0) {
                  traceBle(
                    if (frameType == replyStartFrameType) "CLIENT_REPLY_START_FRAME_INVALID"
                    else "CLIENT_REPLY_END_FRAME_INVALID",
                    macAddress,
                    traceAttemptId,
                    mapOf("TRANSFER_ID" to transferId, "TOTAL_BYTES" to totalBytes),
                  )
                  return
                }

                if (frameType == replyStartFrameType) {
                  traceBle(
                    "CLIENT_REPLY_START_RECEIVED",
                    macAddress,
                    traceAttemptId,
                    mapOf(
                      "TRANSFER_ID" to transferId,
                      "CHUNK_COUNT" to chunkCount,
                      "TOTAL_BYTES" to totalBytes,
                      "CRC32" to (crc32.toLong() and 0xFFFFFFFFL),
                    ),
                  )
                  Handler(Looper.getMainLooper()).post {
                    eventSink?.success(
                      hashMapOf(
                        "event" to "reply_start",
                        "mac" to macAddress,
                        "transferId" to transferId,
                        "chunkCount" to chunkCount,
                        "totalBytes" to totalBytes,
                        "crc32" to (crc32.toLong() and 0xFFFFFFFFL),
                        "attemptId" to traceAttemptId,
                      ),
                    )
                  }
                  return
                }

                val transfer = IncomingReplyTransfer(
                  macAddress = macAddress,
                  transferId = transferId,
                  gatt = g,
                  attemptId = traceAttemptId,
                  completeReceipt = { accepted ->
                    finishNotifyReceipt(g, traceAttemptId, accepted)
                  },
                )
                incomingReplyTransfers[framedReplyKey(macAddress, transferId)] = transfer
                traceBle(
                  "CLIENT_REPLY_END_RECEIVED",
                  macAddress,
                  traceAttemptId,
                  mapOf(
                    "TRANSFER_ID" to transferId,
                    "CHUNK_COUNT" to chunkCount,
                    "TOTAL_BYTES" to totalBytes,
                    "CRC32" to (crc32.toLong() and 0xFFFFFFFFL),
                    "INDICATION" to true,
                  ),
                )
                Handler(Looper.getMainLooper()).post {
                  eventSink?.success(
                    hashMapOf(
                      "event" to "reply_end",
                      "mac" to macAddress,
                      "transferId" to transferId,
                      "chunkCount" to chunkCount,
                      "totalBytes" to totalBytes,
                      "crc32" to (crc32.toLong() and 0xFFFFFFFFL),
                      "attemptId" to traceAttemptId,
                    ),
                  )
                }
                return
              }
              replyDataFrameType -> {
                if (value.size <= replyDataFrameHeaderBytes) {
                  traceBle(
                    "CLIENT_REPLY_CHUNK_FRAME_INVALID",
                    macAddress,
                    traceAttemptId,
                    mapOf("BYTES" to value.size),
                  )
                  return
                }
                val chunkIndex = readFrameU16(value, 1)
                val bytes = value.copyOfRange(replyDataFrameHeaderBytes, value.size)
                traceBle(
                  "CLIENT_REPLY_CHUNK_RECEIVED",
                  macAddress,
                  traceAttemptId,
                  mapOf("CHUNK_INDEX" to chunkIndex, "BYTES" to bytes.size),
                )
                Handler(Looper.getMainLooper()).post {
                  eventSink?.success(
                    hashMapOf(
                      "event" to "reply_data",
                      "mac" to macAddress,
                      "chunkIndex" to chunkIndex,
                      "bytes" to bytes,
                      "attemptId" to traceAttemptId,
                    ),
                  )
                }
              }
              else -> {
                traceBle(
                  "CLIENT_REPLY_FRAME_INVALID",
                  macAddress,
                  traceAttemptId,
                  mapOf("BYTES" to value.size, "FRAME_TYPE" to frameType),
                )
              }
            }
          }
        }

        // Connection collision guard: only one outbound GATT attempt at a time.
        if (!isOutboundClientBusy.compareAndSet(false, true)) {
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_SKIPPED | REASON:gatt_busy")
          traceBle("CLIENT_ATTEMPT_SKIPPED", macAddress, attemptId, mapOf("REASON" to "gatt_busy"))
          Handler(Looper.getMainLooper()).post { result.error("gatt_busy", "GATT is currently busy, retry on next scan cycle", null) }
          return@submit
        }

        // Prefer a short settle delay; long jitter was stacking with the connect
        // watchdog and making live catch-up miss the few-second budget.
        val jitterMs = (50..250).random().toLong()
        Handler(Looper.getMainLooper()).postDelayed({
          if (
            isCompleted.get() ||
            outboundCancelGeneration.get() != requestCancelGeneration ||
            isResettingServer
          ) {
            isOutboundClientBusy.set(false)
            if (!isCompleted.get()) {
              completeErrorOnMain("cancelled", "Outbound cancelled or GATT service resetting")
            }
            return@postDelayed
          }
          if (connectedServerClients[macAddress] == true) {
            isOutboundClientBusy.set(false)
            completeErrorOnMain("already_connected", "Already connected as Server to this MAC")
            return@postDelayed
          }
          releaseHeldClientNow("new_outbound_attempt")
          // Keep the fast path unchanged for peers that connect promptly while
          // giving slower/farther links enough time to finish the LE handshake.
          val connectTimeoutMs = if (bypassDeadCache) 3500L else 5000L
          mainHandler.postDelayed(connectionWatchdog, connectTimeoutMs)
          traceBle(
            "CLIENT_CONNECT_STARTED",
            macAddress,
            attemptId,
            mapOf(
              "TIMEOUT_MS" to connectTimeoutMs,
              "ADDRESS_TYPE" to addressType,
            ),
          )
          gatt = device.connectGatt(
            this@MainActivity,
            false,
            gattCallback,
            BluetoothDevice.TRANSPORT_LE,
          )
          currentOutboundGatt = gatt
          if (gatt == null) {
            mainHandler.removeCallbacks(connectionWatchdog)
            isOutboundClientBusy.set(false)
            traceBle("CLIENT_CONNECT_REJECTED", macAddress, attemptId, mapOf("REASON" to "null_gatt"))
            completeErrorOnMain("connect_failed", "connectGatt returned null")
          }
        }, jitterMs)

        // Block the single-thread queue until this connection attempt finishes (success, fail, or 25s timeout)
        taskLatch.await()
      } catch (e: Exception) {
        isOutboundClientBusy.set(false)
        completeErrorOnMain("queue_exception", e.message ?: "queue exception")
      } finally {
        mainHandler.removeCallbacks(connectionWatchdog)
        mainHandler.removeCallbacks(transferWatchdog)
      }
    }
  }

  // Server-side reply: push a framed Delta payload back over the existing GATT link.
  // This avoids the GATT 257 "role-switching" crash by reusing the existing open connection
  // instead of spinning up a second GAP link.
  @SuppressLint("MissingPermission")
  private fun sendReplyFeedback(
    call: io.flutter.plugin.common.MethodCall,
    result: MethodChannel.Result,
  ) {
    val macAddress = call.argument<String>("macAddress")
      ?: return result.error("no_mac", "macAddress is required", null)
    val transferId = call.argument<Int>("transferId")
      ?: return result.error("no_transfer_id", "transferId is required", null)
    val action = call.argument<String>("action")
      ?: return result.error("no_action", "action is required", null)
    val key = framedReplyKey(macAddress, transferId)
    val transfer = incomingReplyTransfers[key]
      ?: return result.error("reply_transfer_missing", "Reply transfer is no longer active", null)
    val missingIndices = (call.argument<List<*>>("missingIndices") ?: emptyList<Any?>())
      .mapNotNull { (it as? Number)?.toInt() }
    val retryAll = call.argument<Boolean>("retryAll") == true ||
      (missingIndices.isEmpty() && action == "nack") ||
      missingIndices.size > maxReplyMissingIndicesPerFrame
    val feedback = when {
      action == "ack" -> byteArrayOf(replyAckFrameType.toByte()) + ByteArray(4).also {
        writeFrameInt(it, 0, transferId)
      }
      action == "nack" && retryAll -> byteArrayOf(replyMissingAllFrameType.toByte()) + ByteArray(4).also {
        writeFrameInt(it, 0, transferId)
      }
      action == "nack" -> {
        val frame = ByteArray(6 + missingIndices.size * 2)
        frame[0] = replyMissingFrameType.toByte()
        writeFrameInt(frame, 1, transferId)
        frame[5] = missingIndices.size.toByte()
        missingIndices.forEachIndexed { index, chunkIndex ->
          appendFrameU16(frame, 6 + index * 2, chunkIndex)
        }
        frame
      }
      else -> return result.error("invalid_action", "action must be ack or nack", null)
    }

    clientReplyAckExecutor.execute {
      clientGattWriteLock.lock()
      var pendingWrite: PendingClientReplyFeedbackWrite? = null
      try {
        if (incomingReplyTransfers[key] !== transfer) {
          Handler(Looper.getMainLooper()).post {
            result.error("reply_transfer_stale", "Reply transfer changed before feedback", null)
          }
          return@execute
        }
        val gatt = transfer.gatt
        val writeChar = gatt.getService(SERVICE_UUID)?.getCharacteristic(CHARACTERISTIC_UUID)
        if (writeChar == null) {
          Handler(Looper.getMainLooper()).post {
            result.error("write_characteristic_missing", "Reply feedback characteristic is missing", null)
          }
          if (action == "ack") transfer.completeReceipt(false)
          return@execute
        }
        val activeWrite = PendingClientReplyFeedbackWrite(CountDownLatch(1))
        pendingWrite = activeWrite
        if (pendingClientReplyFeedbackWrites.putIfAbsent(gatt, activeWrite) != null) {
          Handler(Looper.getMainLooper()).post {
            result.error("gatt_write_busy", "Another reply feedback write is pending", null)
          }
          if (action == "ack") transfer.completeReceipt(false)
          return@execute
        }
        val started = try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
              writeChar,
              feedback,
              BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            ) == BluetoothGatt.GATT_SUCCESS
          } else {
            @Suppress("DEPRECATION")
            writeChar.value = feedback
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(writeChar)
          }
        } catch (t: Throwable) {
          Log.w(TAG, "[GATT-REPLY] Feedback write threw: ${t.message}")
          false
        }
        if (!started) {
          pendingClientReplyFeedbackWrites.remove(gatt, activeWrite)
          Handler(Looper.getMainLooper()).post {
            result.error("reply_feedback_rejected", "GATT rejected reply feedback", null)
          }
          if (action == "ack") transfer.completeReceipt(false)
          return@execute
        }
        traceBle(
          if (action == "ack") "CLIENT_REPLY_ACK_QUEUED" else "CLIENT_REPLY_NACK_QUEUED",
          macAddress,
          transfer.attemptId,
          mapOf(
            "TRANSFER_ID" to transferId,
            "BYTES" to feedback.size,
            "MISSING_COUNT" to missingIndices.size,
            "RETRY_ALL" to retryAll,
          ),
        )
        val callbackReceived = activeWrite.latch.await(replyAckTimeoutMs, TimeUnit.MILLISECONDS)
        val status = activeWrite.status
        pendingClientReplyFeedbackWrites.remove(gatt, activeWrite)
        if (!callbackReceived || status != BluetoothGatt.GATT_SUCCESS) {
          traceBle(
            "CLIENT_REPLY_FEEDBACK_WRITE_FAILED",
            macAddress,
            transfer.attemptId,
            mapOf("ACTION" to action, "STATUS" to status, "TIMEOUT" to !callbackReceived),
          )
          incomingReplyTransfers.remove(key, transfer)
          transfer.completeReceipt(false)
          Handler(Looper.getMainLooper()).post {
            result.error("reply_feedback_write_failed", "Reply feedback write failed", null)
          }
          return@execute
        }
        traceBle(
          if (action == "ack") "CLIENT_REPLY_ACK_WRITE_CALLBACK" else "CLIENT_REPLY_NACK_WRITE_CALLBACK",
          macAddress,
          transfer.attemptId,
          mapOf("TRANSFER_ID" to transferId, "STATUS" to status),
        )
        if (action == "ack") {
          incomingReplyTransfers.remove(key, transfer)
          transfer.completeReceipt(true)
        }
        Handler(Looper.getMainLooper()).post { result.success(null) }
      } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
        pendingWrite?.let { pendingClientReplyFeedbackWrites.remove(transfer.gatt, it) }
        incomingReplyTransfers.remove(key, transfer)
        transfer.completeReceipt(false)
        Handler(Looper.getMainLooper()).post {
          result.error("reply_feedback_interrupted", "Reply feedback was interrupted", null)
        }
      } catch (t: Throwable) {
        pendingWrite?.let { pendingClientReplyFeedbackWrites.remove(transfer.gatt, it) }
        incomingReplyTransfers.remove(key, transfer)
        transfer.completeReceipt(false)
        Handler(Looper.getMainLooper()).post {
          result.error("reply_feedback_failed", t.message ?: "Reply feedback failed", null)
        }
      } finally {
        clientGattWriteLock.unlock()
      }
    }
  }

  @SuppressLint("MissingPermission")
  private fun replyPayloadToPeer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val macAddress = call.argument<String>("macAddress")
      ?: return result.error("no_mac", "macAddress is required", null)
    val payload = coercePayloadBytes(call.argument<Any?>("payload")) ?: ByteArray(0)
    val benchmarkMessageIds = (call.argument<List<*>>("benchmarkMessageIds") ?: emptyList<Any?>())
      .mapNotNull { it as? String }

    val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    // getRemoteDevice is safe here: we have an active server connection to this address.
    val device = bm.adapter.getRemoteDevice(macAddress)
    val server = bluetoothGattServer ?: return result.error("no_server", "GATT server not started", null)
    val service = server.getService(SERVICE_UUID)
    val notifyChar = service?.getCharacteristic(NOTIFY_CHARACTERISTIC_UUID)
      ?: return result.error("no_char", "NOTIFY characteristic not found in service", null)

    serverReplyExecutor.submit {
      try {
        if (
          connectedServerClients[macAddress] != true ||
          notifyReadyServerClients[macAddress] != true
        ) {
          traceBle("SERVER_REPLY_SKIPPED_LINK_GONE", macAddress)
          Handler(Looper.getMainLooper()).post {
            result.error("peer_disconnected", "GATT server link is no longer ready", null)
          }
          return@submit
        }
        val mtu = serverMtuMap[macAddress] ?: 23
        val chunkSize = (mtu - 3).coerceIn(20, 512)

        fun notifyBlocking(
          chunk: ByteArray,
          offset: Int,
          isEof: Boolean = false,
          confirm: Boolean = false,
        ): Boolean {
          if (
            connectedServerClients[macAddress] != true ||
            notifyReadyServerClients[macAddress] != true
          ) {
            traceBle("SERVER_NOTIFY_ABORTED_LINK_GONE", macAddress, fields = mapOf("OFFSET" to offset))
            return false
          }
          val startedAt = SystemClock.elapsedRealtime()
          synchronized(serverNotifyLock) {
            lastNotifyOk = null
            lastNotifyMac = null
            notifyStartedAtMs = startedAt
          }

          val startStatus: Int
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            startStatus = server.notifyCharacteristicChanged(device, notifyChar, confirm, chunk)
          } else {
            @Suppress("DEPRECATION")
            notifyChar.value = chunk
            @Suppress("DEPRECATION")
            val started = server.notifyCharacteristicChanged(device, notifyChar, confirm)
            startStatus = if (started) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE
          }
          if (startStatus != BluetoothGatt.GATT_SUCCESS) {
            traceBle(
              "SERVER_NOTIFY_REJECTED",
              macAddress,
              connectionId = serverConnectionIds[macAddress],
              fields = mapOf("STATUS" to startStatus, "BYTES" to chunk.size, "OFFSET" to offset, "EOF" to isEof, "INDICATION" to confirm),
            )
            return false
          }
          traceBle(
            "SERVER_NOTIFY_STARTED",
            macAddress,
            connectionId = serverConnectionIds[macAddress],
            fields = mapOf("BYTES" to chunk.size, "OFFSET" to offset, "EOF" to isEof, "INDICATION" to confirm),
          )

          // Android 9 often omits onNotificationSent for unconfirmed NOTIFY.
          // The final indication has an application-level receipt, so pacing
          // each missing notification callback at 400 ms stalls small-MTU replies.
          val callbackFallbackMs =
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) 50L else 400L
          val deadlineMs = startedAt + callbackFallbackMs
          var callbackResult: Boolean? = null
          synchronized(serverNotifyLock) {
            while (
              (lastNotifyOk == null || lastNotifyMac != macAddress) &&
              SystemClock.elapsedRealtime() < deadlineMs
            ) {
              serverNotifyLock.wait(50L)
            }
            if (lastNotifyMac == macAddress) callbackResult = lastNotifyOk
          }
          val waitedMs = SystemClock.elapsedRealtime() - startedAt
          val accepted = callbackResult != false
          traceBle(
            "SERVER_NOTIFY_COMPLETE",
            macAddress,
            connectionId = serverConnectionIds[macAddress],
            fields = mapOf(
              "RESULT" to accepted,
              "CALLBACK" to callbackResult,
              "WAIT_MS" to waitedMs,
              "FALLBACK_TIMEOUT_MS" to callbackFallbackMs,
              "BYTES" to chunk.size,
              "OFFSET" to offset,
              "EOF" to isEof,
              "INDICATION" to confirm,
            ),
          )
          return accepted
        }


        val dataChunkSize = chunkSize - replyDataFrameHeaderBytes
        if (dataChunkSize <= 0) {
          Handler(Looper.getMainLooper()).post {
            result.error("INVALID_MTU", "MTU cannot carry a framed reply chunk", null)
          }
          return@submit
        }
        val chunkCount = if (payload.isEmpty()) 0 else (payload.size + dataChunkSize - 1) / dataChunkSize
        if (chunkCount > 0xFFFF) {
          Handler(Looper.getMainLooper()).post {
            result.error("REPLY_TOO_LARGE", "Reply exceeds framed chunk index capacity", null)
          }
          return@submit
        }
        val transferId = java.util.concurrent.ThreadLocalRandom.current()
          .nextInt(1, Int.MAX_VALUE)
        val pending = PendingFramedServerReply(
          transferId = transferId,
          feedback = java.util.concurrent.LinkedBlockingQueue(),
        )
        if (pendingServerReplyAcks.putIfAbsent(macAddress, pending) != null) {
          traceBle(
            "SERVER_REPLY_ACK_BUSY",
            macAddress,
            connectionId = serverConnectionIds[macAddress],
            fields = mapOf("PROTOCOL" to "framed", "TRANSFER_ID" to transferId),
          )
          Handler(Looper.getMainLooper()).post {
            result.error("NOTIFY_BUSY", "Another framed reply is awaiting receipt from this peer", null)
          }
          return@submit
        }
        try {
          traceBle(
            "SERVER_REPLY_STARTED",
            macAddress,
            connectionId = serverConnectionIds[macAddress],
            fields = mapOf(
              "PROTOCOL" to "framed_v2",
              "TRANSFER_ID" to transferId,
              "BYTES" to payload.size,
              "MTU" to mtu,
              "CHUNK_SIZE" to dataChunkSize,
              "CHUNK_COUNT" to chunkCount,
              "CRC32" to java.util.zip.CRC32().apply { update(payload) }.value,
              "BENCH_MESSAGE_IDS" to benchmarkMessageIds.joinToString(","),
            ),
          )
          var retries = 0
          fun sendChunk(index: Int): Boolean {
            val offset = index * dataChunkSize
            val length = minOf(dataChunkSize, payload.size - offset)
            val data = payload.copyOfRange(offset, offset + length)
            val frame = buildReplyDataFrame(index, data)
            val sent = notifyBlocking(frame, offset, isEof = false)
            traceBle(
              if (sent) "SERVER_REPLY_CHUNK_SENT" else "SERVER_REPLY_CHUNK_FAILED",
              macAddress,
              connectionId = serverConnectionIds[macAddress],
              fields = mapOf(
                "TRANSFER_ID" to transferId,
                "CHUNK_INDEX" to index,
                "CHUNK_COUNT" to chunkCount,
                "OFFSET" to offset,
                "DATA_BYTES" to data.size,
                "RETRANSMIT" to (retries > 0),
              ),
            )
            return sent
          }
          fun sendEnd(): Boolean = notifyBlocking(
            buildReplyEndFrame(transferId, chunkCount, payload),
            payload.size,
            isEof = true,
            confirm = true,
          )

          val startFrame = buildReplyStartFrame(transferId, chunkCount, payload)
          if (!notifyBlocking(startFrame, 0, isEof = false)) {
            Handler(Looper.getMainLooper()).post {
              result.error("NOTIFY_FAILED", "Framed reply start failed", null)
            }
            return@submit
          }
          traceBle(
            "SERVER_REPLY_START_SENT",
            macAddress,
            connectionId = serverConnectionIds[macAddress],
            fields = mapOf(
              "TRANSFER_ID" to transferId,
              "CHUNK_COUNT" to chunkCount,
              "TOTAL_BYTES" to payload.size,
              "CRC32" to (java.util.zip.CRC32().apply { update(payload) }.value),
            ),
          )
          for (index in 0 until chunkCount) {
            if (!sendChunk(index)) {
              Handler(Looper.getMainLooper()).post {
                result.error("NOTIFY_FAILED", "Framed reply chunk failed at index=$index", null)
              }
              return@submit
            }
          }
          if (!sendEnd()) {
            Handler(Looper.getMainLooper()).post {
              result.error("NOTIFY_FAILED", "Framed reply end indication failed", null)
            }
            return@submit
          }
          traceBle(
            "SERVER_REPLY_FEEDBACK_WAIT_STARTED",
            macAddress,
            connectionId = serverConnectionIds[macAddress],
            fields = mapOf("TRANSFER_ID" to transferId, "TIMEOUT_MS" to replyAckTimeoutMs),
          )

          while (true) {
            val feedback = pending.feedback.poll(replyAckTimeoutMs, TimeUnit.MILLISECONDS)
            if (
              feedback?.accepted == true &&
              pendingServerReplyAcks[macAddress] === pending &&
              connectedServerClients[macAddress] == true
            ) {
              traceBle(
                "SERVER_REPLY_COMPLETE",
                macAddress,
                connectionId = serverConnectionIds[macAddress],
                fields = mapOf(
                  "TRANSFER_ID" to transferId,
                  "PROTOCOL" to "framed_v2",
                  "BYTES" to payload.size,
                  "ACKNOWLEDGED" to true,
                  "RETRIES" to retries,
                ),
              )
              Handler(Looper.getMainLooper()).post { result.success(null) }
              return@submit
            }
            if (
              connectedServerClients[macAddress] != true ||
              !FramedReplyRetryPolicy.canRetry(retries)
            ) {
              traceBle(
                "SERVER_REPLY_ACK_TIMEOUT",
                macAddress,
                connectionId = serverConnectionIds[macAddress],
                fields = mapOf(
                  "TRANSFER_ID" to transferId,
                  "TIMEOUT_MS" to replyAckTimeoutMs,
                  "RETRIES" to retries,
                  "HAS_FEEDBACK" to (feedback != null),
                ),
              )
              Handler(Looper.getMainLooper()).post {
                result.error("NOTIFY_UNCONFIRMED", "Peer did not validate the complete framed reply", null)
              }
              return@submit
            }

            val retryAll = FramedReplyRetryPolicy.shouldReplayAll(
              feedbackReceived = feedback != null,
              retryAllRequested = feedback?.retryAll == true,
            )
            val missing = if (retryAll) {
              (0 until chunkCount).toList()
            } else {
              feedback?.missingChunkIndices.orEmpty().distinct().filter { it in 0 until chunkCount }
            }
            val retryIndices = if (missing.isEmpty()) (0 until chunkCount).toList() else missing
            retries += 1
            traceBle(
              "SERVER_REPLY_RETRY_STARTED",
              macAddress,
              connectionId = serverConnectionIds[macAddress],
              fields = mapOf(
                "TRANSFER_ID" to transferId,
                "RETRY" to retries,
                "REQUESTED_MISSING" to (feedback?.missingChunkIndices?.size ?: 0),
                "RETRY_COUNT" to retryIndices.size,
                "RETRY_ALL" to retryAll,
                "REASON" to if (feedback == null) "ack_timeout" else "peer_nack",
              ),
            )
            var retryFailed = false
            for (index in retryIndices) {
              if (!sendChunk(index)) {
                retryFailed = true
                break
              }
            }
            if (retryFailed || !sendEnd()) {
              Handler(Looper.getMainLooper()).post {
                result.error("NOTIFY_FAILED", "Framed reply retry failed", null)
              }
              return@submit
            }
          }
        } finally {
          pendingServerReplyAcks.remove(macAddress, pending)
        }

      } catch (t: Throwable) {
        Log.e(TAG, "[GATT-NOTIFY] Exception during reply", t)
        Handler(Looper.getMainLooper()).post { result.error("NOTIFY_EXCEPTION", t.message ?: "Unknown", null) }
      }
    }
  }

  private fun coercePayloadBytes(payloadAny: Any?): ByteArray? {
    return when (payloadAny) {
      is ByteArray -> payloadAny
      is List<*> -> {
        try {
          val list = payloadAny.filterNotNull().map { (it as Number).toInt() and 0xFF }
          ByteArray(list.size) { idx -> list[idx].toByte() }
        } catch (_: Throwable) {
          null
        }
      }
      else -> null
    }
  }
}
