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

      result.success(null)
    } catch (t: Throwable) {
      result.error("server_error", t.message ?: "Unknown error", null)
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

    val adv = advertiser
    val cb = advertiseCallback
    val settings = advertiseSettings
    if (adv == null || cb == null || settings == null) {
      result.error("not_started", "Advertiser not started yet", null)
      return
    }

    try {
      adv.stopAdvertising(cb)
    } catch (_: Throwable) {}

    val data = buildAdvertiseData(currentAdvertiserHash)
    adv.startAdvertising(settings, data, cb)
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
    if (macAddress.isNullOrBlank()) {
      result.error("bad_args", "macAddress is required", null)
      return
    }

    val payload = coercePayloadBytes(call.argument<Any?>("payload"))
    if (payload == null) {
      result.error("bad_args", "payload must be a ByteArray/Uint8List", null)
      return
    }

    val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    val adapter: BluetoothAdapter = bluetoothManager.adapter
    val device = adapter.getRemoteDevice(macAddress)

    val isCompleted = java.util.concurrent.atomic.AtomicBoolean(false)

    fun completeSuccessOnMain() {
      Handler(Looper.getMainLooper()).post {
        if (isCompleted.compareAndSet(false, true)) {
          result.success(null)
        }
      }
    }

    fun completeErrorOnMain(code: String, message: String) {
      Handler(Looper.getMainLooper()).post {
        if (isCompleted.compareAndSet(false, true)) {
          result.error(code, message, null)
        }
      }
    }

    val lock = Object()
    var lastWriteOk: Boolean? = null
    var phase: String = "connecting"

    val gattCallback = object : BluetoothGattCallback() {
      override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
        super.onConnectionStateChange(gatt, status, newState)
        if (gatt == null) return

        if (newState == BluetoothProfile.STATE_CONNECTED) {
          phase = "request_mtu"
          val ok = gatt.requestMtu(512)
          Log.d(TAG, "requestMtu initiated: $ok")
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
          if (!isCompleted.get()) {
            try {
              gatt.close()
            } catch (_: Throwable) {}
            completeErrorOnMain("DISCONNECTED", "Disconnected during phase=$phase status=$status")
          }
        }
      }

      override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
        super.onMtuChanged(gatt, mtu, status)
        if (gatt == null) return
        if (status == BluetoothGatt.GATT_SUCCESS) {
          phase = "discover_services"
          gatt.discoverServices()
        } else {
          gatt.disconnect()
          gatt.close()
          completeErrorOnMain("MTU_FAILED", "Failed to request MTU")
        }
      }

      override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
        super.onServicesDiscovered(gatt, status)
        if (gatt == null) return

        if (status == BluetoothGatt.GATT_SUCCESS) {
          phase = "services_discovered"
          val service = gatt.getService(SERVICE_UUID)
          val characteristic = service?.getCharacteristic(CHARACTERISTIC_UUID)

          if (characteristic != null) {
            Thread {
              try {
                phase = "writing"
                // Use write-with-response so we can deterministically know when each chunk is accepted.
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

                fun writeBlocking(bytes: ByteArray): Boolean {
                  synchronized(lock) { lastWriteOk = null }

                  val started: Boolean = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    val rc = gatt.writeCharacteristic(characteristic, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                    rc == BluetoothGatt.GATT_SUCCESS
                  } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = bytes
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(characteristic)
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
                    try { gatt.disconnect() } catch (_: Throwable) {}
                    try { gatt.close() } catch (_: Throwable) {}
                    completeErrorOnMain("WRITE_FAILED", "Write chunk failed at offset=$offset len=$length")
                    return@Thread
                  }
                  offset += length
                }

                // EOF marker
                val eof = "||EOF||".toByteArray()
                val eofOk = writeBlocking(eof)
                if (!eofOk) {
                  try { gatt.disconnect() } catch (_: Throwable) {}
                  try { gatt.close() } catch (_: Throwable) {}
                  completeErrorOnMain("WRITE_FAILED", "Write EOF failed")
                  return@Thread
                }

                try { gatt.disconnect() } catch (_: Throwable) {}
                try { gatt.close() } catch (_: Throwable) {}
                completeSuccessOnMain()
              } catch (t: Throwable) {
                try { gatt.disconnect() } catch (_: Throwable) {}
                try { gatt.close() } catch (_: Throwable) {}
                completeErrorOnMain("SEND_EXCEPTION", t.message ?: "send exception")
              }
            }.start()
          } else {
            gatt.disconnect()
            gatt.close()
            val discovered = try {
              gatt.services?.joinToString(separator = ";") { s ->
                val chars = s.characteristics?.joinToString(separator = ",") { c -> c.uuid.toString() } ?: ""
                "${s.uuid}[$chars]"
              } ?: "<no-services>"
            } catch (_: Throwable) {
              "<services-enum-failed>"
            }
            completeErrorOnMain(
              "CHAR_NOT_FOUND",
              "Mesh characteristic not found. expectedService=$SERVICE_UUID expectedChar=$CHARACTERISTIC_UUID discovered=$discovered"
            )
          }
        } else {
          gatt.disconnect()
          gatt.close()
          completeErrorOnMain("DISCOVERY_FAILED", "Failed to discover services")
        }
      }

      override fun onCharacteristicWrite(
        gatt: BluetoothGatt?,
        characteristic: BluetoothGattCharacteristic?,
        status: Int
      ) {
        super.onCharacteristicWrite(gatt, characteristic, status)
        synchronized(lock) {
          lastWriteOk = status == BluetoothGatt.GATT_SUCCESS
          lock.notifyAll()
        }
      }
    }

    val gatt = device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    if (gatt == null) {
      completeErrorOnMain("connect_failed", "connectGatt returned null")
      return
    }

    // Watchdog: avoid leaving the Dart Future pending forever.
    Handler(Looper.getMainLooper()).postDelayed({
      if (isCompleted.compareAndSet(false, true)) {
        try {
          gatt.disconnect()
        } catch (_: Throwable) {}
        try {
          gatt.close()
        } catch (_: Throwable) {}
        result.error("timeout", "Timed out waiting for MTU/services/write", null)
      }
    }, 10000)
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
