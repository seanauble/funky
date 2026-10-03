package com.jerseylovebrand.funky

import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Story-viewer screenshot detection — hand-written (no third-party plugin),
 * using a ContentObserver on the media store, since a half-maintained
 * screenshot-detection package is exactly what broke the iOS build once
 * already in this project. Best-effort: untested on a real device (no local
 * Android SDK set up yet) — iOS is this project's actively-tested platform,
 * via Codemagic/TestFlight.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var observer: ContentObserver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.funkyapp.funky/screenshot")
        channel = methodChannel

        val contentObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                if (uri?.toString()?.lowercase()?.contains("screenshot") == true) {
                    methodChannel.invokeMethod("screenshotTaken", null)
                }
            }
        }
        observer = contentObserver
        try {
            contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, contentObserver)
        } catch (e: SecurityException) {
            // No media permission yet — screenshots just won't be detected until it's granted.
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        observer?.let {
            try {
                contentResolver.unregisterContentObserver(it)
            } catch (e: Exception) {
                // Nothing to clean up.
            }
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
