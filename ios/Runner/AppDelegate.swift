import Flutter
import UIKit
import Speech
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var offlineSpeech: OfflineSpeech?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "StudyOrbitOfflineSpeech") {
      let speech = OfflineSpeech()
      offlineSpeech = speech
      let channel = FlutterMethodChannel(name: "si.studyorbit/offline_speech", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak speech] call, result in
        switch call.method {
        case "recognize": speech?.recognize(result)
        case "stop": speech?.stop(); result(nil)
        case "cancel": speech?.finish(nil); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}

/// Refuses recognition unless Apple confirms on-device support for this locale.
private final class OfflineSpeech {
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var reply: FlutterResult?
  private var recognizer: SFSpeechRecognizer?
  private var tapped = false
  private var timeout: DispatchWorkItem?
  private var observer: NSObjectProtocol?
  init() {
    observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.finish(nil) }
  }
  deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
  func recognize(_ result: @escaping FlutterResult) {
    guard reply == nil else { result(FlutterError(code: "busy", message: "Speech recognition is already running.", details: nil)); return }
    reply = result
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self = self, self.reply != nil else { return }
        guard status == .authorized else { self.fail("Speech recognition access was denied. Use text input instead."); return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard self.reply != nil else { return }
            if granted { self.start() } else { self.fail("Microphone access was denied. Use text input instead.") }
          }
        }
      }
    }
  }
  private func start() {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
      fail("English on-device recognition is unavailable. Install an offline language model or use text input."); return
    }
    self.recognizer = recognizer
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = false
      self.request = request
      let input = engine.inputNode
      input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
      tapped = true
      task = recognizer.recognitionTask(with: request) { [weak self] response, error in
        DispatchQueue.main.async {
          if let response = response, response.isFinal { self?.finish(response.bestTranscription.formattedString) }
          else if error != nil { self?.fail("On-device speech recognition failed. Try again or use text input.") }
        }
      }
      engine.prepare()
      try engine.start()
      let timeout = DispatchWorkItem { [weak self] in self?.stop() }
      self.timeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
    } catch { fail("Unable to start the microphone or on-device recognition.") }
  }
  func stop() {
    engine.stop()
    request?.endAudio()
    timeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in self?.fail("On-device recognition timed out. Use text input instead.") }
    self.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
  }
  func finish(_ value: Any?) {
    let result = reply
    reply = nil
    timeout?.cancel(); timeout = nil
    engine.stop()
    if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    request?.endAudio(); request = nil
    task?.cancel(); task = nil
    recognizer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    result?(value)
  }
  private func fail(_ message: String) { finish(FlutterError(code: "offline_speech", message: message, details: nil)) }
}
