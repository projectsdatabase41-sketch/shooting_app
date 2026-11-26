package com.example.shooting_app

import android.os.Build
import android.os.Bundle
import android.view.WindowManager

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity нужна биометрическому входу (local_auth).
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestHighRefreshRate()
    }

    /// Канал «мягкая клавиатура» (отзыв 26.11: в 3D-вьюере клавиатура
    /// дёргала WebView). На время экрана 3D включаем ADJUST_NOTHING — окно
    /// не меняет размер, WebView не перерисовывает сцену; при выходе
    /// возвращаем обычное поведение.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nexus/secure")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        setSecure(call.argument<Boolean>("on") == true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nexus/soft_input")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setMode" -> {
                        val nothing = call.argument<String>("mode") == "nothing"
                        window.setSoftInputMode(
                            if (nothing) WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
                            else WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Просит у системы самую высокую частоту обновления экрана (90/120 Гц), с тем же разрешением:
    /// без запроса Android часто держит приложения на 60 Гц. Не получилось — остаётся как было.
    private fun requestHighRefreshRate() {
        try {
            val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else null
            @Suppress("DEPRECATION")
            val d = display ?: windowManager.defaultDisplay
            val current = d.mode
            val best = d.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .maxByOrNull { it.refreshRate } ?: return
            if (best.refreshRate > current.refreshRate) {
                val attrs = window.attributes
                attrs.preferredDisplayModeId = best.modeId
                window.attributes = attrs
            }
        } catch (_: Throwable) {
        }
    }

    /// Запрет скриншотов для личных экранов (переписка, безопасность).
    /// Экран сам просит включить/выключить через канал nexus/secure.
    private fun setSecure(on: Boolean) {
        if (on) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}
