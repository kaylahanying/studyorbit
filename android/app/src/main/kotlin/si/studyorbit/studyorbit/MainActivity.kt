package si.studyorbit.studyorbit

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), RecognitionListener {
    private var recognizer: SpeechRecognizer? = null
    private var pending: MethodChannel.Result? = null
    private var speechChannel: MethodChannel? = null
    private var lastTranscript = ""
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { finish(null, "On-device recognition timed out. Try again or use text input.") }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "si.studyorbit/offline_speech")
        speechChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "recognize" -> {
                        if (pending != null) {
                            result.error("busy", "Speech recognition is already running.", null)
                        } else if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
                            result.error("offline_unavailable", "On-device recognition requires Android 12 or later and an English offline model. Use text input instead.", null)
                        } else {
                            pending = result
                            lastTranscript = ""
                            handler.postDelayed(timeout, 60000)
                            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 842)
                            } else startOffline()
                        }
                    }
                    "stop" -> {
                        if (recognizer == null) finish(null, null) else recognizer?.stopListening()
                        result.success(null)
                    }
                    "cancel" -> { finish(null, null); result.success(null) }
                    "openSettings" -> {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
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
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            }
            recognizer?.startListening(intent)
        } catch (_: Exception) { finish(null, "Unable to start on-device recognition. Check the English offline model.") }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 842) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startOffline()
            else finish(null, "Microphone access is not allowed. Enable Microphone for this app in Settings.", "permission_denied")
        }
    }
    private fun finish(text: String?, error: String?, errorCode: String = "offline_speech") {
        val reply = pending
        pending = null
        handler.removeCallbacks(timeout)
        recognizer?.destroy()
        recognizer = null
        if (error != null) reply?.error(errorCode, error, null) else reply?.success(text)
    }
    override fun onResults(results: Bundle?) { finish(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull(), null) }
    override fun onError(error: Int) {
        if (lastTranscript.isNotBlank()) finish(lastTranscript, null)
        else finish(null, "On-device recognition failed ($error). Check the English offline model or use text input.")
    }
    override fun onReadyForSpeech(params: Bundle?) { speechChannel?.invokeMethod("listening", null) }
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onPartialResults(partialResults: Bundle?) {
        val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
        if (pending != null && !text.isNullOrBlank()) {
            lastTranscript = text
            speechChannel?.invokeMethod("partialResult", text)
        }
    }
    override fun onEvent(eventType: Int, params: Bundle?) {}
    override fun onStop() { finish(null, null); super.onStop() }
    override fun onDestroy() { finish(null, null); super.onDestroy() }
}
