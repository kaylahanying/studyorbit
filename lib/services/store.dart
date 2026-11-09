import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/task.dart';
import 'media_cleanup.dart';

class StudyStore extends ChangeNotifier {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  List<StudyTask> tasks = [];
  List<HistoryEntry> history = [];
  Set<String> tomorrowSubjects = {};
  bool deletePhotos = true;
  String? error;
  Future<void> _writes = Future.value();
  Future<void> load() async {
    try {
      final raw = await _prefs.getString('studyorbit.v1');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final loadedTasks = (j['tasks'] as List)
            .map((v) => StudyTask.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList();
        final loadedHistory = (j['history'] as List)
            .map(
              (v) => HistoryEntry.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList();
        tasks = loadedTasks;
        history = loadedHistory;
        tomorrowSubjects = Set<String>.from(j['tomorrowSubjects'] as List);
        deletePhotos = j['deletePhotos'] as bool;
      }
    } catch (_) {
      error = '本地数据读取失败。为保护已有记录，本次不会自动覆盖；请重新启动或主动清空数据。';
    }
    notifyListeners();
  }

  String encode() => jsonEncode({
    'version': 1,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'history': history.map((h) => h.toJson()).toList(),
    'tomorrowSubjects': tomorrowSubjects.toList(),
    'deletePhotos': deletePhotos,
  });
  Future<void> save([String? message]) {
    if (error != null) return Future.error(StateError(error!));
    if (message != null) {
      history.insert(0, HistoryEntry(message, DateTime.now()));
    }
    final snapshot = encode();
    notifyListeners();
    _writes = _writes
        .catchError((Object _) {})
        .then((_) => _prefs.setString('studyorbit.v1', snapshot));
    return _writes;
  }

  Future<void> clear() async {
    await _writes.catchError((Object _) {});
    await clearRetainedPhotos();
    await _prefs.remove('studyorbit.v1');
    tasks = [];
    history = [];
    tomorrowSubjects = {};
    deletePhotos = true;
    error = null;
    notifyListeners();
  }

  Future<void> add(List<StudyTask> drafts) async {
    tasks.addAll(drafts);
    await save('添加了 ${drafts.length} 个任务');
  }

  Future<void> toggle(StudyTask task) async {
    task.done = !task.done;
    await save('${task.done ? '完成' : '重新打开'}：${task.title}');
  }

  Future<void> defer(StudyTask task) async {
    task.deferredUntil = dayOnly(DateTime.now()).add(const Duration(days: 1));
    await save('延后至明天：${task.title}');
  }

  Future<void> sample() async {
    final now = DateTime.now();
    final due = dayOnly(now).add(const Duration(days: 1));
    await add([
      StudyTask(
        id: '${now.microsecondsSinceEpoch}-a',
        title: '二次函数 · 练习与订正',
        subject: '数学',
        due: due,
        minutes: 45,
        weak: true,
        difficulty: 3,
        steps: ['订正今天 quiz 的错题', '完成练习 1–8', '整理易错点'],
      ),
      StudyTask(
        id: '${now.microsecondsSinceEpoch}-b',
        title: '阅读《The Great Gatsby》第 3 章',
        subject: '英语',
        due: due,
        minutes: 30,
        kind: TaskKind.preview,
      ),
      StudyTask(
        id: '${now.microsecondsSinceEpoch}-c',
        title: '力与运动 · 考前复习',
        subject: '物理',
        due: due.add(const Duration(days: 2)),
        minutes: 60,
        kind: TaskKind.exam,
        difficulty: 3,
        steps: ['回顾公式', '练习典型题', '复盘错题'],
      ),
    ]);
  }
}
