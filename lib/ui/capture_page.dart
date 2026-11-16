part of '../app.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({super.key, required this.mode, required this.deletePhotos,
    required this.store, this.reviewDrafts = false});
  final int mode;
  final bool deletePhotos;
  final StudyController store;
  final bool reviewDrafts;
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late int mode = widget.mode;
  final input = TextEditingController();
  final captureScroll = ScrollController();
  late final client = StudyAiClient(gateway: widget.store.gateway);
  final speech = const MethodChannel('si.studyorbit/offline_speech');
  bool busy = false, listening = false, stoppingSpeech = false;
  bool feedback = false, reviewed = false;
  String speechStatus = '', speechBaseText = '';
  String? speechErrorCode, error;
  Uint8List? photo;
  List<StudyTask>? drafts;
  String? capturedText, captureId;
  bool? capturedFeedback;

  @override
  void initState() {
    super.initState();
    if (widget.reviewDrafts) drafts = widget.store.drafts.toList();
    speech.setMethodCallHandler((call) async {
      if (!mounted || !listening) return;
      if (call.method == 'listening') {
        setState(() => speechStatus = 'Listening. Speak now, then tap Stop recording.');
      } else if (call.method == 'partialResult' && call.arguments is String) {
        setState(() {
          input.text = _withTranscript(call.arguments as String);
          speechStatus = 'Listening. Your words appear below.';
        });
      }
    });
  }

  void fail(String message) { if (mounted) setState(() => error = message); }
  String _withTranscript(String transcript) =>
      [speechBaseText, transcript.trim()].where((s) => s.isNotEmpty).join('\n');

  Future<void> _cancelSpeech() async {
    try { await speech.invokeMethod<void>('cancel'); } catch (_) {
      // Native capture may already have released its resources.
    }
  }

  @override
  void dispose() {
    captureScroll.dispose();
    speech.setMethodCallHandler(null);
    if (listening) unawaited(_cancelSpeech());
    client.close();
    input.dispose();
    super.dispose();
  }

  bool get mobile => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> scan(ImageSource source) async {
    if (busy) return;
    if (!mobile) { fail('Photo scanning requires an Android or iOS phone. Use text input on this platform.'); return; }
    setState(() { busy = true; error = null; });
    TextRecognizer? recognizer;
    String? path;
    try {
      final picked = await ImagePicker().pickImage(source: source, maxWidth: 2400,
          imageQuality: 90, requestFullMetadata: false);
      if (picked == null) return;
      path = picked.path;
      await retainLocalPhoto(path);
      final bytes = await picked.readAsBytes();
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final result = await recognizer.processImage(InputImage.fromFilePath(path));
      if (!mounted) return;
      setState(() { photo = bytes; input.text = result.text; });
      if (result.text.trim().isEmpty) fail('No text found. Try another photo or type your tasks.');
    } catch (_) {
      fail('Unable to scan this photo. Check camera permissions and on-device models, or use text input.');
    } finally {
      await recognizer?.close();
      if (widget.deletePhotos && path != null) {
        try { await deleteLocalPhoto(path); } catch (_) {
          fail('Unable to delete the temporary photo. Use Delete retained photo copies in My space.');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> dictate() async {
    if (listening) {
      if (stoppingSpeech) return;
      setState(() { stoppingSpeech = true; speechStatus = 'Finishing transcription…'; });
      try { await speech.invokeMethod<void>('stop'); }
      on PlatformException catch (e) { fail(e.message ?? 'Unable to stop recording. Please try again.'); await _cancelSpeech(); }
      catch (_) { fail('Unable to stop recording. Please try again.'); await _cancelSpeech(); }
      return;
    }
    if (busy) return;
    if (!mobile) { fail('Voice input requires an Android or iOS phone with on-device speech support. Use text input instead.'); return; }
    setState(() {
      busy = true; listening = true; stoppingSpeech = false;
      speechBaseText = input.text.trim();
      speechStatus = 'Preparing voice input. Allow microphone and speech access if asked.';
      speechErrorCode = null; error = null;
    });
    try {
      final result = await speech.invokeMethod<String>('recognize', {'locale': 'en-US'})
          .timeout(const Duration(seconds: 75));
      if (mounted && result != null && result.trim().isNotEmpty) {
        setState(() => input.text = _withTranscript(result));
      } else if (mounted && error == null && input.text.trim() == speechBaseText) {
        fail('No speech was recognized. Tap Start voice input and speak clearly.');
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => speechErrorCode = e.code);
      fail(e.message ?? 'On-device speech recognition is unavailable. Use text input instead.');
    } on MissingPluginException {
      fail('Voice input is not connected in this app version. Install the latest TestFlight build.');
    } on TimeoutException {
      await _cancelSpeech();
      fail('Voice input timed out. Check microphone permissions and try again.');
    } catch (_) { fail('On-device speech recognition is unavailable. Use text input instead.'); }
    finally {
      if (mounted) setState(() { busy = false; listening = false; stoppingSpeech = false; speechStatus = ''; });
    }
  }

  Future<String> saveSource(String text) async {
    if (capturedText != text || capturedFeedback != feedback) {
      captureId = const Uuid().v4();
      capturedText = text;
      capturedFeedback = feedback;
    }
    if (widget.store.evidence.any((source) => source.id == captureId)) return captureId!;
    await widget.store.saveEvidence(TextEvidence(id: captureId!, text: text,
        createdAt: DateTime.now(), feedback: feedback));
    return captureId!;
  }

  Future<void> createDrafts({bool basic = false}) async {
    if (busy) return;
    final text = input.text.trim();
    if (text.isEmpty) { fail('Enter your study tasks first.'); return; }
    setState(() { busy = true; error = null; speechErrorCode = null; });
    try {
      final id = await saveSource(text);
      if (feedback) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Feedback saved locally. It can inform a future approved AI plan; no assignments were created.')));
        }
        return;
      }
      final snapshot = widget.store.snapshot;
      List<StudyTask> result;
      if (basic) {
        result = parseDrafts(text, DateTime.now()).map((task) => task.copyWith(
            sourceCaptureId: id, sourceQuote: task.title)).toList();
      } else {
        if (!mounted || !await approveAiRequest(context, widget.store.gateway, snapshot,
            operation: 'task extraction', text: text)) {
          return;
        }
        result = await client.extractTasks(text: text, captureId: id, now: DateTime.now(),
            context: snapshot, consent: true);
      }
      await widget.store.saveDrafts(result);
      if (!mounted) return;
      setState(() { drafts = result; reviewed = false; });
      if (captureScroll.hasClients) captureScroll.jumpTo(0);
    } catch (e) {
      fail('Unable to create drafts. Your input is still here; saved source text stays local. $e');
    } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> editDraft(int index) async {
    if (busy) return;
    final edited = await showModalBottomSheet<StudyTask>(context: context,
        isScrollControlled: true, useSafeArea: true,
        builder: (_) => TaskEditor(task: drafts![index]));
    if (edited == null || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.store.saveDrafts([edited]);
      if (mounted) setState(() { drafts = [...drafts!]..[index] = edited; reviewed = false; });
    } catch (e) { fail('Unable to save draft. $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> discard(StudyTask task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.store.discardDraft(task.id);
      if (mounted) setState(() { drafts = drafts!.where((t) => t.id != task.id).toList(); reviewed = false; });
    } catch (e) { fail('Unable to remove draft. $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> confirmDrafts() async {
    if (busy || !reviewed || drafts == null || drafts!.isEmpty) return;
    setState(() => busy = true);
    try {
      await widget.store.add(drafts!);
      if (mounted) Navigator.pop(context);
    } catch (e) { fail('Unable to confirm tasks. Drafts remain saved for retry. $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Widget draftCard(int index) {
    final task = drafts![index];
    final source = widget.store.evidence.where((e) => e.id == task.sourceCaptureId).firstOrNull;
    return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(contentPadding: const EdgeInsets.all(14),
        leading: CircleAvatar(backgroundColor: const Color(0xFFEFEDFB),
            child: Text('${index + 1}', style: const TextStyle(color: violet))),
        title: Text(task.title),
        subtitle: Text('${task.subject} · ${kindName(task.kind)}\n${deadlineLabel(task)} · ${task.minutes} min estimate · ${task.remaining} min remaining'
            '${task.suggested ? '\nAI suggestion · not an assignment' : ''}'),
        onTap: busy ? null : () => editDraft(index),
        trailing: IconButton(tooltip: 'Remove draft', onPressed: busy ? null : () => discard(task), icon: const Icon(Icons.close)),
      ),
      if (task.reason.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(task.reason)),
      if (task.steps.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(task.steps.join('\n'))),
      if (task.sourceQuote.isNotEmpty || source != null)
        ExpansionTile(title: const Text('Review source text'), children: [
          Padding(padding: const EdgeInsets.all(16), child: SelectableText(
              'Quoted requirement:\n${task.sourceQuote}\n\nSaved source:\n${source?.text ?? 'No source record available'}')),
        ]),
    ]));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(drafts == null ? 'Add your study tasks' : 'Review your task drafts')),
    body: SafeArea(child: SingleChildScrollView(controller: captureScroll,
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 40), child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('CAPTURE · CONFIRM · PLAN', style: TextStyle(fontSize: 10, color: violet,
              fontWeight: FontWeight.w800, letterSpacing: 2)),
          const SizedBox(height: 12),
          Text(drafts == null ? 'Write down what you need to do.' : 'Check the details before you start.',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(drafts == null ? 'Capture locally. Choose AI extraction only when you want to share text.'
              : 'Drafts are saved locally, not scheduled. Check source requirements, subject, deadline, time and steps before confirming.',
              style: const TextStyle(color: muted, fontSize: 13)),
          const SizedBox(height: 22),
          if (drafts == null) ...[
            SegmentedButton<int>(segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.edit_note), label: Text('Text')),
              ButtonSegment(value: 1, icon: Icon(Icons.camera_alt_outlined), label: Text('Photo')),
              ButtonSegment(value: 2, icon: Icon(Icons.mic_none), label: Text('Voice')),
            ], selected: {mode}, onSelectionChanged: busy ? null : (v) => setState(() => mode = v.first)),
            const SizedBox(height: 20),
            if (mode == 1) ...[
              Wrap(spacing: 12, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: busy ? null : () => scan(ImageSource.camera), icon: const Icon(Icons.camera_alt_outlined), label: const Text('Take a photo')),
                OutlinedButton.icon(onPressed: busy ? null : () => scan(ImageSource.gallery), icon: const Icon(Icons.photo_outlined), label: const Text('Choose from library')),
              ]),
              const Text('OCR runs on device. Photos are never uploaded. Review the recognized text before choosing extraction.', style: TextStyle(fontSize: 11, color: muted)),
            ],
            if (mode == 2) ...[
              FilledButton.icon(onPressed: stoppingSpeech || busy && !listening ? null : dictate,
                  icon: Icon(listening ? Icons.stop : Icons.mic_none),
                  label: Text(stoppingSpeech ? 'Finishing…' : listening ? 'Stop recording' : 'Start voice input')),
              if (listening) Padding(padding: const EdgeInsets.only(top: 12), child: Text(speechStatus, semanticsLabel: speechStatus)),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
              if (speechErrorCode == 'permission_denied') TextButton(onPressed: () async {
                try { await speech.invokeMethod<void>('openSettings'); }
                catch (_) { fail('Open your device Settings and allow Microphone and Speech Recognition for this app.'); }
              }, child: const Text('Open Settings')),
              const SizedBox(height: 12),
              const Text('An English offline speech model must be installed. If unavailable, recognition stops without using the cloud. Audio is never uploaded. Review the transcript before choosing extraction.',
                  style: TextStyle(fontSize: 11, color: muted)),
            ],
            if (photo != null) ...[
              const SizedBox(height: 16),
              ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.memory(photo!, height: 160, width: double.infinity, fit: BoxFit.contain)),
              TextButton(onPressed: busy ? null : () => setState(() => photo = null), child: const Text('Remove photo preview')),
            ],
            const SizedBox(height: 20),
            TextField(controller: input, enabled: !busy, minLines: 7, maxLines: 14,
              decoration: const InputDecoration(labelText: 'Study tasks / Recognized text', alignLabelWithHint: true,
                hintText: 'Math exercises due tomorrow, 30 minutes\nPhysics review, 45 minutes')),
            const SizedBox(height: 12),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: feedback,
                title: const Text('This is marked work / feedback, not new assignments'),
                subtitle: const Text('Save as learning evidence without inventing homework.'),
                onChanged: busy ? null : (v) => setState(() => feedback = v)),
            if (!feedback) const Text('AI extraction asks permission each time. Basic splitting is local, one task per line; unknown deadlines stay unset and default estimates require review.',
                style: TextStyle(fontSize: 11, color: muted)),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: busy ? null : () => createDrafts(),
                icon: Icon(feedback ? Icons.save_outlined : Icons.auto_awesome_outlined),
                label: Text(feedback ? 'Save feedback locally' : 'Extract tasks with AI'))),
            if (!feedback) TextButton(onPressed: busy ? null : () => createDrafts(basic: true), child: const Text('Create basic drafts locally')),
          ] else ...[
            if (drafts!.isEmpty) const Text('No tasks to confirm. Saved evidence remains available to future approved plans.'),
            for (var i = 0; i < drafts!.length; i++) draftCard(i),
            if (drafts!.isNotEmpty) ...[
              CheckboxListTile(contentPadding: EdgeInsets.zero, value: reviewed,
                  title: const Text('I checked the source, deadlines and time estimates'),
                  onChanged: busy ? null : (v) => setState(() => reviewed = v ?? false)),
              SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: busy || !reviewed ? null : confirmDrafts,
                  icon: const Icon(Icons.check_rounded), label: Text('Confirm and add ${drafts!.length} ${drafts!.length == 1 ? 'task' : 'tasks'}'))),
            ],
            TextButton.icon(onPressed: busy ? null : () => setState(() { drafts = null; reviewed = false; }),
                icon: const Icon(Icons.arrow_back), label: const Text('Edit original text')),
          ],
          if (busy) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: LinearProgressIndicator()),
          if (error != null && (mode != 2 || drafts != null)) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
        ]),
      )))),
  );
}
