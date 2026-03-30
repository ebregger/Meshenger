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
              eventSink?.success(bytes)
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

      // Start BLE advertising so FlutterBluePlus can scan/filter by SERVICE_UUID.
      advertiser = adapter.bluetoothLeAdvertiser
      if (advertiser == null) {
        result.error("advertiser_unavailable", "BluetoothLeAdvertiser is null", null)
        return
      }

      val hashBytes = coercePayloadBytes(call.argument<Any?>("hash"))
      if (hashBytes != null && hashBytes.isNotEmpty()) {
        currentAdvertiserHash = hashBytes
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

      val writeNoResponseCharacteristic = BluetoothGattCharacteristic(
        CHARACTERISTIC_UUID,
        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
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
    return AdvertiseData.Builder()
      .addManufacturerData(0xFFE0, hash)
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

    val gattCallback = object : BluetoothGattCallback() {
      override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
        super.onConnectionStateChange(gatt, status, newState)
        if (gatt == null) return

        if (newState == BluetoothProfile.STATE_CONNECTED) {
          val ok = gatt.requestMtu(512)
          Log.d(TAG, "requestMtu initiated: $ok")
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
          if (!isCompleted.get()) {
            try {
              gatt.close()
            } catch (_: Throwable) {}
            completeErrorOnMain("DISCONNECTED", "Disconnected before write completed")
          }
        }
      }

      override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
        super.onMtuChanged(gatt, mtu, status)
        if (gatt == null) return
        if (status == BluetoothGatt.GATT_SUCCESS) {
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
          val service = gatt.getService(UUID.fromString("c7e4f1a2-9b3d-4a8e-a1f6-2d5e8b9c0a4f"))
          val characteristic = service?.getCharacteristic(UUID.fromString("6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a"))

          if (characteristic != null) {
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            Thread {
                val chunkSize = 500
                var offset = 0
                while (offset < payload.size) {
                    val length = Math.min(chunkSize, payload.size - offset)
                    val chunk = ByteArray(length)
                    System.arraycopy(payload, offset, chunk, 0, length)

                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                        gatt.writeCharacteristic(characteristic, chunk, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
                    } else {
                        @Suppress("DEPRECATION")
                        characteristic.value = chunk
                        @Suppress("DEPRECATION")
                        gatt.writeCharacteristic(characteristic)
                    }
                    Thread.sleep(15) // Give the radio buffer time to clear
                    offset += length
                }

                // Send EOF marker
                val eof = "||EOF||".toByteArray()
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(characteristic, eof, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = eof
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(characteristic)
                }

                Thread.sleep(400)
                gatt.disconnect()
                gatt.close()
                completeSuccessOnMain()
            }.start()
          } else {
            gatt.disconnect()
            gatt.close()
            completeErrorOnMain("CHAR_NOT_FOUND", "Mesh characteristic not found")
          }
        } else {
          gatt.disconnect()
          gatt.close()
          completeErrorOnMain("DISCOVERY_FAILED", "Failed to discover services")
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
