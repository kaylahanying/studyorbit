import 'package:flutter_test/flutter_test.dart';
import 'package:studyorbit/domain/task.dart';
import 'package:studyorbit/domain/planner.dart';
import 'package:studyorbit/domain/parser.dart';

void main() {
  final day = DateTime(2026, 11, 2);
  StudyTask task(String id, int minutes, {int due = 1, bool weak = false}) =>
      StudyTask(
        id: id,
        title: id,
        subject: 'Math',
        due: day.add(Duration(days: due)),
        minutes: minutes,
        weak: weak,
      );
  test('Evening stays contiguous in bounds, reserves dinner and leisure, and accounts for overflow', () {
    final tasks = [task('a', 600), task('b', 200)];
    final plan = Planner().generate(tasks, day);
    expect(plan.blocks.first.start, DateTime(2026, 11, 2, 16));
    expect(plan.blocks.last.end, DateTime(2026, 11, 2, 21));
    for (var i = 0; i < plan.blocks.length; i++) {
      final b = plan.blocks[i];
      expect(b.minutes, greaterThan(0));
      if (b.taskId != null) expect(b.minutes, lessThanOrEqualTo(45));
      if (i > 0) expect(b.start, plan.blocks[i - 1].end);
    }
    expect(plan.blocks.singleWhere((b) => b.title == 'Dinner').minutes, 30);
    expect(plan.blocks.singleWhere((b) => b.title == 'Free time').minutes, 20);
    final scheduled = plan.blocks
        .where((b) => b.taskId != null)
        .fold<int>(0, (a, b) => a + b.minutes);
    expect(
      scheduled + plan.unscheduledMinutes.values.fold<int>(0, (a, b) => a + b),
      800,
    );
  });
  test('Urgent deadlines outrank distant tasks and weak subjects win equal deadlines', () {
    final plan = Planner().generate([
      task('far', 30, due: 10, weak: true),
      task('normal', 30),
      task('weak', 30, weak: true),
      task('today', 30, due: 0),
    ], day);
    expect(
      plan.blocks
          .where((b) => b.taskId != null)
          .map((b) => b.taskId)
          .toSet()
          .take(3),
      ['today', 'weak', 'normal'],
    );
  });
  test('Completed and deferred tasks do not enter tonight; recorded study reduces duration', () {
    final complete = task('done', 30)..done = true;
    final deferred = task('later', 30)
      ..deferredUntil = day.add(const Duration(days: 1));
    final active = task('active', 30)..spentSeconds = 600;
    final plan = Planner().generate([complete, deferred, active], day);
    expect(
      plan.blocks.where((b) => b.taskId != null).map((b) => b.taskId).toSet(),
      {'active'},
    );
    expect(
      plan.blocks
          .where((b) => b.taskId == 'active')
          .fold<int>(0, (a, b) => a + b.minutes),
      20,
    );
  });
  test('Replanning during dinner preserves remaining dinner and never schedules in the past', () {
    final from = DateTime(2026, 11, 2, 18, 15);
    final plan = Planner().generate([task('a', 120)], day, from: from);
    expect(plan.blocks.first.start, from);
    expect(plan.blocks.first.title, 'Dinner');
    expect(plan.blocks.first.minutes, 15);
    expect(plan.blocks.every((b) => !b.start.isBefore(from)), isTrue);
  });
  test('After 21:00 all unfinished minutes are reported', () {
    final plan = Planner().generate(
      [task('a', 70)],
      day,
      from: DateTime(2026, 11, 2, 22),
    );
    expect(plan.blocks, isEmpty);
    expect(plan.unscheduledMinutes, {'a': 70});
  });
  test('Tomorrow courses influence equal priority tasks', () {
    final english = task('eng', 30)..subject = 'English';
    final math = task('math', 30);
    final plan = Planner().generate(
      [math, english],
      day,
      tomorrowSubjects: {'English'},
    );
    expect(plan.blocks.first.taskId, 'eng');
  });
  test('Draft extraction recognizes dates, types and minutes, and keeps duplicate IDs unique', () {
    final drafts = parseDrafts('数学 今天订正 45分钟\n物理 后天考试 90分钟\n英语 预习\n英语 预习', day);
    expect(drafts.length, 4);
    expect(drafts[0].due, day);
    expect(drafts[0].minutes, 45);
    expect(drafts[0].kind, TaskKind.review);
    expect(drafts[1].due, day.add(const Duration(days: 2)));
    expect(drafts[1].steps, isNotEmpty);
    expect(drafts[2].kind, TaskKind.preview);
    expect(drafts[2].minutes, 30);
    expect(drafts.map((t) => t.id).toSet().length, 4);
  });

  test(
    'English task input recognizes relative dates, subjects and task types',
    () {
      final drafts = parseDrafts(
        'Math review today, 45 mins\n'
        'Physics exam the day after tomorrow, 90 minutes\n'
        'English preview tomorrow, 20 min\n'
        'Chemistry corrections 11/5, 30 minutes',
        day,
      );
      expect(drafts.map((t) => t.subject), [
        'Math',
        'Physics',
        'English',
        'Chemistry',
      ]);
      expect(drafts.map((t) => t.kind), [
        TaskKind.review,
        TaskKind.exam,
        TaskKind.preview,
        TaskKind.review,
      ]);
      expect(drafts.map((t) => t.due), [
        day,
        day.add(const Duration(days: 2)),
        day.add(const Duration(days: 1)),
        DateTime(2026, 11, 5),
      ]);
      expect(drafts.map((t) => t.minutes), [45, 90, 20, 30]);
      expect(drafts[1].steps.first, 'Gather instructions and materials');
    },
  );
}
