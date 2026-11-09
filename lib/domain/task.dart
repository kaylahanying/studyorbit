enum TaskKind { homework, exam, review, preview }

class StudyTask {
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
    this.steps = const [],
    this.deferredUntil,
  });
  final String id;
  String title, subject;
  DateTime due;
  int minutes, difficulty, spentSeconds;
  TaskKind kind;
  bool weak, done;
  List<String> steps;
  DateTime? deferredUntil;
  int get remaining => (minutes - spentSeconds ~/ 60).clamp(0, minutes);
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'subject': subject,
    'due': due.toIso8601String(),
    'minutes': minutes,
    'kind': kind.index,
    'difficulty': difficulty,
    'weak': weak,
    'done': done,
    'spentSeconds': spentSeconds,
    'steps': steps,
    'deferredUntil': deferredUntil?.toIso8601String(),
  };
  factory StudyTask.fromJson(Map<String, dynamic> j) => StudyTask(
    id: j['id'] as String,
    title: j['title'] as String,
    subject: normalizeSubject(j['subject'] as String),
    due: DateTime.parse(j['due'] as String),
    minutes: j['minutes'] as int,
    kind: TaskKind.values[j['kind'] as int],
    difficulty: j['difficulty'] as int,
    weak: j['weak'] as bool,
    done: j['done'] as bool,
    spentSeconds: j['spentSeconds'] as int,
    steps: List<String>.from(j['steps'] as List),
    deferredUntil: j['deferredUntil'] == null
        ? null
        : DateTime.parse(j['deferredUntil'] as String),
  );
}

class HistoryEntry {
  HistoryEntry(this.message, this.time);
  final String message;
  final DateTime time;
  Map<String, dynamic> toJson() => {
    'message': message,
    'time': time.toIso8601String(),
  };
  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    englishHistoryMessage(j['message'] as String),
    DateTime.parse(j['time'] as String),
  );
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
String clockTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
