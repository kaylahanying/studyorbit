part of '../app.dart';

class FocusPage extends StatefulWidget {
  const FocusPage({super.key, required this.task, required this.store, this.minutes, this.now});
  final StudyTask task;
  final StudyController store;
  final int? minutes;
  final DateTime Function()? now;
  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> with WidgetsBindingObserver {
  Timer? timer;
  DateTime? started, segmentStarted;
  int accumulated = 0, recorded = 0;
  bool running = false, breakMode = false, leaving = false;
  Future<bool>? saveInFlight;
  String? saveError;
  StudyFocusRecord? pending;
  final checked = <int>{};
  late final int targetSeconds = math.min(widget.minutes ?? 25,
      math.max(1, widget.task.remaining)) * 60;
  DateTime clock() => widget.now?.call() ?? DateTime.now();
  bool get saving => saveInFlight != null || leaving;
  int get elapsed => accumulated + (running && started != null
      ? math.max(0, clock().difference(started!).inSeconds) : 0);
  int get target => breakMode ? 5 * 60 : targetSeconds;
  int get left => (target - elapsed).clamp(0, target);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (running && left == 0) {
        pause();
        unawaited(persist());
        unawaited(SystemSound.play(SystemSoundType.alert));
        showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: Text(breakMode ? 'Break finished' : 'Focus session finished'),
          content: Text(breakMode ? 'Return to your study plan when you are ready.'
              : 'Look away, drink some water, and take a five-minute break. Your task is not automatically marked complete.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
        ));
      }
      setState(() {});
    });
  }

  void pause() {
    if (!running) return;
    accumulated = elapsed;
    running = false;
    started = null;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { pause(); unawaited(persist()); }
  }

  Future<bool> persist() {
    final active = saveInFlight;
    if (active != null) return active;
    if (breakMode || elapsed <= recorded) return Future.value(true);
    final end = clock();
    pending ??= StudyFocusRecord(id: const Uuid().v4(), taskId: widget.task.id,
        taskTitle: widget.task.title, subject: widget.task.subject,
        startedAt: segmentStarted ?? end.subtract(Duration(seconds: elapsed - recorded)),
        endedAt: end, focusedSeconds: elapsed - recorded);
    final operation = Future<bool>.microtask(savePending);
    saveInFlight = operation;
    if (mounted) setState(() {});
    return operation;
  }

  Future<bool> savePending() async {
    final record = pending!;
    try {
      await widget.store.recordFocus(recordId: record.id, taskId: record.taskId,
          seconds: record.focusedSeconds, startedAt: record.startedAt, endedAt: record.endedAt);
      recorded += record.focusedSeconds;
      pending = null;
      segmentStarted = null;
      saveError = null;
      return true;
    } catch (e) {
      saveError = 'Unable to save your study record. Retry before leaving. $e';
      return false;
    } finally {
      saveInFlight = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> leave({bool complete = false}) async {
    if (leaving) return;
    setState(() => leaving = true);
    pause();
    try {
      if (!await persist()) return;
      if (complete) {
        final latest = widget.store.tasks.where((t) => t.id == widget.task.id).firstOrNull;
        if (latest != null && !latest.done) await widget.store.toggle(latest);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => saveError = 'Unable to save. Please retry. $e');
    } finally { if (mounted) setState(() => leaving = false); }
  }

  Future<void> switchMode() async {
    if (saving) return;
    pause();
    if (!await persist() || !mounted) return;
    setState(() {
      breakMode = !breakMode;
      accumulated = 0;
      recorded = 0;
      segmentStarted = null;
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) { if (!didPop && !leaving) unawaited(leave()); },
    child: Scaffold(
      appBar: AppBar(leading: IconButton(tooltip: 'Save and go back', onPressed: leaving ? null : leave,
          icon: const Icon(Icons.arrow_back)), title: const Text('Focus mode')),
      body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
          child: Column(children: [
            const SizedBox(height: 24),
            Text(breakMode ? 'Give your mind a break' : 'One task at a time', style: const TextStyle(color: muted, letterSpacing: 1)),
            const SizedBox(height: 14),
            Text(widget.task.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('${widget.task.subject} · ${kindName(widget.task.kind)}', style: const TextStyle(color: muted)),
            const SizedBox(height: 36),
            SizedBox(width: 250, height: 250, child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(child: CircularProgressIndicator(value: left / target, strokeWidth: 8,
                  backgroundColor: const Color(0xFFE7E4F6), color: breakMode ? const Color(0xFF79A68D) : violet, strokeCap: StrokeCap.round)),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${(left ~/ 60).toString().padLeft(2, '0')}:${(left % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 57, fontWeight: FontWeight.w300, color: ink)),
                Text(breakMode ? 'Break time' : running ? 'Getting closer to your goal' : 'Start when you are ready', style: const TextStyle(color: muted, fontSize: 12)),
              ]),
            ])),
            const SizedBox(height: 35),
            Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 12, children: [
              FilledButton.icon(onPressed: saving || left == 0 || saveError != null ? null : () {
                if (running) { pause(); unawaited(persist()); }
                else { setState(() { running = true; started = clock(); segmentStarted ??= started; }); }
              }, icon: Icon(running ? Icons.pause_rounded : Icons.play_arrow_rounded), label: Text(running ? 'Pause' : 'Start')),
              OutlinedButton(onPressed: saving ? null : switchMode,
                  child: Text(breakMode ? 'Back to studying' : 'Take a 5-minute break')),
            ]),
            if (saveError != null) ...[
              const SizedBox(height: 16),
              Text(saveError!, style: const TextStyle(color: Colors.redAccent)),
              TextButton(onPressed: saving ? null : () => persist(), child: const Text('Retry saving focus')),
            ],
            if (saveInFlight != null) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
            const SizedBox(height: 24),
            for (var i = 0; i < widget.task.steps.length; i++) CheckboxListTile(value: checked.contains(i),
                onChanged: (v) => setState(() { v == true ? checked.add(i) : checked.remove(i); }),
                title: Text(widget.task.steps[i], style: const TextStyle(fontSize: 13)),
                subtitle: const Text('Session checklist', style: TextStyle(fontSize: 10, color: muted)), controlAffinity: ListTileControlAffinity.leading),
            const SizedBox(height: 20),
            TextButton.icon(onPressed: saving || widget.task.done ? null : () => leave(complete: true),
                icon: const Icon(Icons.check_circle_outline), label: const Text('Mark task complete')),
            const SizedBox(height: 12),
            const Text('Sessions pause when you leave the app. Only actual unpaused time is recorded. Reminders work while this screen is open.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: muted)),
          ]),
        )),
      )),
    ),
  );
}
