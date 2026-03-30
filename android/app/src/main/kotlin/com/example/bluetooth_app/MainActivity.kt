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
          startNativeServer(result)
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
  private fun startNativeServer(result: MethodChannel.Result) {
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

      val settings = AdvertiseSettings.Builder()
        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
        .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
        .setConnectable(true)
        .build()

      val data = AdvertiseData.Builder()
        .addServiceUuid(ParcelUuid(SERVICE_UUID))
        .addManufacturerData(0xFFE0, byteArrayOf(1))
        .build()

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
  private fun sendPayloadToPeer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val macAddress = call.argument<String>("macAddress")
    if (macAddress.isNullOrBlank()) {
      result.error("bad_args", "macAddress is required", null)
      return
    }

    val payloadBytes = coercePayloadBytes(call.argument<Any?>("payload"))
    if (payloadBytes == null) {
      result.error("bad_args", "payload must be a ByteArray/Uint8List", null)
      return
    }

    val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    val adapter: BluetoothAdapter = bluetoothManager.adapter
    val device = adapter.getRemoteDevice(macAddress)

    var completed = false
    fun finishSuccess() {
      if (completed) return
      completed = true
      result.success(null)
    }

    fun finishError(code: String, message: String) {
      if (completed) return
      completed = true
      result.error(code, message, null)
    }

    val gattCallback = object : BluetoothGattCallback() {
      override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
        super.onConnectionStateChange(gatt, status, newState)
        if (gatt == null) return

        if (newState == BluetoothProfile.STATE_CONNECTED) {
          val ok = gatt.requestMtu(512)
          Log.d(TAG, "requestMtu initiated: $ok")
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
          // If we disconnect before finishing write, still close and finish.
          if (!completed) {
            try {
              gatt.close()
            } catch (_: Throwable) {}
            finishSuccess()
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
          finishSuccess()
        }
      }

      override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
        super.onServicesDiscovered(gatt, status)
        if (gatt == null) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
          gatt.disconnect()
          gatt.close()
          finishSuccess()
          return
        }

        val characteristic = gatt.services
          .flatMap { it.characteristics }
          .firstOrNull { it.uuid == CHARACTERISTIC_UUID }

        if (characteristic == null) {
          gatt.disconnect()
          gatt.close()
          finishError("char_not_found", "Characteristic UUID not found on peer")
          return
        }

        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        characteristic.value = payloadBytes

        gatt.writeCharacteristic(characteristic)

        // Blind write: wait a fixed budget before disconnect.
        Handler(Looper.getMainLooper()).postDelayed({
          try {
            gatt.disconnect()
          } catch (_: Throwable) {}
          try {
            gatt.close()
          } catch (_: Throwable) {}
          finishSuccess()
        }, 400)
      }
    }

    val gatt = device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    if (gatt == null) {
      result.error("connect_failed", "connectGatt returned null", null)
      return
    }

    // Watchdog: avoid leaving the Dart Future pending forever.
    Handler(Looper.getMainLooper()).postDelayed({
      if (!completed) {
        try {
          gatt.disconnect()
        } catch (_: Throwable) {}
        try {
          gatt.close()
        } catch (_: Throwable) {}
        finishError("timeout", "Timed out waiting for MTU/services/write")
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
