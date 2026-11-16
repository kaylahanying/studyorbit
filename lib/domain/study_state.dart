import 'task.dart';
import 'validation.dart';

export 'task.dart' show HistoryEntry;

const _unchanged = Object();

StudyTask _snapshotTask(dynamic value) {
  final json = jsonObject(value);
  jsonFields(json, StudyTask.jsonFieldNames, required: StudyTask.jsonFieldNames);
  return StudyTask.fromJson(json);
}

class TextEvidence {
  const TextEvidence({required this.id, required this.text,
    required this.createdAt, this.feedback = false});
  final String id, text;
  final DateTime createdAt;
  final bool feedback;
  Map<String, dynamic> toJson() => {
    'id': id, 'text': text, 'createdAt': createdAt.toIso8601String(),
    'feedback': feedback,
  };
  factory TextEvidence.fromJson(Map<String, dynamic> j) {
    jsonFields(j, const {'id', 'text', 'createdAt', 'feedback'},
        required: const {'id', 'text', 'createdAt', 'feedback'});
    return TextEvidence(id: jsonString(j['id'], max: 200),
      text: jsonString(j['text'], max: 100000),
      createdAt: jsonDate(j['createdAt']), feedback: jsonBool(j['feedback']));
  }
}

class StudyFocusRecord {
  const StudyFocusRecord({required this.id, required this.taskId,
    required this.taskTitle, required this.subject, required this.startedAt,
    required this.endedAt, required this.focusedSeconds});
  final String id, taskId, taskTitle, subject;
  final DateTime startedAt, endedAt;
  final int focusedSeconds;
  Map<String, dynamic> toJson() => {
    'id': id, 'taskId': taskId, 'taskTitle': taskTitle, 'subject': subject,
    'startedAt': startedAt.toIso8601String(), 'endedAt': endedAt.toIso8601String(),
    'focusedSeconds': focusedSeconds,
  };
  factory StudyFocusRecord.fromJson(Map<String, dynamic> j) {
    const fields = {'id', 'taskId', 'taskTitle', 'subject', 'startedAt',
      'endedAt', 'focusedSeconds'};
    jsonFields(j, fields, required: fields);
    final start = jsonDate(j['startedAt']);
    final end = jsonDate(j['endedAt']);
    final seconds = jsonInt(j['focusedSeconds'], max: 604800);
    if (end.isBefore(start) || seconds > end.difference(start).inSeconds) {
      throw const FormatException('Focus exceeds elapsed wall-clock time.');
    }
    return StudyFocusRecord(id: jsonString(j['id'], max: 200),
      taskId: jsonString(j['taskId'], max: 200),
      taskTitle: jsonString(j['taskTitle']), subject: jsonString(j['subject'], max: 100),
      startedAt: start, endedAt: end, focusedSeconds: seconds);
  }
}

class PlanAdvice {
  PlanAdvice({required List<String> order,
    required Map<String, List<String>> dependencies,
    required Map<String, String> reasons, required List<StudyTask> suggestions})
      : order = List.unmodifiable(order),
        dependencies = Map.unmodifiable(dependencies.map(
          (id, values) => MapEntry(id, List<String>.unmodifiable(values)))),
        reasons = Map.unmodifiable(reasons), suggestions = List.unmodifiable(suggestions);
  final List<String> order;
  final Map<String, List<String>> dependencies;
  final Map<String, String> reasons;
  final List<StudyTask> suggestions;
  Map<String, dynamic> toJson() => {
    'order': order, 'dependencies': dependencies, 'reasons': reasons,
    'suggestions': suggestions.map((task) => task.toJson()).toList(),
  };
  factory PlanAdvice.fromJson(Map<String, dynamic> j) {
    const fields = {'order', 'dependencies', 'reasons', 'suggestions'};
    jsonFields(j, fields, required: fields);
    final order = jsonStrings(j['order'], max: 2000, textMax: 200);
    uniqueIds(order);
    final rawDependencies = jsonObject(j['dependencies']);
    final rawReasons = jsonObject(j['reasons']);
    if (rawDependencies.length > 2000 || rawReasons.length > 2000) {
      throw const FormatException('Too much planning advice.');
    }
    final dependencies = <String, List<String>>{};
    var edges = 0;
    for (final entry in rawDependencies.entries) {
      final id = jsonString(entry.key, max: 200);
      final values = jsonStrings(entry.value, max: 2000, textMax: 200);
      uniqueIds(values);
      edges += values.length;
      if (values.contains(id) || edges > 20000) {
        throw const FormatException('Invalid task dependencies.');
      }
      dependencies[id] = values;
    }
    final visited = <String>{};
    final visiting = <String>{};
    void visit(String id) {
      if (visiting.contains(id)) throw const FormatException('Cyclic task dependencies.');
      if (!visited.add(id)) return;
      visiting.add(id);
      for (final prior in dependencies[id] ?? const <String>[]) {
        visit(prior);
      }
      visiting.remove(id);
    }
    for (final id in dependencies.keys) {
      visit(id);
    }
    final suggestions = jsonList(j['suggestions'], max: 200)
        .map(_snapshotTask).toList();
    uniqueIds(suggestions.map((task) => task.id));
    return PlanAdvice(order: order, dependencies: dependencies,
      reasons: rawReasons.map((id, reason) => MapEntry(
        jsonString(id, max: 200), jsonString(reason, max: 4000))),
      suggestions: suggestions);
  }
}

class StudySnapshot {
  StudySnapshot({List<StudyTask> tasks = const [], List<StudyTask> drafts = const [],
    List<HistoryEntry> history = const [], Set<String> tomorrowSubjects = const {},
    this.coursesDate, this.deletePhotos = true,
    List<TextEvidence> evidence = const [], List<StudyFocusRecord> focusRecords = const [],
    Map<String, PlanAdvice> adviceByDate = const {}})
      : tasks = List.unmodifiable(tasks), drafts = List.unmodifiable(drafts),
        history = List.unmodifiable(history), tomorrowSubjects = Set.unmodifiable(tomorrowSubjects),
        evidence = List.unmodifiable(evidence), focusRecords = List.unmodifiable(focusRecords),
        adviceByDate = Map.unmodifiable(adviceByDate);
  final List<StudyTask> tasks, drafts;
  final List<HistoryEntry> history;
  final Set<String> tomorrowSubjects;
  final DateTime? coursesDate;
  final bool deletePhotos;
  final List<TextEvidence> evidence;
  final List<StudyFocusRecord> focusRecords;
  final Map<String, PlanAdvice> adviceByDate;

  StudySnapshot copyWith({List<StudyTask>? tasks, List<StudyTask>? drafts,
    List<HistoryEntry>? history, Set<String>? tomorrowSubjects,
    Object? coursesDate = _unchanged, bool? deletePhotos,
    List<TextEvidence>? evidence, List<StudyFocusRecord>? focusRecords,
    Map<String, PlanAdvice>? adviceByDate}) => StudySnapshot(
      tasks: tasks ?? this.tasks, drafts: drafts ?? this.drafts,
      history: history ?? this.history, tomorrowSubjects: tomorrowSubjects ?? this.tomorrowSubjects,
      coursesDate: identical(coursesDate, _unchanged) ? this.coursesDate : coursesDate as DateTime?,
      deletePhotos: deletePhotos ?? this.deletePhotos, evidence: evidence ?? this.evidence,
      focusRecords: focusRecords ?? this.focusRecords, adviceByDate: adviceByDate ?? this.adviceByDate);

  Map<String, dynamic> toJson() => {
    'version': 2, 'tasks': tasks.map((task) => task.toJson()).toList(),
    'drafts': drafts.map((task) => task.toJson()).toList(),
    'history': history.map((entry) => entry.toJson()).toList(),
    'tomorrowSubjects': tomorrowSubjects.toList()..sort(),
    'coursesDate': coursesDate == null ? null : calendarDateKey(coursesDate!),
    'deletePhotos': deletePhotos, 'evidence': evidence.map((item) => item.toJson()).toList(),
    'focusRecords': focusRecords.map((record) => record.toJson()).toList(),
    'adviceByDate': adviceByDate.map((day, advice) => MapEntry(day, advice.toJson())),
  };

  factory StudySnapshot.fromJson(Map<String, dynamic> j) {
    const fields = {'version', 'tasks', 'drafts', 'history', 'tomorrowSubjects',
      'coursesDate', 'deletePhotos', 'evidence', 'focusRecords', 'adviceByDate'};
    jsonFields(j, fields, required: fields);
    if (j['version'] != 2) throw const FormatException('Unsupported study library version.');
    List<StudyTask> tasks(String name) => jsonList(j[name], max: 2000)
        .map(_snapshotTask).toList();
    final confirmed = tasks('tasks');
    final drafts = tasks('drafts');
    uniqueIds([...confirmed, ...drafts].map((task) => task.id));
    if (confirmed.any((task) => task.suggested)) {
      throw const FormatException('Unconfirmed suggestions cannot be saved as tasks.');
    }
    final subjects = jsonStrings(j['tomorrowSubjects'], max: 100, textMax: 100);
    uniqueIds(subjects);
    final evidence = jsonList(j['evidence'], max: 500)
        .map((item) => TextEvidence.fromJson(jsonObject(item))).toList();
    final focus = jsonList(j['focusRecords'], max: 10000)
        .map((item) => StudyFocusRecord.fromJson(jsonObject(item))).toList();
    uniqueIds(evidence.map((item) => item.id));
    uniqueIds(focus.map((item) => item.id));
    final focusedByTask = <String, int>{};
    for (final record in focus) {
      focusedByTask.update(record.taskId, (seconds) => seconds + record.focusedSeconds,
        ifAbsent: () => record.focusedSeconds);
    }
    if (confirmed.any((task) => (focusedByTask[task.id] ?? 0) > task.spentSeconds)) {
      throw const FormatException('Recorded focus exceeds actual task study time.');
    }
    final rawAdvice = jsonObject(j['adviceByDate']);
    if (rawAdvice.length > 400) throw const FormatException('Too many saved plans.');
    final advice = rawAdvice.map((day, item) {
      jsonDate(day, dateOnly: true);
      return MapEntry(day, PlanAdvice.fromJson(jsonObject(item)));
    });
    return StudySnapshot(tasks: confirmed, drafts: drafts,
      history: jsonList(j['history'], max: 10000)
        .map((item) => HistoryEntry.fromJson(jsonObject(item))).toList(),
      tomorrowSubjects: subjects.map(normalizeSubject).toSet(),
      coursesDate: j['coursesDate'] == null ? null : jsonDate(j['coursesDate'], dateOnly: true),
      deletePhotos: jsonBool(j['deletePhotos']), evidence: evidence,
      focusRecords: focus, adviceByDate: advice);
  }
}
