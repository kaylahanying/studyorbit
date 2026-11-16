import 'validation.dart';

const _unchanged = Object();

enum TaskKind { homework, exam, review, preview }

class StudyTask {
  static const jsonFieldNames = {
    'id', 'title', 'subject', 'due', 'minutes', 'kind', 'difficulty',
    'weak', 'done', 'spentSeconds', 'remainingSeconds', 'steps',
    'deferredUntil', 'sourceCaptureId', 'sourceQuote', 'reason',
    'suggested', 'dueTimeKnown',
  };

  StudyTask({
    required this.id,
    required this.title,
    required this.subject,
    required this.due,
    required this.minutes,
    this.kind = TaskKind.homework,
    this.difficulty = 2,
    this.weak = false,
    this.done = false,
    this.spentSeconds = 0,
    int? remainingSeconds,
    List<String> steps = const [],
    this.deferredUntil,
    this.sourceCaptureId = '',
    this.sourceQuote = '',
    this.reason = '',
    this.suggested = false,
    this.dueTimeKnown = false,
  }) : remainingSeconds = remainingSeconds ?? minutes * 60,
       steps = List.unmodifiable(steps);

  final String id, title, subject;
  final DateTime? due, deferredUntil;
  final int minutes, difficulty, spentSeconds, remainingSeconds;
  final TaskKind kind;
  final bool weak, done, suggested, dueTimeKnown;
  final List<String> steps;
  final String sourceCaptureId, sourceQuote, reason;

  int get remaining => (remainingSeconds + 59) ~/ 60;

  StudyTask copyWith({
    String? id,
    String? title,
    String? subject,
    Object? due = _unchanged,
    int? minutes,
    TaskKind? kind,
    int? difficulty,
    bool? weak,
    bool? done,
    int? spentSeconds,
    int? remainingSeconds,
    List<String>? steps,
    Object? deferredUntil = _unchanged,
    String? sourceCaptureId,
    String? sourceQuote,
    String? reason,
    bool? suggested,
    bool? dueTimeKnown,
  }) => StudyTask(
    id: id ?? this.id,
    title: title ?? this.title,
    subject: subject ?? this.subject,
    due: identical(due, _unchanged) ? this.due : due as DateTime?,
    minutes: minutes ?? this.minutes,
    kind: kind ?? this.kind,
    difficulty: difficulty ?? this.difficulty,
    weak: weak ?? this.weak,
    done: done ?? this.done,
    spentSeconds: spentSeconds ?? this.spentSeconds,
    remainingSeconds: remainingSeconds ?? this.remainingSeconds,
    steps: steps ?? this.steps,
    deferredUntil: identical(deferredUntil, _unchanged)
        ? this.deferredUntil : deferredUntil as DateTime?,
    sourceCaptureId: sourceCaptureId ?? this.sourceCaptureId,
    sourceQuote: sourceQuote ?? this.sourceQuote,
    reason: reason ?? this.reason,
    suggested: suggested ?? this.suggested,
    dueTimeKnown: dueTimeKnown ?? (due == null ? false : this.dueTimeKnown),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'subject': subject,
    'due': due == null ? null : dueTimeKnown
        ? due!.toIso8601String() : calendarDateKey(due!),
    'minutes': minutes,
    'kind': kind.index,
    'difficulty': difficulty,
    'weak': weak,
    'done': done,
    'spentSeconds': spentSeconds,
    'remainingSeconds': remainingSeconds,
    'steps': steps,
    'deferredUntil': deferredUntil == null ? null : calendarDateKey(deferredUntil!),
    'sourceCaptureId': sourceCaptureId,
    'sourceQuote': sourceQuote,
    'reason': reason,
    'suggested': suggested,
    'dueTimeKnown': dueTimeKnown,
  };

  factory StudyTask.fromJson(Map<String, dynamic> j) {
    jsonFields(j, jsonFieldNames,
        required: const {'id', 'title', 'subject', 'due', 'minutes'});
    final minutes = jsonInt(j['minutes'], min: 1, max: 10080);
    dynamic field(String name, dynamic fallback) =>
        j.containsKey(name) ? j[name] : fallback;
    final spent = jsonInt(field('spentSeconds', 0));
    final dueTimeKnown = jsonBool(field('dueTimeKnown', false));
    final due = j['due'] == null ? null : jsonDate(j['due']);
    if (dueTimeKnown && (due == null || !(j['due'] as String).contains('T'))) {
      throw const FormatException('A deadline time requires a date and clock.');
    }
    return StudyTask(
      id: jsonString(j['id'], max: 200),
      title: jsonString(j['title']),
      subject: normalizeSubject(jsonString(j['subject'], max: 100)),
      due: due == null || dueTimeKnown ? due
          : jsonDate((j['due'] as String).substring(0, 10), dateOnly: true),
      minutes: minutes,
      kind: TaskKind.values[jsonInt(field('kind', 0), max: 3)],
      difficulty: jsonInt(field('difficulty', 2), min: 1, max: 5),
      weak: jsonBool(field('weak', false)),
      done: jsonBool(field('done', false)),
      spentSeconds: spent,
      remainingSeconds: j.containsKey('remainingSeconds')
          ? jsonInt(j['remainingSeconds'], max: 604800)
          : (minutes * 60 - spent).clamp(0, minutes * 60),
      steps: jsonStrings(field('steps', []), max: 100),
      deferredUntil: j['deferredUntil'] == null
          ? null : _calendarJsonDate(j['deferredUntil']),
      sourceCaptureId: jsonString(field('sourceCaptureId', ''), max: 200, empty: true),
      sourceQuote: jsonString(field('sourceQuote', ''), max: 100000, empty: true),
      reason: jsonString(field('reason', ''), max: 4000, empty: true),
      suggested: jsonBool(field('suggested', false)),
      dueTimeKnown: dueTimeKnown,
    );
  }
}

DateTime _calendarJsonDate(dynamic value) {
  jsonDate(value);
  return jsonDate((value as String).substring(0, 10), dateOnly: true);
}

class HistoryEntry {
  HistoryEntry(this.message, this.time);
  final String message;
  final DateTime time;
  Map<String, dynamic> toJson() => {
    'message': message,
    'time': time.toIso8601String(),
  };
  factory HistoryEntry.fromJson(Map<String, dynamic> j) {
    jsonFields(j, const {'message', 'time'}, required: const {'message', 'time'});
    return HistoryEntry(
      englishHistoryMessage(jsonString(j['message'], max: 4000)),
      jsonDate(j['time']),
    );
  }
}

String englishHistoryMessage(String message) {
  const prefixes = {
    '完成：': 'Completed: ',
    '重新打开：': 'Reopened: ',
    '修改任务：': 'Edited task: ',
    '删除任务：': 'Deleted task: ',
    '延后至明天：': 'Deferred until tomorrow: ',
  };
  for (final entry in prefixes.entries) {
    if (message.startsWith(entry.key)) {
      return '${entry.value}${message.substring(entry.key.length)}';
    }
  }
  final added = RegExp(r'^添加了 (\d+) 个任务$').firstMatch(message);
  if (added != null) {
    return 'Added ${added[1]} ${added[1] == '1' ? 'task' : 'tasks'}';
  }
  final focused = RegExp(
    r'^专注 (\d+) 分 (\d+) 秒：(.*)$',
    dotAll: true,
  ).firstMatch(message);
  if (focused != null) {
    return 'Focused for ${focused[1]} min ${focused[2]} sec: ${focused[3]}';
  }
  if (message == '从当前时间重新排程') return 'Replanned from the current time';
  return message;
}

String kindName(TaskKind kind) =>
    ['Homework', 'Exam', 'Review', 'Preview'][kind.index];

// Normalize labels saved by the original Chinese interface. User-entered task
// titles and steps stay intact.
String normalizeSubject(String subject) =>
    const {
      '数学': 'Math',
      '英语': 'English',
      '物理': 'Physics',
      '化学': 'Chemistry',
      '生物': 'Biology',
      '历史': 'History',
      '语文': 'Chinese',
      '其他': 'Other',
    }[subject] ??
    subject;

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime calendarDayAfter(DateTime d, [int days = 1]) =>
    DateTime(d.year, d.month, d.day + days);
bool sameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
String calendarDateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String clockTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
