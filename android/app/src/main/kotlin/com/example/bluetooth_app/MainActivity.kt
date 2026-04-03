package com.example.bluetooth_app

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
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
  private val MESH_MFG_ID = 0xFFE0
  private val MESH_MAGIC: ByteArray = byteArrayOf(0x4D, 0x45, 0x53, 0x48) // 'M''E''S''H'

  private val gattExecutor = Executors.newSingleThreadExecutor()
  private val deadMacs = java.util.concurrent.ConcurrentHashMap<String, Long>()
  private var pendingHashUpdateHandler: Handler? = null

  private val SERVICE_UUID = UUID.fromString("c7e4f1a2-9b3d-4a8e-a1f6-2d5e8b9c0a4f")
  private val CHARACTERISTIC_UUID =
    UUID.fromString("6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a")

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
        "send_payload" -> {
          sendPayloadToPeer(call, result)
        }
        else -> result.notImplemented()
      }
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

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
          super.onConnectionStateChange(device, status, newState)
          if (newState == BluetoothProfile.STATE_CONNECTED) {
            Log.d(TAG, "[SERVER] Client connected: ${device.address}")
          } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            Log.d(TAG, "[SERVER] Client disconnected: ${device.address} status=$status")
            // Explicitly cancel to release the GATT server connection slot.
            // Android allows ~7 concurrent server connections; without this they leak.
            try { bluetoothGattServer?.cancelConnection(device) } catch (_: Throwable) {}
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

      val service = BluetoothGattService(
        SERVICE_UUID,
        BluetoothGattService.SERVICE_TYPE_PRIMARY
      )
      service.addCharacteristic(writeNoResponseCharacteristic)

      val added = bluetoothGattServer?.addService(service) ?: false
      if (!added) {
        result.error("service_add_failed", "Failed to add GATT service", null)
        return
      }

      // Start BLE advertising (manufacturer payload) after service is registered.
      advertiser = adapter.bluetoothLeAdvertiser
      if (advertiser == null) {
        result.error("advertiser_unavailable", "BluetoothLeAdvertiser is null", null)
        return
      }

      val settings = AdvertiseSettings.Builder()
        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
        .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
        .setConnectable(true)
        .build()
      advertiseSettings = settings

      val data = buildAdvertiseData(currentAdvertiserHash)

      advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
          Log.d(TAG, "Advertising started (settings=$settingsInEffect)")
        }

        override fun onStartFailure(errorCode: Int) {
          Log.e(TAG, "Advertising failed: $errorCode")
        }
      }

      advertiser?.startAdvertising(settings, data, advertiseCallback)

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
    try {
      advertiser?.let { adv ->
        advertiseCallback?.let { cb ->
          try { adv.stopAdvertising(cb) } catch (_: Throwable) {}
        }
      }
      bluetoothGattServer?.clearServices()
      bluetoothGattServer?.close()
    } catch (_: Throwable) {}
    bluetoothGattServer = null
    deadMacs.clear()
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

    val adv = advertiser
    val cb = advertiseCallback
    val settings = advertiseSettings
    if (adv == null || cb == null || settings == null) {
      result.success(null) // Not started yet, hash stored for when server starts.
      return
    }

    // Debounce: cancel any pending restart and schedule a new one in 5s.
    // This prevents the advertiser from stop/starting (which tears down active GATT
    // connections) on every single message send during a rapid burst.
    pendingHashUpdateHandler?.removeCallbacksAndMessages(null)
    val handler = Handler(Looper.getMainLooper())
    pendingHashUpdateHandler = handler
    handler.postDelayed({
      try { adv.stopAdvertising(cb) } catch (_: Throwable) {}
      val data = buildAdvertiseData(currentAdvertiserHash)
      adv.startAdvertising(settings, data, cb)
      val hex = currentAdvertiserHash.joinToString("") { "%02x".format(it) }
      Log.d(TAG, "[ADV] Advertiser hash updated to $hex (debounced)")
    }, 5000)

    result.success(null)
  }

  private fun buildAdvertiseData(hash: ByteArray): AdvertiseData {
    val payload = ByteArray(MESH_MAGIC.size + hash.size)
    System.arraycopy(MESH_MAGIC, 0, payload, 0, MESH_MAGIC.size)
    System.arraycopy(hash, 0, payload, MESH_MAGIC.size, hash.size)
    return AdvertiseData.Builder()
      .addManufacturerData(MESH_MFG_ID, payload)
      .build()
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

      val connectionWatchdog = Runnable {
        if (isCompleted.compareAndSet(false, true)) {
          deadMacs[macAddress] = System.currentTimeMillis() + 8000L
          try { gatt?.disconnect() } catch (_: Throwable) {}
          try { gatt?.close() } catch (_: Throwable) {}
          Handler(Looper.getMainLooper()).post { result.error("timeout", "Timed out waiting for connection", null) }
          taskLatch.countDown()
        }
      }
      val transferWatchdog = Runnable {
        if (isCompleted.compareAndSet(false, true)) {
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
              mainHandler.removeCallbacks(connectionWatchdog)
              mainHandler.postDelayed(transferWatchdog, 30000)
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
                deadMacs[macAddress] = System.currentTimeMillis() + 8000L
                try { g.close() } catch (_: Throwable) {}
                completeErrorOnMain("DISCONNECTED", "Disconnected during phase=$phase status=$status")
              }
            }
          }

          override fun onMtuChanged(g: BluetoothGatt?, mtu: Int, status: Int) {
            super.onMtuChanged(g, mtu, status)
            Log.d(TAG, "[GATT] onMtuChanged mtu=$mtu status=$status mac=$macAddress")
            if (g == null) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
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
              deadMacs[macAddress] = System.currentTimeMillis() + 15000L
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

                    val chunkSize = 500
                    var offset = 0
                    while (offset < payload.size) {
                      val length = Math.min(chunkSize, payload.size - offset)
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

                    try { g.disconnect() } catch (_: Throwable) {}
                    try { g.close() } catch (_: Throwable) {}
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
              deadMacs[macAddress] = System.currentTimeMillis() + 15000L
              g.disconnect()
              g.close()
              completeErrorOnMain("DISCOVERY_FAILED", "Failed to discover services")
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
        }

        Handler(Looper.getMainLooper()).post {
          gatt = device.connectGatt(this@MainActivity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
          if (gatt == null) {
            completeErrorOnMain("connect_failed", "connectGatt returned null")
          }
        }

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
