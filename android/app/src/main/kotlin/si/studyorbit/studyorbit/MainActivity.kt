package si.studyorbit.studyorbit

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), RecognitionListener {
    private var recognizer: SpeechRecognizer? = null
    private var pending: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { finish(null, "设备端识别超时，请重试或使用文字输入。") }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "si.studyorbit/offline_speech")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "recognize" -> {
                        if (pending != null) {
                            result.error("busy", "语音识别正在进行。", null)
                        } else if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
                            result.error("offline_unavailable", "此设备不支持设备端识别。需要 Android 12+ 及中文离线模型，请改用文字输入。", null)
                        } else {
                            pending = result
                            handler.postDelayed(timeout, 60000)
                            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 842)
                            } else startOffline()
                        }
                    }
                    "stop" -> { recognizer?.stopListening(); result.success(null) }
                    "cancel" -> { finish(null, null); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }
    private fun startOffline() {
        if (Build.VERSION.SDK_INT < 31 || pending == null) return
        try {
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            recognizer?.setRecognitionListener(this)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            }
            recognizer?.startListening(intent)
        } catch (_: Exception) { finish(null, "无法启动设备端识别，请检查中文离线模型。") }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 842) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startOffline()
            else finish(null, "麦克风权限未获批准。请改用文字输入。")
        }
    }
    private fun finish(text: String?, error: String?) {
        val reply = pending
        pending = null
        handler.removeCallbacks(timeout)
        recognizer?.destroy()
        recognizer = null
        if (error != null) reply?.error("offline_speech", error, null) else reply?.success(text)
    }
    override fun onResults(results: Bundle?) { finish(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull(), null) }
    override fun onError(error: Int) { finish(null, "设备端识别失败（$error）。请检查中文离线模型，或改用文字输入。") }
    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onPartialResults(partialResults: Bundle?) {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
    override fun onStop() { finish(null, null); super.onStop() }
    override fun onDestroy() { finish(null, null); super.onDestroy() }
}
