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
    subject: j['subject'] as String,
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
  factory HistoryEntry.fromJson(Map<String, dynamic> j) =>
      HistoryEntry(j['message'] as String, DateTime.parse(j['time'] as String));
}

String kindName(TaskKind kind) => ['作业', '考试', '复习', '预习'][kind.index];
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String clockTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
