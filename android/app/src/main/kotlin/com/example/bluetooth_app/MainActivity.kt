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
import android.os.BatteryManager
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.annotation.RequiresApi
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.ActivityCompat
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private val TAG = "NativeMeshService"

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

  private val gattExecutor = Executors.newSingleThreadExecutor()
  private val deadMacs = java.util.concurrent.ConcurrentHashMap<String, Long>()
  private val failureCounts = java.util.concurrent.ConcurrentHashMap<String, Int>()
  private var pendingHashUpdateHandler: Handler? = null
  // Tracks MACs that are currently connected to our GATT server.
  // Used to guard cancelConnection() — calling it on an already-disconnected
  // device triggers another onConnectionStateChange(DISCONNECTED) callback,
  // creating an infinite cascade that floods the log and bricks the BLE stack.
  private val connectedServerClients = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
  /// Inbound clients that enabled NOTIFY on our CCCD (safe to push deltas).
  private val notifyReadyServerClients = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
  // Set to true during resetNativeServer() to suppress re-entrant disconnect callbacks.
  @Volatile private var isResettingServer = false
  // Connection collision mutex: only one outbound GATT attempt may run at a time.
  private val isOutboundClientBusy = java.util.concurrent.atomic.AtomicBoolean(false)
  private val activeInboundServers = java.util.concurrent.atomic.AtomicInteger(0)
  // Dart sets this during push-on-write so we reject a second inbound (GATT 133).
  @Volatile private var urgentHold = false
  @Volatile private var currentOutboundGatt: BluetoothGatt? = null
  @Volatile private var heldClientGatt: BluetoothGatt? = null
  @Volatile private var heldWriteChar: BluetoothGattCharacteristic? = null
  @Volatile private var heldChunkSize: Int = 20
  @Volatile private var heldClientLeaseStartedAtMs: Long = 0L
  private val clientIoLock = Object()
  @Volatile private var clientIoOk: Boolean? = null
  @Volatile private var heldNotifyLatch: CountDownLatch? = null
  private val outboundCancelRequested = AtomicBoolean(false)
  private val heldClientRelease = Runnable {
    val g = heldClientGatt
    heldClientGatt = null
    heldWriteChar = null
    heldClientLeaseStartedAtMs = 0L
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
  // Per-client MTU negotiated on the server side so we know the notify chunk size.
  private val serverMtuMap = java.util.concurrent.ConcurrentHashMap<String, Int>()

  private val REQUEST_BLUETOOTH_PERMS = 4312

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    requestBluetoothPermissionsIfNeeded()

    val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.featherfawks.mesh/ble")
    val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.featherfawks.mesh/ble_events")

    eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
      }

      override fun onCancel(arguments: Any?) {
        eventSink = null
      }
    })

    methodChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "start_server" -> {
          startNativeServer(call, result)
        }
        "reset_server" -> {
          resetNativeServer(result)
        }
        "update_hash" -> {
          updateAdvertiserHash(call, result)
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
        "connected_server_macs" -> {
          result.success(ArrayList(notifyReadyServerClients.keys.filter { notifyReadyServerClients[it] == true }))
        }
        "has_inbound_clients" -> {
          result.success(connectedServerClients.isNotEmpty())
        }
        "set_urgent_hold" -> {
          urgentHold = call.argument<Boolean>("active") ?: false
          Log.d(TAG, "[SERVER] urgentHold=$urgentHold inbound=${activeInboundServers.get()}")
          result.success(null)
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

      val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
      val adapter = bluetoothManager.adapter
      val callback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicWriteRequest(
          device: BluetoothDevice,
          requestId: Int,
          characteristic: BluetoothGattCharacteristic,
          preparedWrite: Boolean,
          responseNeeded: Boolean,
          offset: Int,
          value: ByteArray?
        ) {
          try {
            if (characteristic.uuid != CHARACTERISTIC_UUID) return
            val bytes = value ?: ByteArray(0)
            deadMacs.remove(device.address)
            failureCounts.remove(device.address)
            Handler(Looper.getMainLooper()).post {
              // Include sender MAC so Dart can reply even if scan routing isn't ready.
              val payload: HashMap<String, Any> = hashMapOf(
                "mac" to device.address,
                "bytes" to bytes
              )
              eventSink?.success(payload)
            }
          } catch (t: Throwable) {
            Log.e(TAG, "Failed pushing payload to Flutter", t)
          } finally {
            if (responseNeeded && bluetoothGattServer != null) {
              bluetoothGattServer?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                offset,
                value ?: ByteArray(0)
              )
            }
          }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
          super.onMtuChanged(device, mtu)
          Log.d(TAG, "[SERVER] onMtuChanged: mtu=$mtu for device=${device.address}")
          serverMtuMap[device.address] = mtu
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
          super.onNotificationSent(device, status)
          synchronized(serverNotifyLock) {
            lastNotifyOk = (status == BluetoothGatt.GATT_SUCCESS)
            serverNotifyLock.notifyAll()
          }
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
          Log.d(TAG, "[SERVER] CCCD write from ${device.address} value=${value?.toList()}")
          if (responseNeeded) {
            bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value ?: ByteArray(0))
          }
          // Mark NOTIFY-ready only after the CCCD response so SDK 28 clients
          // actually subscribe before we push.
          if (descriptor.uuid == CCCD_UUID && value != null && value.isNotEmpty() &&
              (value[0].toInt() and 0x01) != 0) {
            notifyReadyServerClients[device.address] = true
            Handler(Looper.getMainLooper()).post {
              eventSink?.success(hashMapOf("event" to "server_ready", "mac" to device.address))
            }
          }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
          super.onConnectionStateChange(device, status, newState)
          // Suppress all callbacks during a server reset to avoid the infinite-disconnect
          // cascade: close() fires DISCONNECTED for every cached slot, and if we call
          // cancelConnection() in response, it fires DISCONNECTED again, ad infinitum.
          if (isResettingServer) return
          if (newState == BluetoothProfile.STATE_CONNECTED) {
            // 2-node: one inbound. Extra slots fill with RPA ghosts and the
            // real peer is rejected (inbound_cap_2 during 500-burst).
            val inboundCap = 1
            val currentInbound = activeInboundServers.get()
            if (currentInbound >= inboundCap) {
              val ghostMac = connectedServerClients.keys.firstOrNull {
                notifyReadyServerClients[it] != true && it != device.address
              }
              if (ghostMac != null) {
                Log.w(
                  TAG,
                  "[DIAGNOSTIC] TARGET_MAC:$ghostMac | EVENT:CONNECTION_REJECTED | REASON:replace_ghost_for_${device.address}"
                )
                try {
                  val ghost = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(ghostMac)
                  if (ghost != null) bluetoothGattServer?.cancelConnection(ghost)
                } catch (_: Throwable) {}
                connectedServerClients.remove(ghostMac)
                notifyReadyServerClients.remove(ghostMac)
                if (activeInboundServers.get() > 0) activeInboundServers.decrementAndGet()
              } else {
                Log.w(
                  TAG,
                  "[DIAGNOSTIC] TARGET_MAC:${device.address} | EVENT:CONNECTION_REJECTED | REASON:inbound_cap_$currentInbound"
                )
                try {
                  bluetoothGattServer?.cancelConnection(device)
                } catch (_: Throwable) {}
                return
              }
            }
            val wasAlreadyConnected = connectedServerClients.put(device.address, true) != null
            if (!wasAlreadyConnected) {
              val activeConns = activeInboundServers.incrementAndGet()
              Log.d(TAG, "[SERVER] Client connected: ${device.address}. Active inbound connections: $activeConns")
              if (activeConns > 1) {
                Log.w(TAG, "[DIAGNOSTIC] SERVER COLLISION WARNING! Multiple concurrent clients connected ($activeConns). This may cause GATT 133 panics.")
              }
              updateServerBusyState()
              Handler(Looper.getMainLooper()).post {
                eventSink?.success(hashMapOf("event" to "server_connect", "mac" to device.address))
              }
            }
          } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            val activeConnsBefore = activeInboundServers.get()
            val wasConnected = connectedServerClients.remove(device.address) != null
            notifyReadyServerClients.remove(device.address)
            if (wasConnected) {
              val activeConnsAfter = activeInboundServers.decrementAndGet()
              Log.d(TAG, "[SERVER] Client disconnected: ${device.address} status=$status. Active inbound connections now: $activeConnsAfter")
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

      // Ensure the GATT service exists before we advertise.
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
        BluetoothGattCharacteristic.PROPERTY_NOTIFY,
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
        result.error("service_add_failed", "Failed to add GATT service", null)
        return
      }

      // Start BLE advertising after service is registered.
      advertiser = adapter.bluetoothLeAdvertiser
      if (advertiser == null) {
        result.error("advertiser_unavailable", "BluetoothLeAdvertiser is null", null)
        return
      }

      // API 26+: use exclusively the modern AdvertisingSet API so hash updates never
      // restart the radio (bypasses Android's undocumented 5-restarts-in-30s ban).
      // Pre-API 26: fall back to the classic legacy advertiser.
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
      result.error("server_error", t.message ?: "Unknown error", null)
    }
  }

  @SuppressLint("MissingPermission")
  private fun resetNativeServer(result: MethodChannel.Result) {
    Log.d(TAG, "[SERVER] Resetting GATT server to release leaked connection slots...")
    // Raise the guard flag BEFORE close() so the DISCONNECTED callbacks fired
    // by close() are silently swallowed instead of cascading into cancelConnection() calls.
    isResettingServer = true
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
      bluetoothGattServer?.clearServices()
      bluetoothGattServer?.close()
    } catch (_: Throwable) {}
    bluetoothGattServer = null
    connectedServerClients.clear()
    notifyReadyServerClients.clear()
    deadMacs.clear()
    isOutboundClientBusy.set(false)
    activeInboundServers.set(0)
    currentOutboundGatt = null
    outboundCancelRequested.set(false)
    try {
      Handler(Looper.getMainLooper()).removeCallbacks(heldClientRelease)
    } catch (_: Throwable) {}
    val held = heldClientGatt
    heldClientGatt = null
    heldClientLeaseStartedAtMs = 0L
    try { held?.close() } catch (_: Throwable) {}
    isResettingServer = false
    Log.d(TAG, "[SERVER] GATT server reset complete.")
    result.success(null)
  }

  @SuppressLint("MissingPermission")
  private fun releaseHeldClientNow() {
    Handler(Looper.getMainLooper()).removeCallbacks(heldClientRelease)
    val g = heldClientGatt
    heldClientGatt = null
    heldWriteChar = null
    heldClientLeaseStartedAtMs = 0L
    try { g?.disconnect() } catch (_: Throwable) {}
    try { g?.close() } catch (_: Throwable) {}
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
    val handler = Handler(Looper.getMainLooper())
    handler.removeCallbacks(heldClientRelease)
    handler.postDelayed(heldClientRelease, delayMs)
    Log.d(
      TAG,
      "[GATT] Held-link lease refresh idle=${delayMs}ms hardRemaining=${hardRemaining}ms"
    )
  }

  @SuppressLint("MissingPermission")
  private fun writeOnHeldClient(
    payload: ByteArray,
    result: MethodChannel.Result,
  ): Boolean {
    val g = heldClientGatt ?: return false
    val characteristic = heldWriteChar ?: return false
    if (!isOutboundClientBusy.compareAndSet(false, true)) {
      Handler(Looper.getMainLooper()).post {
        result.error("gatt_busy", "Held client write already in flight", null)
      }
      return true
    }
    Handler(Looper.getMainLooper()).removeCallbacks(heldClientRelease)
    val notifyLatch = CountDownLatch(1)
    heldNotifyLatch = notifyLatch
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
        if (!started) return false
        val deadlineMs = System.currentTimeMillis() + 8000L
        synchronized(clientIoLock) {
          while (clientIoOk == null && System.currentTimeMillis() < deadlineMs) {
            clientIoLock.wait(50L)
          }
          return clientIoOk == true
        }
      }
      val chunkSize = heldChunkSize.coerceIn(20, 512)
      var offset = 0
      Log.d(TAG, "[GATT] Reusing held client link ${payload.size}B chunk=$chunkSize")
      while (offset < payload.size) {
        val length = minOf(chunkSize, payload.size - offset)
        if (!writeBlocking(payload.copyOfRange(offset, offset + length))) {
          Log.w(TAG, "[GATT] Held-link write failed — releasing for reconnect")
          releaseHeldClientNow()
          return false
        }
        offset += length
      }
      if (!writeBlocking("||EOF||".toByteArray())) {
        Log.w(TAG, "[GATT] Held-link EOF failed — releasing for reconnect")
        releaseHeldClientNow()
        return false
      }
      if (!notifyLatch.await(3, java.util.concurrent.TimeUnit.SECONDS)) {
        Log.w(TAG, "[GATT] Held-link notify timeout — releasing for reconnect")
        releaseHeldClientNow()
        return false
      }
      Handler(Looper.getMainLooper()).post { result.success(null) }
      heldClientGatt = g
      return true
    } catch (t: Throwable) {
      Log.e(TAG, "[GATT] Held-link exception ${t.message} — releasing")
      releaseHeldClientNow()
      return false
    } finally {
      if (heldNotifyLatch === notifyLatch) heldNotifyLatch = null
      isOutboundClientBusy.set(false)
    }
  }

  @SuppressLint("MissingPermission")
  private fun cancelOutboundClient() {
    outboundCancelRequested.set(true)
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
    val macs = connectedServerClients.keys.toList()
    for (mac in macs) {
      try {
        val device = bm.adapter.getRemoteDevice(mac)
        bluetoothGattServer?.cancelConnection(device)
      } catch (_: Throwable) {}
      connectedServerClients.remove(mac)
      notifyReadyServerClients.remove(mac)
    }
    activeInboundServers.set(0)
    updateServerBusyState()
    Log.d(TAG, "[SERVER] disconnect_inbound cleared ${macs.size} client(s)")
  }

  @SuppressLint("MissingPermission")
  private fun updateServerBusyState() {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentAdvertisingSet != null) {
          try {
              currentAdvertisingSet?.setAdvertisingData(buildPrimaryAd(currentAdvertiserHash))
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

    // Both Modern and Legacy APIs: use a debounced stop+restart to update the advertisement.
    // setAdvertisingData/setScanResponseData are silently dropped by many Qualcomm/Samsung HALs
    // in LegacyMode after the first call — the only reliable approach is to stop and restart.
    // MAC rotation from restart is acceptable: scanner-side identity is keyed on the 64-bit DB
    // hash in the scan response packet, not the random resolvable address.
    pendingHashUpdateHandler?.removeCallbacksAndMessages(null)
    val handler = Handler(Looper.getMainLooper())
    pendingHashUpdateHandler = handler
    handler.postDelayed({
      val hex = currentAdvertiserHash.joinToString("") { "%02x".format(it) }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentAdvertisingSet != null) {
        Log.d(TAG, "[ADV] Restarting Modern AdvertisingSet for hash update hex=$hex...")
        try {
          advertiser?.stopAdvertisingSet(advertisingSetCallback!!)
        } catch (e: Throwable) {
          Log.e(TAG, "[ADV] stopAdvertisingSet error: ${e.message}")
        }
        currentAdvertisingSet = null
        startModernAdvertising(currentAdvertiserHash)
        Log.d(TAG, "[ADV] (Modern) Restarted AdvertisingSet with hash=$hex")
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

  /** Primary Ad: Service UUID triggers hardware filter. Kept minimal to fit all OEM 31-byte budgets. */
  private fun buildPrimaryAd(hashPayload: ByteArray): AdvertiseData {
    // REVISED: For Legacy mode (which we are forcing for compatibility),
    // the manufacturer data MUST go into the scan response because
    // Flags (3) + 128-bit UUID (18) + Manufacturer Data (20) = 41 bytes (exceeds 31).
    return AdvertiseData.Builder()
      .setIncludeTxPowerLevel(false)
      .setIncludeDeviceName(false)
      .addServiceUuid(ParcelUuid(SERVICE_UUID))
      .addManufacturerData(0xFFE1, buildTelemetryBytes(hashPayload))
      .build()
  }

  private fun buildTelemetryBytes(hashPayload: ByteArray): ByteArray {
      val telemetry = ByteArray(4)
      if (hashPayload.size >= 4) {
          telemetry[0] = hashPayload[2]
          telemetry[1] = hashPayload[3]
      } else if (hashPayload.size >= 2) {
          telemetry[0] = hashPayload[0]
          telemetry[1] = hashPayload[1]
      }
      
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
      // Only advertise busy when at inbound capacity — flagging busy on the first
      // connection made every peer back off and multi-second catch-up stalls.
      val isBusy = activeInboundServers.get() >= 2
      val hopDistance = 0 

      var flags = 0
      if (isGateway) flags = flags or (1 shl 0)
      if (isLowBattery) flags = flags or (1 shl 1)
      if (isLegacy) flags = flags or (1 shl 2)
      if (isIOS) flags = flags or (1 shl 3)
      if (isBusy) flags = flags or (1 shl 4)
      
      val clampedHop = hopDistance.coerceIn(0, 3)
      flags = flags or (clampedHop shl 5)

      telemetry[2] = (flags and 0xFF).toByte()
      telemetry[3] = ((flags shr 8) and 0xFF).toByte()

      val hex0 = String.format("%02X", telemetry[0].toInt() and 0xFF)
      val hex1 = String.format("%02X", telemetry[1].toInt() and 0xFF)
      Log.d(TAG, "[DIAGNOSTIC] BROADCASTING TELEMETRY HEADER BYTES: 0x$hex0 0x$hex1")

      return telemetry
  }

  private fun buildScanResponseData(hash: ByteArray, prefix: ByteArray? = null): AdvertiseData {
    val payloadSize = MESH_MAGIC.size + hash.size + (prefix?.size ?: 0)
    val payload = ByteArray(payloadSize)
    System.arraycopy(MESH_MAGIC, 0, payload, 0, MESH_MAGIC.size)
    System.arraycopy(hash, 0, payload, MESH_MAGIC.size, hash.size)
    if (prefix != null) {
      System.arraycopy(prefix, 0, payload, MESH_MAGIC.size + hash.size, prefix.size)
    }
    return AdvertiseData.Builder()
      .addManufacturerData(MESH_MFG_ID, payload)
      .build()
  }

  @SuppressLint("MissingPermission")
  @RequiresApi(Build.VERSION_CODES.O)
  private fun startModernAdvertising(hashPayload: ByteArray) {
    // Use non-legacy (extended) mode on BLE 5 capable devices (all on API 26+).
    // Non-legacy mode: no 31-byte constraint, connectable + scan response works without HAL conflicts.
    // setLegacyMode(false) uses ADV_EXT_IND which is supported by all BLE 5 central devices.
    // Legacy BLE 4.x-only centrals won't see this — they will see nothing. However all
    // devices in this mesh are API 26+ (confirmed SDK 36) so this is acceptable.
    val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    val isLegacyMode = !adapter.isLeExtendedAdvertisingSupported
    val parameters = AdvertisingSetParameters.Builder()
      // We FORCE legacy mode (true) even on Extended-capable hardware.
      // This ensures Device 2 (Android 9) and other older devices can see the packets,
      // while still using the AdvertisingSet API to avoid the radio-restart ban.
      .setLegacyMode(true) 
      .setConnectable(true)
      .setScannable(true) // Required for Legacy Mode if we want a Scan Response
      .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
      .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
      .build()

    // In Legacy Mode (forced), we MUST put the data in the scan response.
    val scanResponse = buildScanResponseData(hashPayload, currentNodeIdPrefix)
    val primaryAd = buildPrimaryAd(hashPayload)

    advertisingSetCallback = object : AdvertisingSetCallback() {
      override fun onAdvertisingSetStarted(advertisingSet: AdvertisingSet?, txPower: Int, status: Int) {
        if (status == ADVERTISE_SUCCESS) {
          currentAdvertisingSet = advertisingSet
          Log.d(TAG, "[ADV] Modern AdvertisingSet (Legacy Format) started txPower=$txPower")
        } else {
          Log.e(TAG, "[ADV] Modern AdvertisingSet FAILED status=$status — falling back to legacy advertiser")
          currentAdvertisingSet = null
          Handler(Looper.getMainLooper()).post { startLegacyAdvertising(hashPayload) }
        }
      }
      override fun onAdvertisingSetStopped(advertisingSet: AdvertisingSet?) {
        if (currentAdvertisingSet == advertisingSet) currentAdvertisingSet = null
        Log.d(TAG, "[ADV] Modern AdvertisingSet stopped")
      }
      override fun onAdvertisingEnabled(advertisingSet: AdvertisingSet?, enable: Boolean, status: Int) {
        Log.d(TAG, "[ADV] Modern advertising enabled=$enable status=$status")
      }
    }

    try {
      // In non-legacy mode, put everything in the primary ad. Scan response is often ignored.
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
    Log.d(TAG, "[ADV] Starting Legacy Advertiser with settings: $settings")
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
        advertiser?.startAdvertising(settings, buildPrimaryAd(hashPayload), buildScanResponseData(hashPayload), advertiseCallback)
      } catch (e2: Throwable) {
        Log.e(TAG, "[ADV] Retry also failed: ${e2.message}")
      }
    } catch (e: Throwable) {
      Log.e(TAG, "[ADV] startAdvertising threw: ${e.message}")
    }
  }

  @SuppressLint("MissingPermission")
  private fun sendPayloadToPeer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val macAddress = call.argument<String>("macAddress")
    val isRandom = call.argument<Boolean>("isRandom") ?: false
    val bypassDeadCache = call.argument<Boolean>("bypassDeadCache") ?: false
    if (macAddress.isNullOrBlank()) {
      result.error("bad_args", "macAddress is required", null)
      return
    }

    val payload = coercePayloadBytes(call.argument<Any?>("payload"))
    if (payload == null) {
      result.error("bad_args", "payload must be a ByteArray/Uint8List", null)
      return
    }

    gattExecutor.submit {
      outboundCancelRequested.set(false)
      val deadUntil = deadMacs[macAddress]
      if (!bypassDeadCache && deadUntil != null && System.currentTimeMillis() < deadUntil) {
        Handler(Looper.getMainLooper()).post { result.error("timeout", "MAC $macAddress is in dead-cache", null) }
        return@submit
      }
      if (writeOnHeldClient(payload, result)) {
        return@submit
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
      var phase: String = "connecting"
      var gatt: BluetoothGatt? = null

      fun completeSuccessOnMain() {
        if (isCompleted.compareAndSet(false, true)) {
          Handler(Looper.getMainLooper()).post { result.success(null) }
          taskLatch.countDown()
        }
      }

      fun completeErrorOnMain(code: String, message: String) {
        if (isCompleted.compareAndSet(false, true)) {
          isOutboundClientBusy.set(false)
          try { gatt?.disconnect() } catch (_: Throwable) {}
          try { gatt?.close() } catch (_: Throwable) {}
          Handler(Looper.getMainLooper()).post { result.error(code, message, null) }
          taskLatch.countDown()
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
          deadMacs[macAddress] = System.currentTimeMillis() + timeoutMs
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:timeout")
          try { gatt?.disconnect() } catch (_: Throwable) {}
          try { gatt?.close() } catch (_: Throwable) {}
          Handler(Looper.getMainLooper()).post { result.error("timeout", "Timed out waiting for connection", null) }
          taskLatch.countDown()
        }
      }
      val transferWatchdog = Runnable {
        isOutboundClientBusy.set(false)
        Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:transfer_timeout")
        try { gatt?.disconnect() } catch (_: Throwable) {}
        try { gatt?.close() } catch (_: Throwable) {}
        if (isCompleted.compareAndSet(false, true)) {
          Handler(Looper.getMainLooper()).post { result.error("timeout", "Timed out waiting for writing", null) }
          taskLatch.countDown()
        }
      }
      val mainHandler = Handler(Looper.getMainLooper())
      // Watchdog starts when connectGatt is issued (not before jitter), otherwise a
      // 0–1.8s delay silently eats most of a 4s budget and Pixel 3 peers time out.

      try {
        val gattCallback = object : BluetoothGattCallback() {
          override fun onConnectionStateChange(g: BluetoothGatt?, status: Int, newState: Int) {
            super.onConnectionStateChange(g, status, newState)
            if (g == null) return

            if (newState == BluetoothProfile.STATE_CONNECTED) {
              isOutboundClientBusy.set(true)
              Log.d(TAG, "[GATT] STATE_CONNECTED mac=$macAddress")
              Log.d(TAG, "[BENCHMARK] TARGET_MAC:$macAddress | EVENT:GATT_CONNECTED | TIMESTAMP:${System.currentTimeMillis()}")
              mainHandler.removeCallbacks(connectionWatchdog)
              // Offer round-trips should finish in a few seconds. A 60s transfer
              // watchdog left urgent push-on-write blocked behind a dead peer.
              mainHandler.postDelayed(transferWatchdog, 15000)
              phase = "request_mtu"
              Handler(Looper.getMainLooper()).postDelayed({
                if (!isCompleted.get()) {
                  try {
                    val ok = g.requestMtu(512)
                    Log.d(TAG, "[GATT] requestMtu initiated: $ok mac=$macAddress")
                  } catch (e: Exception) {
                    Log.e(TAG, "[GATT] requestMtu exception mac=$macAddress", e)
                    completeErrorOnMain("MTU_EXCEPTION", "Failed to initiate requestMtu")
                  }
                }
              }, 50)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
              Log.d(TAG, "[GATT] STATE_DISCONNECTED phase=$phase status=$status mac=$macAddress")
              isOutboundClientBusy.set(false) // Always release the mutex on disconnect.
              if (!isCompleted.get()) {
                val count = failureCounts.getOrDefault(macAddress, 0) + 1
                failureCounts[macAddress] = count
                val timeoutMs = Math.min(500 * Math.pow(2.0, count.toDouble()).toLong(), 2000L)
                deadMacs[macAddress] = System.currentTimeMillis() + timeoutMs
                Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
                Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:$status")
                try { g.close() } catch (_: Throwable) {}
                completeErrorOnMain("DISCONNECTED", "Disconnected during phase=$phase status=$status")
              } else {
                // Already completed (e.g. after receiving EOF from server notify).
                try { g.close() } catch (_: Throwable) {}
                if (heldClientGatt === g) heldClientGatt = null
              }
            }
          }

          override fun onMtuChanged(g: BluetoothGatt?, mtu: Int, status: Int) {
            super.onMtuChanged(g, mtu, status)
            Log.d(TAG, "[GATT] onMtuChanged mtu=$mtu status=$status mac=$macAddress")
            if (g == null) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
              // Subtract 3 bytes for the ATT protocol header (1 opcode + 2 handle).
              // Also clamp to 512: Android's GATT stack hard-caps attribute writes at 512 bytes
              // regardless of the negotiated MTU. Some devices report mtu=517 (L2CAP frame size)
              // which would cause writeCharacteristic to throw if we naively use mtu-3=514.
              negotiatedChunkSize = (mtu - 3).coerceIn(20, 512)
              Log.d(TAG, "[GATT] Effective chunk size: $negotiatedChunkSize bytes mac=$macAddress")
              phase = "discover_services"
              Handler(Looper.getMainLooper()).postDelayed({
                if (!isCompleted.get()) {
                  try {
                    g.discoverServices()
                  } catch (e: Exception) {
                    completeErrorOnMain("SERVICES_EXCEPTION", "Failed to initiate discoverServices")
                  }
                }
              }, 50)
            } else {
              val count = failureCounts.getOrDefault(macAddress, 0) + 1
              failureCounts[macAddress] = count
              val timeoutMs = Math.min(500 * Math.pow(2.0, count.toDouble()).toLong(), 2000L)
              deadMacs[macAddress] = System.currentTimeMillis() + timeoutMs
              Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
              Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:mtu_failure_$status")
              g.disconnect()
              g.close()
              completeErrorOnMain("MTU_FAILED", "Failed to request MTU")
            }
          }

          override fun onServicesDiscovered(g: BluetoothGatt?, status: Int) {
            super.onServicesDiscovered(g, status)
            Log.d(TAG, "[GATT] onServicesDiscovered status=$status mac=$macAddress")
            if (g == null) return

            if (status == BluetoothGatt.GATT_SUCCESS) {
              phase = "services_discovered"
              val service = g.getService(SERVICE_UUID)
              val characteristic = service?.getCharacteristic(CHARACTERISTIC_UUID)

              if (characteristic != null) {
                Thread {
                  try {
                    phase = "subscribe_notify"
                    val notifyChar = service.getCharacteristic(NOTIFY_CHARACTERISTIC_UUID)
                    if (notifyChar != null) {
                      g.setCharacteristicNotification(notifyChar, true)
                      val descriptor = notifyChar.getDescriptor(CCCD_UUID)
                      if (descriptor != null) {
                        synchronized(lock) { lastWriteOk = null }
                        val started = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                          g.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
                        } else {
                          @Suppress("DEPRECATION")
                          descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                          @Suppress("DEPRECATION")
                          g.writeDescriptor(descriptor)
                        }
                        if (started) {
                          val deadlineMs = System.currentTimeMillis() + 8000L
                          synchronized(lock) {
                            while (lastWriteOk == null && System.currentTimeMillis() < deadlineMs) {
                              lock.wait(250L)
                            }
                          }
                          Log.d(TAG, "[GATT] Subscribed to NOTIFY mac=$macAddress result=$lastWriteOk")
                        }
                      }
                    }

                    phase = "writing"
                    heldWriteChar = characteristic
                    heldChunkSize = negotiatedChunkSize
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

                    fun writeBlocking(bytes: ByteArray): Boolean {
                      synchronized(lock) { lastWriteOk = null }

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

                      val deadlineMs = System.currentTimeMillis() + 8000L
                      synchronized(lock) {
                        while (lastWriteOk == null && System.currentTimeMillis() < deadlineMs) {
                          lock.wait(250L)
                        }
                        return lastWriteOk == true
                      }
                    }

                    // Use the MTU negotiated with this specific peer, not a hardcoded constant.
                    // Android is not guaranteed to grant 512; it may stay at 23 bytes (default) on some devices.
                    var offset = 0
                    Log.d(TAG, "[GATT] Starting chunked write: ${payload.size} bytes in chunks of $negotiatedChunkSize mac=$macAddress")
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
                    // Success is signaled when we receive the server's "||EOF||" notify.
                    Log.d(TAG, "[GATT] Offer sent. Waiting for notify Delta reply mac=$macAddress")
                    failureCounts.remove(macAddress)
                  } catch (t: Throwable) {
                    try { g.disconnect() } catch (_: Throwable) {}
                    try { g.close() } catch (_: Throwable) {}
                    completeErrorOnMain("SEND_EXCEPTION", t.message ?: "send exception")
                  }
                }.start()
              } else {
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
              deadMacs[macAddress] = System.currentTimeMillis() + timeoutMs
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
            synchronized(lock) {
              lastWriteOk = status == BluetoothGatt.GATT_SUCCESS
              lock.notifyAll()
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
            Log.d(TAG, "[GATT-NOTIFY] Received chunk ${value.size} bytes from server mac=$macAddress")
            // Forward the chunk to Flutter exactly as if a write came in from the other direction.
            Handler(Looper.getMainLooper()).post {
              val payload: HashMap<String, Any> = hashMapOf("mac" to macAddress, "bytes" to value)
              eventSink?.success(payload)
            }
            if (value.contentEquals("||EOF||".toByteArray())) {
              Log.d(TAG, "[GATT-NOTIFY] EOF received — holding client link mac=$macAddress")
              mainHandler.removeCallbacks(transferWatchdog)
              isOutboundClientBusy.set(false)
              completeSuccessOnMain()
              heldNotifyLatch?.countDown()
              heldNotifyLatch = null
              // Reuse this link for immediate newest + old-page catch-up, but cap
              // the lease so another mesh peer gets the single inbound slot.
              heldClientGatt = g
              scheduleHeldClientRelease(g)
            }
          }
        }

        // Connection collision guard: only one outbound GATT attempt at a time.
        if (!isOutboundClientBusy.compareAndSet(false, true)) {
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_SKIPPED | REASON:gatt_busy")
          Handler(Looper.getMainLooper()).post { result.error("gatt_busy", "GATT is currently busy, retry on next scan cycle", null) }
          return@submit
        }

        // Prefer a short settle delay; long jitter was stacking with the connect
        // watchdog and making live catch-up miss the few-second budget.
        val jitterMs = (50..250).random().toLong()
        Handler(Looper.getMainLooper()).postDelayed({
          if (isCompleted.get() || outboundCancelRequested.get()) {
            isOutboundClientBusy.set(false)
            if (!isCompleted.get()) {
              completeErrorOnMain("cancelled", "Outbound cancelled")
            }
            return@postDelayed
          }
          if (connectedServerClients[macAddress] == true) {
            isOutboundClientBusy.set(false)
            completeErrorOnMain("already_connected", "Already connected as Server to this MAC")
            return@postDelayed
          }
          releaseHeldClientNow()
          // Urgent push-on-write uses bypassDeadCache; fail stale RPAs faster so a
          // scan-MAC retry still fits in the few-second catch-up budget.
          val connectTimeoutMs = if (bypassDeadCache) 1800L else 3500L
          mainHandler.postDelayed(connectionWatchdog, connectTimeoutMs)
          gatt = device.connectGatt(this@MainActivity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
          currentOutboundGatt = gatt
          if (gatt == null) {
            mainHandler.removeCallbacks(connectionWatchdog)
            isOutboundClientBusy.set(false)
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

  // Server-side reply: push a Delta payload back to a connected Client via NOTIFY.
  // This avoids the GATT 257 "role-switching" crash by reusing the existing open connection
  // instead of spinning up a second GAP link.
  @SuppressLint("MissingPermission")
  private fun replyPayloadToPeer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val macAddress = call.argument<String>("macAddress")
      ?: return result.error("no_mac", "macAddress is required", null)
    val payload = coercePayloadBytes(call.argument<Any?>("payload")) ?: ByteArray(0)

    val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    // getRemoteDevice is safe here: we have an active server connection to this address.
    val device = bm.adapter.getRemoteDevice(macAddress)
    val server = bluetoothGattServer ?: return result.error("no_server", "GATT server not started", null)
    val service = server.getService(SERVICE_UUID)
    val notifyChar = service?.getCharacteristic(NOTIFY_CHARACTERISTIC_UUID)
      ?: return result.error("no_char", "NOTIFY characteristic not found in service", null)

    serverReplyExecutor.submit {
      try {
        val mtu = serverMtuMap[macAddress] ?: 23
        val chunkSize = (mtu - 3).coerceIn(20, 512)

        fun notifyBlocking(chunk: ByteArray): Boolean {
          synchronized(serverNotifyLock) { lastNotifyOk = null }

          if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, notifyChar, false, chunk)
          } else {
            @Suppress("DEPRECATION")
            notifyChar.value = chunk
            server.notifyCharacteristicChanged(device, notifyChar, false)
          }

          // SDK 28 often never fires onNotificationSent for unconfirmed NOTIFY.
          // Wait briefly for an explicit NACK; treat timeout as sent.
          val deadlineMs = System.currentTimeMillis() + 400L
          synchronized(serverNotifyLock) {
            while (lastNotifyOk == null && System.currentTimeMillis() < deadlineMs) {
              serverNotifyLock.wait(50L)
            }
            return lastNotifyOk != false
          }
        }

        Log.d(TAG, "[GATT-NOTIFY] Sending ${payload.size} bytes in chunks of $chunkSize to mac=$macAddress")
        var offset = 0
        while (offset < payload.size) {
          val length = minOf(chunkSize, payload.size - offset)
          val chunk = payload.copyOfRange(offset, offset + length)
          if (!notifyBlocking(chunk)) {
            Log.e(TAG, "[GATT-NOTIFY] Notify chunk failed at offset=$offset")
            Handler(Looper.getMainLooper()).post { result.error("NOTIFY_FAILED", "Notify chunk failed at offset=$offset", null) }
            return@submit
          }
          offset += length
        }

        val eof = "||EOF||".toByteArray()
        if (!notifyBlocking(eof)) {
          Handler(Looper.getMainLooper()).post { result.error("NOTIFY_FAILED", "Notify EOF failed", null) }
          return@submit
        }

        Log.d(TAG, "[GATT-NOTIFY] Delta fully sent to mac=$macAddress")
        Handler(Looper.getMainLooper()).post { result.success(null) }
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
