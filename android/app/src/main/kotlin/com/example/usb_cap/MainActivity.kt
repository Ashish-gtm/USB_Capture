package com.example.usb_cap

import android.content.Context
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "usb_capture_viewer/uvc_formats"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "listFormats") {
                val deviceName = call.argument<String>("deviceName")
                try {
                    result.success(readFormats(deviceName))
                } catch (e: Exception) {
                    result.error("UVC_DESCRIPTOR_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun readFormats(deviceName: String?): List<Map<String, Any>> {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device: UsbDevice = manager.deviceList.values.firstOrNull { it.deviceName == deviceName }
            ?: throw IllegalStateException("USB device not found: $deviceName")

        val connection = manager.openDevice(device)
            ?: throw IllegalStateException("Could not open USB device (permission missing?)")

        val raw: ByteArray
        try {
            raw = connection.rawDescriptors ?: throw IllegalStateException("No descriptors returned")
        } finally {
            connection.close()
        }

        return parseUvcFrames(raw)
    }

    // Walks the raw USB configuration descriptor and pulls out every
    // VS_FRAME_UNCOMPRESSED (0x07) and VS_FRAME_MJPEG (0x05) block,
    // per the USB Video Class 1.1 spec. Both share the same byte layout.
    private fun parseUvcFrames(raw: ByteArray): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        var offset = 0
        while (offset + 2 <= raw.size) {
            val length = raw[offset].toInt() and 0xFF
            if (length < 2) break
            val descriptorType = raw[offset + 1].toInt() and 0xFF
            if (offset + length > raw.size) break

            if (descriptorType == 0x24 && length >= 26) { // CS_INTERFACE
                val subtype = raw[offset + 2].toInt() and 0xFF
                if (subtype == 0x07 || subtype == 0x05) { // uncompressed / MJPEG frame
                    val format = if (subtype == 0x05) "MJPEG" else "Uncompressed"
                    val width = readU16(raw, offset + 5)
                    val height = readU16(raw, offset + 7)
                    val frameIntervalType = raw[offset + 25].toInt() and 0xFF
                    val fpsList = mutableListOf<Double>()

                    if (frameIntervalType == 0) {
                        if (offset + 38 <= raw.size) {
                            val minInterval = readU32(raw, offset + 26)
                            val maxInterval = readU32(raw, offset + 30)
                            if (minInterval > 0) fpsList.add(10_000_000.0 / minInterval)
                            if (maxInterval > 0 && maxInterval != minInterval) fpsList.add(10_000_000.0 / maxInterval)
                        }
                    } else {
                        var p = offset + 26
                        for (i in 0 until frameIntervalType) {
                            if (p + 4 > raw.size) break
                            val interval = readU32(raw, p)
                            if (interval > 0) fpsList.add(10_000_000.0 / interval)
                            p += 4
                        }
                    }

                    out.add(
                        mapOf(
                            "format" to format,
                            "width" to width,
                            "height" to height,
                            "fps" to fpsList.map { Math.round(it * 100.0) / 100.0 }
                        )
                    )
                }
            }
            offset += length
        }
        return out
    }

    private fun readU16(data: ByteArray, offset: Int): Int {
        return (data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun readU32(data: ByteArray, offset: Int): Long {
        return (data[offset].toLong() and 0xFF) or
            ((data[offset + 1].toLong() and 0xFF) shl 8) or
            ((data[offset + 2].toLong() and 0xFF) shl 16) or
            ((data[offset + 3].toLong() and 0xFF) shl 24)
    }
}
