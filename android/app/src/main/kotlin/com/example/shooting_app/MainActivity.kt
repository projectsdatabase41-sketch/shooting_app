package com.example.shooting_app

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

// FragmentActivity нужна биометрическому входу (local_auth).
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestHighRefreshRate()
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
}
