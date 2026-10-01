package com.vrheadsetmanager.adbwifi

import android.content.Context
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Runs the bundled adb command-line client (jniLibs/arm64-v8a/libadb.so).
 *
 * HOME points to the app's private files dir, so the client's RSA key pair lives in
 * files/.android/adbkey - that is the key the headset is asked to "Always allow".
 */
class AdbClient(context: Context) {

    private val binary = File(context.applicationInfo.nativeLibraryDir, "libadb.so")
    private val home = context.filesDir
    private val tmp = context.cacheDir

    val isAvailable: Boolean get() = binary.canExecute()

    /** Runs `adb <args>` and returns its combined stdout/stderr (never throws). */
    fun run(vararg args: String, timeoutSeconds: Long = 15): String {
        return try {
            val process = ProcessBuilder(listOf(binary.absolutePath) + args)
                .directory(home)
                .redirectErrorStream(true)
                .apply {
                    environment()["HOME"] = home.absolutePath
                    environment()["TMPDIR"] = tmp.absolutePath
                }
                .start()
            // Read on a separate thread: the adb server daemon forked by the first
            // command can keep inherited pipes open, so never block on EOF here.
            val output = StringBuilder()
            val reader = Thread {
                try {
                    process.inputStream.bufferedReader().forEachLine {
                        synchronized(output) { output.appendLine(it) }
                    }
                } catch (_: Exception) { }
            }.apply { isDaemon = true; start() }
            if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
                process.destroy()
                synchronized(output) { output.appendLine("(timed out after ${timeoutSeconds}s)") }
            }
            reader.join(500)
            synchronized(output) { output.toString().trim() }
        } catch (e: Exception) {
            "error: ${e.message}"
        }
    }
}
