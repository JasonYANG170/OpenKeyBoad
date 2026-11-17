package io.keyboardcontrol.keyboard_control

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.hardware.usb.UsbRequest
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val jobs = Executors.newSingleThreadExecutor()
    private val usb by lazy { getSystemService(Context.USB_SERVICE) as UsbManager }
    private val permissionAction by lazy { "$packageName.USB_PERMISSION" }
    private var pendingPermission: Pair<String, MethodChannel.Result>? = null
    private var port: ViaPort? = null
    private var registered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != permissionAction) return
            val (id, result) = pendingPermission ?: return
            pendingPermission = null
            val device = usb.deviceList[id]
            if (device == null || !usb.hasPermission(device)) {
                result.error("USB_PERMISSION", "USB 权限未授予或设备已拔出。", null)
            } else {
                openAsync(device, result)
            }
        }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val filter = IntentFilter(permissionAction)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        else @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(receiver, filter)
        registered = true
        MethodChannel(engine.dartExecutor.binaryMessenger, "keyboard_control/usb").setMethodCallHandler { call, result ->
            when (call.method) {
                "scan" -> result.success(usb.deviceList.values.filter(::supported).map {
                    mapOf("id" to it.deviceName, "vid" to it.vendorId, "pid" to it.productId)
                })
                "open" -> {
                    val id = call.argument<String>("id")
                    val device = id?.let { usb.deviceList[it] }
                    if (Build.VERSION.SDK_INT < 26) {
                        result.error("USB_VERSION", "USB 直连需要 Android 8 或更新版本。", null)
                    } else if (id == null || device == null || !supported(device) ||
                        device.vendorId != call.argument<Int>("vid") || device.productId != call.argument<Int>("pid")) {
                        result.error("USB_DEVICE", "键盘已断开或型号不匹配。", null)
                    } else if (usb.hasPermission(device)) {
                        openAsync(device, result)
                    } else if (pendingPermission != null) {
                        result.error("USB_PERMISSION", "正在等待另一个 USB 权限请求。", null)
                    } else {
                        pendingPermission = id to result
                        val permission = PendingIntent.getBroadcast(
                            this, 0, Intent(permissionAction).setPackage(packageName),
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                        )
                        usb.requestPermission(device, permission)
                    }
                }
                "exchange" -> runUsb(result) {
                    val bytes = call.arguments as ByteArray
                    check(bytes.size == 32) { "报告长度错误。" }
                    checkNotNull(port) { "USB 键盘已断开。" }.exchange(bytes)
                }
                "close" -> runUsb(result) { closePort(); null }
                else -> result.notImplemented()
            }
        }
    }

    private fun supported(device: UsbDevice) =
        (device.vendorId == 0xfeed && device.productId == 0x5232) ||
        (device.vendorId == 0x05ac && device.productId == 0x024f)

    private fun openAsync(device: UsbDevice, result: MethodChannel.Result) = runUsb(result) {
        closePort()
        val connection = checkNotNull(usb.openDevice(device)) { "无法打开 USB 键盘。" }
        try {
            for (index in 0 until device.interfaceCount) {
                val intf = device.getInterface(index)
                if (intf.interfaceClass != UsbConstants.USB_CLASS_HID || !hasViaDescriptor(connection, intf)) continue
                val endpoints = (0 until intf.endpointCount).map { intf.getEndpoint(it) }.filter {
                    it.type == UsbConstants.USB_ENDPOINT_XFER_INT && it.maxPacketSize >= 32
                }
                val input = endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_IN } ?: continue
                val output = endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_OUT } ?: continue
                check(connection.claimInterface(intf, true)) { "无法占用 VIA 接口。" }
                port = ViaPort(connection, intf, input, output)
                break
            }
            check(port != null) { "未发现 VIA 配置接口，请检查 QMK 固件和有线模式。" }
        } finally {
            if (port == null) connection.close()
        }
        null
    }

    private fun hasViaDescriptor(connection: UsbDeviceConnection, intf: UsbInterface): Boolean {
        val bytes = ByteArray(512)
        val length = connection.controlTransfer(0x81, 0x06, 0x2200, intf.id, bytes, bytes.size, 750)
        // The QMK Raw HID top-level collection uses usage page FF60 and usage 61.
        val prefix = byteArrayOf(0x06, 0x60, 0xff.toByte(), 0x09, 0x61, 0xa1.toByte(), 0x01)
        return (0..(length - prefix.size)).any { index ->
            prefix.indices.all { bytes[index + it] == prefix[it] }
        }
    }

    private fun closePort() {
        val current = port
        port = null
        current?.close()
    }

    private fun runUsb(result: MethodChannel.Result, block: () -> Any?) {
        jobs.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("USB_IO", error.message ?: "USB 通信失败。", null) }
            }
        }
    }

    override fun onDestroy() {
        if (registered) unregisterReceiver(receiver)
        pendingPermission = null
        jobs.execute { closePort() }
        jobs.shutdown()
        super.onDestroy()
    }
}

private class ViaPort(
    private val connection: UsbDeviceConnection,
    private val intf: UsbInterface,
    private val input: UsbEndpoint,
    private val output: UsbEndpoint,
) {
    fun exchange(bytes: ByteArray): ByteArray {
        val outgoing = ByteBuffer.allocateDirect(32)
        outgoing.put(bytes)
        outgoing.flip()
        transfer(output, outgoing)
        check(outgoing.position() == 32) { "USB 写入长度错误。" }
        val incoming = ByteBuffer.allocateDirect(input.maxPacketSize)
        transfer(input, incoming)
        check(incoming.position() == 32) { "VIA 回报长度错误。" }
        incoming.flip()
        return ByteArray(32).also { incoming.get(it) }
    }

    private fun transfer(endpoint: UsbEndpoint, buffer: ByteBuffer) {
        val request = UsbRequest()
        try {
            check(request.initialize(connection, endpoint)) { "无法初始化 USB 端点。" }
            check(request.queue(buffer)) { "USB 报告无法发送。" }
            check(connection.requestWait(1800) == request) { "VIA 报告超时。" }
        } finally {
            request.cancel()
            request.close()
        }
    }

    fun close() {
        connection.releaseInterface(intf)
        connection.close()
    }
}
