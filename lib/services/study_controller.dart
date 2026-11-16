import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/local_repository.dart';
import '../domain/planner.dart';
import '../domain/study_state.dart';
import '../domain/task.dart';
import 'hosted_ai.dart';
import 'media_cleanup.dart';

/// The only mutation boundary. Candidates are immutable and become visible only
/// after a durable save. Every queued operation reads the last committed state.
class StudyController extends ChangeNotifier {
  StudyController({LocalRepository? repository, HostedAiGateway? gateway})
      : _repository = repository ?? LocalRepository(),
        gateway = gateway ?? HostedAiGateway(),
        _ownsRepository = repository == null, _ownsGateway = gateway == null;
  final LocalRepository _repository;
  final HostedAiGateway gateway;
  final bool _ownsRepository, _ownsGateway;
  StudySnapshot _snapshot = StudySnapshot();
  Future<void> _tail = Future.value();
  bool _ready = false, _blocked = false, _disposed = false;
  int _pending = 0;
  String? _error;

  StudySnapshot get snapshot => _snapshot;
  List<StudyTask> get tasks => _snapshot.tasks;
  List<StudyTask> get drafts => _snapshot.drafts;
  List<HistoryEntry> get history => _snapshot.history;
  List<TextEvidence> get evidence => _snapshot.evidence;
  List<StudyFocusRecord> get focusRecords => _snapshot.focusRecords;
  Set<String> get tomorrowSubjects => _snapshot.tomorrowSubjects;
  DateTime? get coursesDate => _snapshot.coursesDate;
  bool get deletePhotos => _snapshot.deletePhotos;
  String? get error => _error;
  bool get busy => _pending > 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _enqueue<T>(Future<T> Function() action,
      {bool needsLoad = true, bool allowBlocked = false}) {
    _pending++;
    final result = _tail.then((_) async {
      try {
        if (_blocked && !allowBlocked) {
          throw const RepositoryException('load_required',
            'Saved records could not be opened safely. Reload, restore a backup, or explicitly clear local data before editing.');
        }
        if (needsLoad && !_ready) await _loadSaved();
        return await action();
      } catch (error) {
        _error = _message(error);
        if (error is RepositoryException &&
            {'commit_uncertain', 'corrupt', 'missing_key', 'open_failed',
              'legacy_invalid', 'legacy_read'}.contains(error.code)) {
          _blocked = true;
        }
        rethrow;
      } finally {
        _pending--;
        _notify();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _notify();
    return result;
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await _repository.load();
      _snapshot = saved;
      _ready = true;
      _blocked = false;
      _error = _repository.warning;
    } catch (_) {
      _blocked = true;
      rethrow;
    }
  }

  Future<void> load() async {
    try {
      await _enqueue(_loadSaved, needsLoad: false, allowBlocked: true);
    } catch (_) {
      // Startup exposes a safe, actionable error without an unhandled future.
      // The previous in-memory snapshot, if any, remains intact and read-only.
    }
  }

  Future<void> _commit(StudySnapshot next, {bool replace = false}) async {
    // Canonicalize and validate before touching persistence, including dates.
    final candidate = StudySnapshot.fromJson(next.toJson());
    if (replace) {
      await _repository.replace(candidate);
    } else {
      await _repository.save(candidate);
    }
    _snapshot = candidate;
    _ready = true;
    _blocked = false;
    _error = _repository.warning;
  }

  Future<void> _mutate(StudySnapshot? Function() change) => _enqueue(() async {
    final candidate = change();
    if (candidate != null) await _commit(candidate);
  });

  List<HistoryEntry> _history(String message) =>
      [HistoryEntry(message, DateTime.now()), ...history].take(10000).toList();

  StudyTask _task(String id) => tasks.firstWhere((task) => task.id == id,
    orElse: () => throw const RepositoryException('task_missing',
      'This task no longer exists. Return to the task list.'));

  Set<String> effectiveTomorrowSubjects(DateTime now) =>
      coursesDate != null && sameCalendarDay(coursesDate!, calendarDayAfter(now))
          ? tomorrowSubjects : const <String>{};

  Future<void> add(List<StudyTask> items) {
    final confirmed = items.map((task) => task.copyWith(suggested: false)).toList();
    return _mutate(() {
      if (confirmed.isEmpty) return null;
      final ids = confirmed.map((task) => task.id).toSet();
      if (ids.length != confirmed.length || tasks.any((task) => ids.contains(task.id))) {
        throw const RepositoryException('duplicate_task', 'A selected task is already confirmed. Review the task list before adding it again.');
      }
      return snapshot.copyWith(tasks: [...tasks, ...confirmed],
        drafts: drafts.where((task) => !ids.contains(task.id)).toList(),
        history: _history('Added ${confirmed.length} ${confirmed.length == 1 ? 'task' : 'tasks'}'));
    });
  }

  Future<void> saveTask(StudyTask task) => _mutate(() {
    final saved = _task(task.id);
    final edited = task.copyWith(spentSeconds: saved.spentSeconds, suggested: false);
    return snapshot.copyWith(tasks: tasks.map((item) => item.id == task.id ? edited : item).toList(),
      history: _history('Edited task: ${edited.title}'));
  });

  Future<void> deleteTask(StudyTask task) => _mutate(() {
    final saved = _task(task.id);
    final advice = snapshot.adviceByDate.map((day, plan) => MapEntry(day, PlanAdvice(
      order: plan.order.where((id) => id != saved.id).toList(),
      dependencies: Map.fromEntries(plan.dependencies.entries
        .where((entry) => entry.key != saved.id)
        .map((entry) => MapEntry(entry.key, entry.value.where((id) => id != saved.id).toList()))),
      reasons: Map.fromEntries(plan.reasons.entries.where((entry) => entry.key != saved.id)),
      suggestions: plan.suggestions)));
    return snapshot.copyWith(tasks: tasks.where((item) => item.id != saved.id).toList(),
      adviceByDate: advice, history: _history('Deleted task: ${saved.title}'));
  });

  Future<void> toggle(StudyTask task) => _mutate(() {
    final saved = _task(task.id);
    return snapshot.copyWith(tasks: tasks.map((item) => item.id == saved.id
      ? item.copyWith(done: !saved.done) : item).toList(),
      history: _history('${saved.done ? 'Reopened' : 'Completed'}: ${saved.title}'));
  });

  Future<void> defer(StudyTask task) => _mutate(() {
    final saved = _task(task.id);
    return snapshot.copyWith(tasks: tasks.map((item) => item.id == saved.id
      ? item.copyWith(deferredUntil: calendarDayAfter(DateTime.now())) : item).toList(),
      history: _history('Deferred until tomorrow: ${saved.title}'));
  });

  Future<void> updateCourses(Set<String> subjects, DateTime date) {
    final selected = subjects.map(normalizeSubject).toSet();
    return _mutate(() => snapshot.copyWith(tomorrowSubjects: selected, coursesDate: dayOnly(date)));
  }

  Future<void> setDeletePhotos(bool value) =>
      _mutate(() => snapshot.copyWith(deletePhotos: value));

  // Focus records retain their deduplication ids and actual spent time. Clearing
  // the activity feed must never make a retry count a focus segment twice.
  Future<void> clearHistory() => _mutate(() => snapshot.copyWith(history: []));

  Future<void> saveEvidence(TextEvidence item) => _mutate(() {
    final existing = evidence.where((entry) => entry.id == item.id);
    if (existing.isNotEmpty) {
      if (existing.first.text != item.text || existing.first.createdAt != item.createdAt ||
          existing.first.feedback != item.feedback) {
        throw const RepositoryException('evidence_conflict', 'This capture identifier already belongs to different evidence. Capture it again.');
      }
      return null;
    }
    return snapshot.copyWith(evidence: [...evidence, item]);
  });

  /// Upsert only the supplied drafts. Other captures and edits are retained.
  Future<void> saveDrafts(List<StudyTask> items) {
    final incoming = List<StudyTask>.of(items);
    return _mutate(() {
      final updates = {for (final task in incoming) task.id: task};
      if (updates.length != incoming.length || tasks.any((task) => updates.containsKey(task.id))) {
        throw const RepositoryException('duplicate_task', 'Draft identifiers conflict with existing tasks. Review the capture before saving.');
      }
      return snapshot.copyWith(drafts: [
        ...drafts.map((task) => updates.remove(task.id) ?? task), ...updates.values]);
    });
  }

  Future<void> discardDraft(String id) => _mutate(() =>
      snapshot.copyWith(drafts: drafts.where((task) => task.id != id).toList()));

  Future<void> applyAdvice(DateTime day, PlanAdvice advice) => _mutate(() {
    final checked = PlanAdvice.fromJson(advice.toJson());
    final eligible = tasks.where((task) => !task.done && task.remainingSeconds > 0 &&
      (task.deferredUntil == null || !dayOnly(task.deferredUntil!).isAfter(dayOnly(day))))
      .map((task) => task.id).toSet();
    if (checked.order.any((id) => !eligible.contains(id)) ||
        checked.reasons.keys.any((id) => !eligible.contains(id)) ||
        checked.dependencies.entries.any((entry) => !eligible.contains(entry.key) ||
          entry.value.any((id) => !eligible.contains(id)))) {
      throw const RepositoryException('advice_stale',
        'Tasks changed while advice was being prepared. Request a new plan before applying it.');
    }
    final fingerprints = [...tasks, ...drafts].map(_fingerprint).toSet();
    final ids = [...tasks, ...drafts].map((task) => task.id).toSet();
    final suggestions = <StudyTask>[];
    for (final item in checked.suggestions) {
      if (!fingerprints.add(_fingerprint(item))) continue;
      if (!ids.add(item.id)) {
        throw const RepositoryException('suggestion_conflict', 'A suggested task identifier conflicts with saved work. Request advice again.');
      }
      suggestions.add(item.copyWith(suggested: true, done: false, spentSeconds: 0));
    }
    return snapshot.copyWith(adviceByDate: {...snapshot.adviceByDate,
      calendarDateKey(day): checked}, drafts: [...drafts, ...suggestions]);
  });

  EveningPlan planFor(DateTime day, {DateTime? from}) {
    final advice = snapshot.adviceByDate[calendarDateKey(day)];
    return Planner().generate(tasks, day, from: from,
      tomorrowSubjects: effectiveTomorrowSubjects(day), order: advice?.order ?? const [],
      dependencies: advice?.dependencies ?? const {}, reasons: advice?.reasons ?? const {});
  }

  Future<void> recordFocus({required String recordId, required String taskId,
    required int seconds, required DateTime startedAt, required DateTime endedAt}) => _mutate(() {
    final previous = focusRecords.where((record) => record.id == recordId);
    if (previous.isNotEmpty) {
      final saved = previous.first;
      if (saved.taskId != taskId || saved.focusedSeconds != seconds ||
          saved.startedAt != startedAt || saved.endedAt != endedAt) {
        throw const RepositoryException('focus_conflict',
          'This focus segment was already saved with different values. Do not reuse its identifier.');
      }
      return null;
    }
    final task = _task(taskId);
    final record = StudyFocusRecord.fromJson(StudyFocusRecord(id: recordId,
      taskId: taskId, taskTitle: task.title, subject: task.subject,
      startedAt: startedAt, endedAt: endedAt, focusedSeconds: seconds).toJson());
    return snapshot.copyWith(tasks: tasks.map((item) => item.id == taskId
      ? item.copyWith(spentSeconds: item.spentSeconds + seconds,
          remainingSeconds: max(0, item.remainingSeconds - seconds)) : item).toList(),
      focusRecords: [...focusRecords, record],
      history: _history('Focused for ${seconds ~/ 60} min ${seconds % 60} sec: ${task.title}'));
  });

  Future<Uint8List> exportBackup(String password) =>
      _enqueue(() => _repository.exportBackup(snapshot, password));
  Future<StudySnapshot> previewBackup(Uint8List bytes, String password) =>
      _enqueue(() => _repository.importBackup(bytes, password),
        needsLoad: false, allowBlocked: true);
  Future<void> restoreBackup(StudySnapshot restored) =>
      _enqueue(() => _commit(restored, replace: true), needsLoad: false, allowBlocked: true);

  Future<void> clear() => _enqueue(() async {
    final warnings = <String>[];
    // Local erasure is never conditional on an available network session.
    try {
      await gateway.signOut();
    } catch (_) {
      warnings.add('Local data was cleared, but the hosted session could not be ended. Reconnect and end the session before sharing this browser or device.');
    }
    Object? deletionError;
    try {
      await _repository.deleteAll();
    } catch (error) {
      deletionError = error;
    }
    try {
      await clearRetainedPhotos();
    } catch (_) {
      warnings.add('Some retained photos could not be removed. Retry clearing local data.');
    }
    if (deletionError != null) throw deletionError;
    _snapshot = StudySnapshot();
    _ready = true;
    _blocked = false;
    _error = warnings.isEmpty ? null : warnings.join(' ');
  }, needsLoad: false, allowBlocked: true);

  Future<void> sample() {
    final now = DateTime.now();
    final due = calendarDayAfter(now);
    return add([
      StudyTask(id: '${now.microsecondsSinceEpoch}-a',
        title: 'Quadratic functions · Practice and corrections', subject: 'Math',
        due: due, minutes: 45, weak: true, difficulty: 3,
        steps: ['Correct mistakes from today\'s quiz', 'Complete exercises 1–8', 'Review common mistakes']),
      StudyTask(id: '${now.microsecondsSinceEpoch}-b',
        title: 'Read chapter 3 of The Great Gatsby', subject: 'English',
        due: due, minutes: 30, kind: TaskKind.preview),
      StudyTask(id: '${now.microsecondsSinceEpoch}-c',
        title: 'Force and motion · Exam review', subject: 'Physics',
        due: calendarDayAfter(now, 2), minutes: 60, kind: TaskKind.exam,
        difficulty: 3, steps: ['Review formulas', 'Practice example problems', 'Review mistakes']),
    ]);
  }

  static String _fingerprint(StudyTask task) =>
      '${normalizeSubject(task.subject).toLowerCase()}|${task.kind.name}|'
      '${task.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}|'
      '${task.due == null ? '' : calendarDateKey(task.due!)}';

  static String _message(Object error) => error is RepositoryException
      ? error.message : 'The change could not be saved. Your previous records are unchanged. Check device storage and try again.';

  @override
  void dispose() {
    _disposed = true;
    if (_ownsGateway) gateway.close();
    if (_ownsRepository) unawaited(_tail.then((_) => _repository.close()).catchError((Object _) {}));
    super.dispose();
  }
}
