import Flutter
import UIKit
import Speech
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var offlineSpeech: OfflineSpeech?
  private var speechChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "si.studyorbit/offline_speech", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    speechChannel = channel
    let speech = OfflineSpeech(
      onTranscript: { [weak channel] text in channel?.invokeMethod("partialResult", arguments: text) },
      onListening: { [weak channel] in channel?.invokeMethod("listening", arguments: nil) }
    )
    offlineSpeech = speech
    channel.setMethodCallHandler { [weak speech] call, result in
      guard let speech = speech else {
        result(FlutterError(code: "unavailable", message: "Voice input is unavailable. Restart the app and try again.", details: nil)); return
      }
      switch call.method {
      case "recognize": speech.recognize(result)
      case "stop": speech.stop(); result(nil)
      case "cancel": speech.finish(nil); result(nil)
      case "openSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Refuses recognition unless Apple confirms on-device support for this locale.
private final class OfflineSpeech {
  private var engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var reply: FlutterResult?
  private var recognizer: SFSpeechRecognizer?
  private var tapped = false
  private var timeout: DispatchWorkItem?
  private var observer: NSObjectProtocol?
  private var sessionID: UUID?
  private var lastTranscript = ""
  private let onTranscript: (String) -> Void
  private let onListening: () -> Void
  init(onTranscript: @escaping (String) -> Void, onListening: @escaping () -> Void) {
    self.onTranscript = onTranscript
    self.onListening = onListening
    observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.finish(nil) }
  }
  deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
  func recognize(_ result: @escaping FlutterResult) {
    guard reply == nil else { result(FlutterError(code: "busy", message: "Speech recognition is already running.", details: nil)); return }
    reply = result
    let id = UUID()
    sessionID = id
    lastTranscript = ""
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self = self, self.sessionID == id else { return }
        guard status == .authorized else {
          self.fail("Speech recognition is not allowed. Enable Speech Recognition for this app in Settings.", code: "permission_denied"); return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard self.sessionID == id else { return }
            if granted { self.start(id) } else { self.fail("Microphone access is not allowed. Enable Microphone for this app in Settings.", code: "permission_denied") }
          }
        }
      }
    }
  }
  private func start(_ id: UUID) {
    // Prefer an installed English locale, including the device's regional model.
    var locales = [Locale.current.identifier, "en-US", "en-GB"]
    locales = locales.filter { Locale(identifier: $0).languageCode == "en" }
    guard let recognizer = locales.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }).first(where: { $0.supportsOnDeviceRecognition }) else {
      fail("An English on-device speech model is unavailable. Enable English dictation in Settings > General > Keyboard, allow its language files to download, then try again. You can also type your tasks.", code: "offline_unavailable"); return
    }
    self.recognizer = recognizer
    do {
      engine = AVAudioEngine()
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      request.taskHint = .dictation
      self.request = request
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        fail("No microphone input is available. Disconnect audio accessories and try again.", code: "microphone_unavailable"); return
      }
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
      tapped = true
      task = recognizer.recognitionTask(with: request) { [weak self] response, error in
        DispatchQueue.main.async {
          guard let self = self, self.sessionID == id else { return }
          if let response = response {
            let text = response.bestTranscription.formattedString
            if !text.isEmpty {
              self.lastTranscript = text
              self.onTranscript(text)
            }
            if response.isFinal { self.finish(text); return }
          }
          if let error = error {
            if !self.lastTranscript.isEmpty { self.finish(self.lastTranscript) }
            else { self.fail("Speech recognition failed: \(error.localizedDescription). Try again or type your tasks.") }
          }
        }
      }
      engine.prepare()
      try engine.start()
      onListening()
      let timeout = DispatchWorkItem { [weak self] in self?.stop() }
      self.timeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
    } catch { fail("Unable to start the microphone: \(error.localizedDescription). Check microphone permissions and try again.") }
  }
  func stop() {
    guard reply != nil else { return }
    guard request != nil else { finish(nil); return }
    let id = sessionID
    engine.stop()
    request?.endAudio()
    timeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.sessionID == id else { return }
      if !self.lastTranscript.isEmpty { self.finish(self.lastTranscript) }
      else { self.fail("No speech was recognized. Try again and speak clearly.") }
    }
    self.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
  }
  func finish(_ value: Any?) {
    let result = reply
    reply = nil
    sessionID = nil
    timeout?.cancel(); timeout = nil
    engine.stop()
    if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    request?.endAudio(); request = nil
    task?.cancel(); task = nil
    recognizer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    result?(value)
  }
  private func fail(_ message: String, code: String = "offline_speech") { finish(FlutterError(code: code, message: message, details: nil)) }
}
