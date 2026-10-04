package com.bregger.edison.meshenger

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.util.size
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Filtered discovery only; MainActivity continues to own the GATT transport. */
@SuppressLint("MissingPermission")
class NativeBleRadio(private val activity: Activity, private val serviceUuid: UUID) : EventChannel.StreamHandler {
  private val handler = Handler(Looper.getMainLooper())
  private val adapter get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
  private var events: EventChannel.EventSink? = null
  private var receiverRegistered = false
  private var scanner: BluetoothLeScanner? = null
  private var callback: ScanCallback? = null
  private var pendingStart: MethodChannel.Result? = null
  private var startTimeout: Runnable? = null
  private var closed = false

  private fun permitted(permission: String) = activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
  private fun canConnect() = Build.VERSION.SDK_INT < 31 || permitted(Manifest.permission.BLUETOOTH_CONNECT)
  private fun canScan() = Build.VERSION.SDK_INT < 31 || permitted(Manifest.permission.BLUETOOTH_SCAN)

  fun adapterState(): String {
    if (!canConnect()) return "unauthorized"
    return try {
      when (adapter?.state) {
        BluetoothAdapter.STATE_ON -> "on"
        BluetoothAdapter.STATE_OFF -> "off"
        BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
        BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
        else -> "unavailable"
      }
    } catch (_: SecurityException) { "unauthorized" }
  }

  private val receiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
      val state = adapterState()
      if (state != "on") stopScan()
      events?.success(mapOf("event" to "adapter_state", "state" to state))
    }
  }

  override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
    events = sink
    if (!receiverRegistered && !closed) {
      val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
      // Bluetooth broadcasts can originate from a privileged non-system UID.
      if (Build.VERSION.SDK_INT >= 33) {
        activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
      } else {
        @Suppress("DEPRECATION")
        activity.registerReceiver(receiver, filter)
      }
      receiverRegistered = true
    }
    events?.success(mapOf("event" to "adapter_state", "state" to adapterState()))
  }

  override fun onCancel(arguments: Any?) {
    events = null
    stopScan()
    unregisterReceiver()
  }

  private fun unregisterReceiver() {
    if (receiverRegistered) {
      activity.unregisterReceiver(receiver)
      receiverRegistered = false
    }
  }

  fun startScan(result: MethodChannel.Result) {
    stopScan()
    if (closed) {
      result.error("RADIO_CLOSED", "Radio activity was destroyed", null)
      return
    }
    if (!canConnect() || !canScan() ||
      !permitted(Manifest.permission.ACCESS_FINE_LOCATION)) {
      result.error("SCAN_UNAUTHORIZED", "Grant Nearby Devices and location permissions before scanning", null)
      return
    }
    if (adapterState() != "on") {
      result.error("ADAPTER_OFF", "Bluetooth is not enabled", null)
      return
    }
    pendingStart = result
    try {
      val activeScanner = adapter?.bluetoothLeScanner ?: error("BLE scanner unavailable")
      val activeCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, observation: ScanResult) {
          emitResults(this, listOf(observation))
        }
        override fun onBatchScanResults(observations: MutableList<ScanResult>) {
          emitResults(this, observations)
        }
        override fun onScanFailed(errorCode: Int) {
          handler.post {
            if (callback !== this) return@post
            val message = if (errorCode == SCAN_FAILED_APPLICATION_REGISTRATION_FAILED)
              "SCAN_FAILED_APPLICATION_REGISTRATION_FAILED" else "Android scan failed ($errorCode)"
            Log.e("NativeBleRadio", message)
            val start = takePendingStart()
            callback = null
            scanner = null
            // A start failure is delivered through its method result for retry;
            // failures after startup are delivered through the scan stream.
            if (start != null) start.error("SCAN_FAILED_$errorCode", message, null)
            else events?.success(mapOf("event" to "scan_error", "code" to errorCode, "message" to message))
          }
        }
      }
      scanner = activeScanner
      callback = activeCallback
      val settings = ScanSettings.Builder()
        .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
        .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        .setReportDelay(0)
      if (Build.VERSION.SDK_INT >= 26) {
        settings.setLegacy(false).setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
      }
      val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUuid)).build())
      activeScanner.startScan(filters, settings.build(), activeCallback)
      // Android has no scan-started callback. Leave a short registration window
      // so immediate onScanFailed results participate in Dart's retry loop.
      startTimeout = Runnable { takePendingStart()?.success(null) }.also { handler.postDelayed(it, 250) }
    } catch (error: Exception) {
      val start = takePendingStart()
      stopScan()
      start?.error("SCAN_START", error.message, null)
    }
  }

  private fun takePendingStart(): MethodChannel.Result? {
    startTimeout?.let(handler::removeCallbacks)
    startTimeout = null
    val result = pendingStart
    pendingStart = null
    return result
  }

  private fun emitResults(source: ScanCallback, observations: List<ScanResult>) {
    handler.post {
      if (callback !== source || closed) return@post
      try {
        val results = observations.map { observation ->
          val record = observation.scanRecord
          val manufacturers = mutableMapOf<Int, ByteArray>()
          record?.manufacturerSpecificData?.let { data ->
            for (index in 0 until data.size) manufacturers[data.keyAt(index)] = data.valueAt(index)
          }
          val ageMs = ((SystemClock.elapsedRealtimeNanos() - observation.timestampNanos) / 1_000_000L).coerceAtLeast(0L)
          mapOf(
            "mac" to observation.device.address,
            "rssi" to observation.rssi,
            "seenAtMs" to System.currentTimeMillis() - ageMs,
            "serviceUuids" to (record?.serviceUuids?.map { it.toString() } ?: emptyList<String>()),
            "manufacturerData" to manufacturers,
          )
        }
        if (results.isNotEmpty()) events?.success(mapOf("event" to "scan_results", "results" to results))
      } catch (_: SecurityException) {
        stopScan()
        events?.success(mapOf("event" to "scan_error", "code" to "UNAUTHORIZED", "message" to "BLE permission revoked"))
        events?.success(mapOf("event" to "adapter_state", "state" to "unauthorized"))
      }
    }
  }

  fun stopScan() {
    val oldCallback = callback
    val oldScanner = scanner
    callback = null
    scanner = null
    takePendingStart()?.error("SCAN_CANCELLED", "Scan was stopped before registration completed", null)
    if (oldCallback != null) {
      try { oldScanner?.stopScan(oldCallback) }
      catch (_: SecurityException) { /* Permission was revoked. */ }
      catch (_: IllegalStateException) { /* Adapter was turned off. */ }
    }
  }

  fun requestEnable(result: MethodChannel.Result) {
    try {
      if (!canConnect()) {
        result.error("ADAPTER_UNAUTHORIZED", "Nearby Devices permission is required", null)
      } else if (adapter == null) {
        result.error("ADAPTER_UNAVAILABLE", "Bluetooth is unavailable", null)
      } else {
        if (adapterState() != "on") activity.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
        result.success(null)
      }
    } catch (error: Exception) {
      result.error("ADAPTER_ENABLE", error.message, null)
    }
  }

  fun close() {
    closed = true
    events = null
    stopScan()
    unregisterReceiver()
    handler.removeCallbacksAndMessages(null)
  }
}
