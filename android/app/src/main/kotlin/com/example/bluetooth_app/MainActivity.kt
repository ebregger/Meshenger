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
  // Hybrid API state
  private var syncSequenceNumber: Byte = 0
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
  // Set to true during resetNativeServer() to suppress re-entrant disconnect callbacks.
  @Volatile private var isResettingServer = false

  private val SERVICE_UUID = UUID.fromString("c7e4f1a2-9b3d-4a8e-a1f6-2d5e8b9c0a4f")
  private val CHARACTERISTIC_UUID =
    UUID.fromString("6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a")
  // New: Server→Client notification characteristic for single-connection bidirectional sync.
  private val NOTIFY_CHARACTERISTIC_UUID =
    UUID.fromString("b9168cf8-4d57-466d-a6f6-4be440ce8025")
  // 0x2902 Client Characteristic Configuration Descriptor UUID
  private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

  // Lock + state for the Server→Client notifyCharacteristicChanged flow.
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
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
          super.onConnectionStateChange(device, status, newState)
          // Suppress all callbacks during a server reset to avoid the infinite-disconnect
          // cascade: close() fires DISCONNECTED for every cached slot, and if we call
          // cancelConnection() in response, it fires DISCONNECTED again, ad infinitum.
          if (isResettingServer) return
          if (newState == BluetoothProfile.STATE_CONNECTED) {
            connectedServerClients[device.address] = true
            Log.d(TAG, "[SERVER] Client connected: ${device.address}")
          } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            Log.d(TAG, "[SERVER] Client disconnected: ${device.address} status=$status")
            // Only call cancelConnection() if the device was actually connected to us.
            // Calling it on an already-disconnected device triggers another
            // onConnectionStateChange(DISCONNECTED) callback — causing an infinite loop.
            val wasConnected = connectedServerClients.remove(device.address) != null
            if (wasConnected) {
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

      // Start with the reliable legacy advertiser. The modern AdvertisingSet API
      // (for zero-teardown live hash updates) is not started here because Android
      // rejects 'connectable + non-scannable' when a legacy advertiser is already active.
      startLegacyAdvertising(currentAdvertiserHash)

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
    deadMacs.clear()
    isResettingServer = false
    Log.d(TAG, "[SERVER] GATT server reset complete.")
    result.success(null)
  }

  @SuppressLint("MissingPermission")
  private fun updateAdvertiserHash(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val newHash = coercePayloadBytes(call.argument<Any?>("hash"))
    if (newHash == null || newHash.isEmpty()) {
      result.error("bad_args", "hash is required", null)
      return
    }
    currentAdvertiserHash = newHash
    syncSequenceNumber++ // Always increment so remote scanners know it's fresh data

    if (advertiser == null) {
      result.success(null) // Not started yet, hash stored for when server starts.
      return
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentAdvertisingSet != null) {
      // MODERN FAST PATH: Update radio live — zero battery tear-down penalty.
      val scanResponse = buildScanResponseData(currentAdvertiserHash)
      currentAdvertisingSet?.setAdvertisingData(buildPrimaryAd())
      currentAdvertisingSet?.setScanResponseData(scanResponse)
      val hex = currentAdvertiserHash.joinToString("") { "%02x".format(it) }
      Log.d(TAG, "[ADV] (Modern) Live hash update seq=${syncSequenceNumber.toInt() and 0xFF} hex=$hex")
    } else {
      // LEGACY PATH: Debounce stop/start to avoid tearing down active GATT connections.
      val adv = advertiser ?: return result.success(null)
      val cb = advertiseCallback ?: return result.success(null)
      val settings = advertiseSettings ?: return result.success(null)
      pendingHashUpdateHandler?.removeCallbacksAndMessages(null)
      val handler = Handler(Looper.getMainLooper())
      pendingHashUpdateHandler = handler
      handler.postDelayed({
        try { adv.stopAdvertising(cb) } catch (_: Throwable) {}
        adv.startAdvertising(settings, buildPrimaryAd(), buildScanResponseData(currentAdvertiserHash), cb)
        val hex = currentAdvertiserHash.joinToString("") { "%02x".format(it) }
        Log.d(TAG, "[ADV] (Legacy) Advertiser hash updated to $hex (debounced)")
      }, 5000)
    }

    result.success(null)
  }

  /** Primary Ad: Service UUID triggers hardware filter. Kept minimal to fit all OEM 31-byte budgets. */
  private fun buildPrimaryAd(): AdvertiseData {
    return AdvertiseData.Builder()
      .setIncludeTxPowerLevel(false)
      .setIncludeDeviceName(false)
      .addServiceUuid(ParcelUuid(SERVICE_UUID))
      .build()
  }

  /** Scan Response: delivers the heavy hash payload when the scanner actively requests it. */
  private fun buildScanResponseData(hash: ByteArray): AdvertiseData {
    val payload = ByteArray(MESH_MAGIC.size + hash.size)
    System.arraycopy(MESH_MAGIC, 0, payload, 0, MESH_MAGIC.size)
    System.arraycopy(hash, 0, payload, MESH_MAGIC.size, hash.size)
    return AdvertiseData.Builder()
      .addManufacturerData(MESH_MFG_ID, payload)
      .build()
  }

  @SuppressLint("MissingPermission")
  @RequiresApi(Build.VERSION_CODES.O)
  private fun startModernAdvertising(hashPayload: ByteArray) {
    val parameters = AdvertisingSetParameters.Builder()
      .setLegacyMode(true) // BLE 4.x compatibility
      .setConnectable(true)
      .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
      .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
      .build()

    val scanResponse = buildScanResponseData(hashPayload)

    advertisingSetCallback = object : AdvertisingSetCallback() {
      override fun onAdvertisingSetStarted(advertisingSet: AdvertisingSet?, txPower: Int, status: Int) {
        if (status == ADVERTISE_SUCCESS) {
          currentAdvertisingSet = advertisingSet
          Log.d(TAG, "[ADV] Modern AdvertisingSet started txPower=$txPower")
        } else {
          Log.e(TAG, "[ADV] Modern AdvertisingSet FAILED status=$status — falling back to legacy advertiser")
          currentAdvertisingSet = null
          // Legacy fallback: use the classic AdvertiseCallback API
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
      advertiser?.startAdvertisingSet(parameters, buildPrimaryAd(), scanResponse, null, null, advertisingSetCallback)
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
    advertiseSettings = settings
    advertiseCallback = object : AdvertiseCallback() {
      override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
        Log.d(TAG, "[ADV] Legacy advertiser started")
      }
      override fun onStartFailure(errorCode: Int) {
        Log.e(TAG, "[ADV] Legacy advertiser failed: $errorCode")
      }
    }
    try {
      advertiser?.startAdvertising(settings, buildPrimaryAd(), buildScanResponseData(hashPayload), advertiseCallback)
    } catch (e: android.os.DeadObjectException) {
      Log.w(TAG, "[ADV] DeadObjectException on startAdvertising — re-acquiring advertiser and retrying")
      val bm = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
      advertiser = bm?.adapter?.bluetoothLeAdvertiser
      try {
        advertiser?.startAdvertising(settings, buildPrimaryAd(), buildScanResponseData(hashPayload), advertiseCallback)
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
      val deadUntil = deadMacs[macAddress]
      if (deadUntil != null && System.currentTimeMillis() < deadUntil) {
        Handler(Looper.getMainLooper()).post { result.error("timeout", "MAC $macAddress is in dead-cache", null) }
        return@submit
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

      fun completeSuccessOnMain() {
        if (isCompleted.compareAndSet(false, true)) {
          Handler(Looper.getMainLooper()).post { result.success(null) }
          taskLatch.countDown()
        }
      }

      fun completeErrorOnMain(code: String, message: String) {
        if (isCompleted.compareAndSet(false, true)) {
          Handler(Looper.getMainLooper()).post { result.error(code, message, null) }
          taskLatch.countDown()
        }
      }

      val lock = Object()
      var lastWriteOk: Boolean? = null
      var phase: String = "connecting"
      var gatt: BluetoothGatt? = null
      // Track the MTU negotiated by the OS. Android doesn't guarantee 512;
      // the peer may negotiate down to 256 or stay at the 23-byte default.
      // We subtract 3 for the ATT protocol header (opcode + handle = 3 bytes).
      var negotiatedChunkSize: Int = 20 // safe conservative default (23 - 3)

      val connectionWatchdog = Runnable {
        if (isCompleted.compareAndSet(false, true)) {
          val count = failureCounts.getOrDefault(macAddress, 0) + 1
          failureCounts[macAddress] = count
          val timeoutMs = Math.min(1000 * Math.pow(2.0, count.toDouble()).toLong(), 16000L)
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
        if (isCompleted.compareAndSet(false, true)) {
          Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:transfer_timeout")
          try { gatt?.disconnect() } catch (_: Throwable) {}
          try { gatt?.close() } catch (_: Throwable) {}
          Handler(Looper.getMainLooper()).post { result.error("timeout", "Timed out waiting for writing", null) }
          taskLatch.countDown()
        }
      }
      val mainHandler = Handler(Looper.getMainLooper())
      // Start the 12 second watchdog for connection attempt
      mainHandler.postDelayed(connectionWatchdog, 12000)

      try {
        val gattCallback = object : BluetoothGattCallback() {
          override fun onConnectionStateChange(g: BluetoothGatt?, status: Int, newState: Int) {
            super.onConnectionStateChange(g, status, newState)
            if (g == null) return

            if (newState == BluetoothProfile.STATE_CONNECTED) {
              Log.d(TAG, "[GATT] STATE_CONNECTED mac=$macAddress")
              Log.d(TAG, "[BENCHMARK] TARGET_MAC:$macAddress | EVENT:GATT_CONNECTED | TIMESTAMP:${System.currentTimeMillis()}")
              mainHandler.removeCallbacks(connectionWatchdog)
              // 60s: large delta replies (after offer) can take time to write back.
              // The offer packet itself is tiny but the peer's response may be thousands of rows.
              mainHandler.postDelayed(transferWatchdog, 60000)
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
              if (!isCompleted.get()) {
                val count = failureCounts.getOrDefault(macAddress, 0) + 1
                failureCounts[macAddress] = count
                val timeoutMs = Math.min(1000 * Math.pow(2.0, count.toDouble()).toLong(), 16000L)
                deadMacs[macAddress] = System.currentTimeMillis() + timeoutMs
                Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:PENALTY_BOX_ENTERED | DURATION:${timeoutMs/1000}")
                Log.d(TAG, "[DIAGNOSTIC] TARGET_MAC:$macAddress | EVENT:CONNECTION_FAILED | REASON:$status")
                try { g.close() } catch (_: Throwable) {}
                completeErrorOnMain("DISCONNECTED", "Disconnected during phase=$phase status=$status")
              } else {
                // Already completed (e.g. after receiving EOF from server notify).
                // Just close the gatt handle cleanly.
                try { g.close() } catch (_: Throwable) {}
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
              val timeoutMs = Math.min(1000 * Math.pow(2.0, count.toDouble()).toLong(), 16000L)
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
                    // push the Delta reply back via NOTIFY. The connection will be cleanly
                    // closed by onCharacteristicChanged when we receive the "||EOF||" notify.
                    // transferWatchdog (60s) guards against a silent server that never replies.
                    Log.d(TAG, "[GATT] Offer sent. Waiting for notify Delta reply mac=$macAddress")
                    failureCounts.remove(macAddress)
                    completeSuccessOnMain()
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
              val timeoutMs = Math.min(1000 * Math.pow(2.0, count.toDouble()).toLong(), 16000L)
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
              Log.d(TAG, "[GATT-NOTIFY] EOF received — closing connection mac=$macAddress")
              mainHandler.removeCallbacks(transferWatchdog)
              try { g.disconnect() } catch (_: Throwable) {}
            }
          }
        }

        val jitterMs = (500..4500).random().toLong()
        Handler(Looper.getMainLooper()).postDelayed({
          if (connectedServerClients[macAddress] == true) {
            completeErrorOnMain("already_connected", "Already connected as Server to this MAC")
            taskLatch.countDown()
            return@postDelayed
          }
          gatt = device.connectGatt(this@MainActivity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
          if (gatt == null) {
            completeErrorOnMain("connect_failed", "connectGatt returned null")
          }
        }, jitterMs)

        // Block the single-thread queue until this connection attempt finishes (success, fail, or 25s timeout)
        taskLatch.await()
      } catch (e: Exception) {
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

    Thread {
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

          val deadlineMs = System.currentTimeMillis() + 8000L
          synchronized(serverNotifyLock) {
            while (lastNotifyOk == null && System.currentTimeMillis() < deadlineMs) {
              serverNotifyLock.wait(250L)
            }
            return lastNotifyOk == true
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
            return@Thread
          }
          offset += length
        }

        val eof = "||EOF||".toByteArray()
        if (!notifyBlocking(eof)) {
          Handler(Looper.getMainLooper()).post { result.error("NOTIFY_FAILED", "Notify EOF failed", null) }
          return@Thread
        }

        Log.d(TAG, "[GATT-NOTIFY] Delta fully sent to mac=$macAddress")
        Handler(Looper.getMainLooper()).post { result.success(null) }
      } catch (t: Throwable) {
        Log.e(TAG, "[GATT-NOTIFY] Exception during reply", t)
        Handler(Looper.getMainLooper()).post { result.error("NOTIFY_EXCEPTION", t.message ?: "Unknown", null) }
      }
    }.start()
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
