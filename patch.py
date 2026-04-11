import sys
import filecmp

file_path = r'c:\Users\Edison\bluetooth_app\android\app\src\main\kotlin\com\example\bluetooth_app\MainActivity.kt'
with open(file_path, 'r') as f:
    text = f.read()

# ADD IMPORTS
imports = """import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback"""
old_imports = """import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback"""

if old_imports in text:
    text = text.replace(old_imports, imports)

# ADD NOTIFY UUIDS
old_uuid = """  private val CHARACTERISTIC_UUID =
    UUID.fromString("6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a")"""

new_uuid = """  private val CHARACTERISTIC_UUID =
    UUID.fromString("6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a")
  private val NOTIFY_CHARACTERISTIC_UUID =
    UUID.fromString("b9168cf8-4d57-466d-a6f6-4be440ce8025")

  private val serverNotifyLock = Object()
  @Volatile private var lastNotifyOk: Boolean? = null
  private val serverMtuMap = java.util.concurrent.ConcurrentHashMap<String, Int>()"""
if old_uuid in text:
    text = text.replace(old_uuid, new_uuid)

# ADD REPLY_PAYLOAD TO SWITCH
old_switch = """        "send_payload" -> {
          sendPayloadToPeer(call, result)
        }
        else -> result.notImplemented()"""
new_switch = """        "send_payload" -> {
          sendPayloadToPeer(call, result)
        }
        "reply_payload" -> {
          replyPayloadToPeer(call, result)
        }
        else -> result.notImplemented()"""
if old_switch in text:
    text = text.replace(old_switch, new_switch)

# ADD SERVER NOTIFY HANDLERS
old_server_handlers = """        override fun onConnectionStateChange"""
new_server_handlers = """        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
          super.onMtuChanged(device, mtu)
          Log.d(TAG, "[SERVER] onMtuChanged: mtu=$mtu for device=${device.address}")
          serverMtuMap[device.address] = mtu
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
          super.onNotificationSent(device, status)
          synchronized(serverNotifyLock) {
            lastNotifyOk = status == BluetoothGatt.GATT_SUCCESS
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
          value: ByteArray
        ) {
          super.onDescriptorWriteRequest(device, requestId, descriptor, preparedWrite, responseNeeded, offset, value)
          if (responseNeeded && bluetoothGattServer != null) {
            bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
          }
        }

        override fun onConnectionStateChange"""

if old_server_handlers in text and "onNotificationSent" not in text:
    text = text.replace(old_server_handlers, new_server_handlers)


# ADD NOTIFY CHARACTERISTIC TO SERVICE
old_service = """      val service = BluetoothGattService(
        SERVICE_UUID,
        BluetoothGattService.SERVICE_TYPE_PRIMARY
      )
      service.addCharacteristic(writeNoResponseCharacteristic)

      val added = bluetoothGattServer?.addService(service)"""

new_service = """      val notifyCharacteristic = BluetoothGattCharacteristic(
        NOTIFY_CHARACTERISTIC_UUID,
        BluetoothGattCharacteristic.PROPERTY_NOTIFY,
        BluetoothGattCharacteristic.PERMISSION_READ
      )
      
      val cccd = BluetoothGattDescriptor(
        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
      )
      notifyCharacteristic.addDescriptor(cccd)

      val service = BluetoothGattService(
        SERVICE_UUID,
        BluetoothGattService.SERVICE_TYPE_PRIMARY
      )
      service.addCharacteristic(writeNoResponseCharacteristic)
      service.addCharacteristic(notifyCharacteristic)

      val added = bluetoothGattServer?.addService(service)"""

if old_service in text:
    text = text.replace(old_service, new_service)

# NOTIFY DISCOVERY IN CLIENT
old_services = """              if (characteristic != null) {
                Thread {"""

new_services = """              if (characteristic != null) {
                val notifyChar = service?.getCharacteristic(NOTIFY_CHARACTERISTIC_UUID)
                if (notifyChar != null) {
                  g.setCharacteristicNotification(notifyChar, true)
                  val descriptor = notifyChar.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
                  if (descriptor != null) {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                      g.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    } else {
                      @Suppress("DEPRECATION")
                      descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                      @Suppress("DEPRECATION")
                      g.writeDescriptor(descriptor)
                    }
                  }
                }
                Thread {"""
if old_services in text:
    text = text.replace(old_services, new_services)


# Client EOF behavior
old_eof = """                    val eofOk = writeBlocking(eof)
                    if (!eofOk) {
                      try { g.disconnect() } catch (_: Throwable) {}
                      try { g.close() } catch (_: Throwable) {}
                      completeErrorOnMain("WRITE_FAILED", "Write EOF failed")
                      return@Thread
                    }

                    try { g.disconnect() } catch (_: Throwable) {}
                    try { g.close() } catch (_: Throwable) {}
                    completeSuccessOnMain()"""

new_eof = """                    val eofOk = writeBlocking(eof)
                    if (!eofOk) {
                      try { g.disconnect() } catch (_: Throwable) {}
                      try { g.close() } catch (_: Throwable) {}
                      completeErrorOnMain("WRITE_FAILED", "Write EOF failed")
                      return@Thread
                    }

                    // DO NOT DISCONNECT. We must keep the socket open to receive the NOTIFY Delta payload!
                    // It will disconnect in onCharacteristicChanged when EOF is received from the server.
                    // Or it will be cleaned up by transferWatchdog 60s from now.
                    completeSuccessOnMain()"""
if old_eof in text:
    text = text.replace(old_eof, new_eof)


# Client onCharacteristicChanged
old_changed = """          override fun onCharacteristicWrite("""

new_changed = """          override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
          ) {
            super.onCharacteristicChanged(g, characteristic, value)
            if (characteristic.uuid == NOTIFY_CHARACTERISTIC_UUID) {
              Handler(Looper.getMainLooper()).post {
                val payload: HashMap<String, Any> = hashMapOf("mac" to macAddress, "bytes" to value)
                eventSink?.success(payload)
              }
              if (value.contentEquals("||EOF||".toByteArray())) {
                 try { g.disconnect() } catch (_: Throwable) {}
                 try { g.close() } catch (_: Throwable) {}
              }
            }
          }

          override fun onCharacteristicChanged(
            g: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?
          ) {
            super.onCharacteristicChanged(g, characteristic)
            if (characteristic != null && g != null) {
              @Suppress("DEPRECATION")
              val value = characteristic.value ?: return
              if (characteristic.uuid == NOTIFY_CHARACTERISTIC_UUID) {
                Handler(Looper.getMainLooper()).post {
                  val payload: HashMap<String, Any> = hashMapOf("mac" to macAddress, "bytes" to value)
                  eventSink?.success(payload)
                }
                if (value.contentEquals("||EOF||".toByteArray())) {
                  try { g.disconnect() } catch (_: Throwable) {}
                  try { g.close() } catch (_: Throwable) {}
                }
              }
            }
          }

          override fun onCharacteristicWrite("""
if old_changed in text:
    text = text.replace(old_changed, new_changed)


# ADD REPLY PAYLOAD TO PEER
new_reply_payload = """
  private fun replyPayloadToPeer(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val macAddress = call.argument<String>("macAddress") ?: return result.error("no_mac", "No MAC", null)
    val payloadAny = call.argument<Any>("payload")
    val payload = coercePayloadBytes(payloadAny) ?: ByteArray(0)

    val bluetoothManager = getSystemService(android.content.Context.BLUETOOTH_SERVICE) as BluetoothManager
    val device = bluetoothManager.adapter.getRemoteDevice(macAddress)
    val server = bluetoothGattServer ?: return result.error("no_server", "Server null", null)
    val service = server.getService(SERVICE_UUID)
    val notifyChar = service?.getCharacteristic(NOTIFY_CHARACTERISTIC_UUID)
      ?: return result.error("no_char", "Notify char missing", null)

    Thread {
      try {
        val mtu = serverMtuMap[macAddress] ?: 23
        val negotiatedChunkSize = (mtu - 3).coerceIn(20, 512)

        fun writeNotifyBlocking(chunk: ByteArray): Boolean {
          synchronized(serverNotifyLock) { lastNotifyOk = null }
          val started = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, notifyChar, false, chunk)
            true
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

        var offset = 0
        Log.d(TAG, "[GATT-NOTIFY] Starting chunked notify: ${payload.size} bytes in chunks of $negotiatedChunkSize mac=$macAddress")
        while (offset < payload.size) {
          val length = minOf(negotiatedChunkSize, payload.size - offset)
          val chunk = ByteArray(length)
          System.arraycopy(payload, offset, chunk, 0, length)
          val ok = writeNotifyBlocking(chunk)
          if (!ok) {
            Log.e(TAG, "[GATT-NOTIFY] Write chunk failed at offset=$offset len=$length")
            Handler(Looper.getMainLooper()).post { result.error("WRITE_FAILED", "Notify chunk failed", null) }
            return@Thread
          }
          offset += length
        }

        val eof = "||EOF||".toByteArray()
        val eofOk = writeNotifyBlocking(eof)
        if (!eofOk) {
          Handler(Looper.getMainLooper()).post { result.error("WRITE_FAILED", "Notify EOF failed", null) }
          return@Thread
        }
        
        Handler(Looper.getMainLooper()).post { result.success(null) }
      } catch (t: Throwable) {
        Handler(Looper.getMainLooper()).post { result.error("NOTIFY_EXCEPTION", t.message ?: "Notify exception", null) }
      }
    }.start()
  }
"""

if "private fun coercePayloadBytes" in text:
    old_tail = "  private fun coercePayloadBytes"
    insert_str = new_reply_payload + "\n  private fun coercePayloadBytes"
    if "private fun replyPayloadToPeer" not in text:
        text = text.replace(old_tail, insert_str)

with open(file_path, 'w') as f:
    f.write(text)
print("Patched MainActivity.kt safely.")
