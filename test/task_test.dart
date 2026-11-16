import 'package:flutter_test/flutter_test.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/domain/task.dart';

void main() {
  StudyTask task() => StudyTask(id: 'a', title: 'Read', subject: 'English',
    due: DateTime(2026, 11, 3), minutes: 30,
    deferredUntil: DateTime(2026, 11, 4), steps: ['Read notes']);

  test('Nullable copy fields can be cleared without changing the original', () {
    final original = task();
    final cleared = original.copyWith(due: null, deferredUntil: null);
    expect(cleared.due, isNull);
    expect(cleared.deferredUntil, isNull);
    expect(original.due, DateTime(2026, 11, 3));
    expect(original.copyWith(title: 'Edited').due, original.due);
    final timed = original.copyWith(dueTimeKnown: true);
    expect(timed.copyWith(due: null).dueTimeKnown, isFalse);
    final snapshot = StudySnapshot(coursesDate: DateTime(2026, 11, 3));
    expect(snapshot.copyWith(coursesDate: null).coursesDate, isNull);
    expect(snapshot.coursesDate, isNotNull);
  });

  test('Actual focus and remaining work are independent with ceiling minutes', () {
    final studied = task().copyWith(spentSeconds: 3600);
    expect(studied.remainingSeconds, 1800);
    expect(studied.done, isFalse);
    expect(studied.copyWith(remainingSeconds: 1).remaining, 1);
    expect(studied.copyWith(remainingSeconds: 61).remaining, 2);
    final legacy = task().toJson()..remove('remainingSeconds');
    legacy['spentSeconds'] = 65;
    final migrated = StudyTask.fromJson(legacy);
    expect(migrated.remainingSeconds, 1735);
    expect(migrated.remaining, 29);
    legacy['spentSeconds'] = 3600;
    expect(StudyTask.fromJson(legacy).remainingSeconds, 0);
    expect(StudyTask.fromJson(legacy).done, isFalse);
  });

  test('Date-only wire values preserve their written calendar date across offsets', () {
    final json = task().toJson();
    final dateOnly = StudyTask.fromJson({...json, 'due': '2026-11-03T00:00:00+08:00'});
    expect(dateOnly.due, DateTime(2026, 11, 3));
    expect(dateOnly.toJson()['due'], '2026-11-03');
    final timed = StudyTask.fromJson({...json, 'due': '2026-11-03T00:00:00+08:00',
      'dueTimeKnown': true});
    expect(timed.due!.toUtc(), DateTime.utc(2026, 11, 2, 16));
    expect(() => StudyTask.fromJson({...json, 'dueTimeKnown': true}), throwsFormatException);
  });

  test('Explicit malformed optional values are not treated as missing defaults', () {
    for (final entry in {'spentSeconds': null, 'done': null, 'weak': 'yes',
      'kind': 99, 'difficulty': 0, 'remainingSeconds': -1, 'steps': [1]}.entries) {
      expect(() => StudyTask.fromJson({...task().toJson(), entry.key: entry.value}),
        throwsFormatException);
    }
  });

  test('Calendar arithmetic handles month, year, and daylight-saving boundaries', () {
    expect(calendarDayAfter(DateTime(2026, 12, 31, 23)), DateTime(2027, 1, 1));
    expect(calendarDayAfter(DateTime(2028, 2, 28)), DateTime(2028, 2, 29));
    expect(calendarDayAfter(DateTime(2026, 3, 8)), DateTime(2026, 3, 9));
    expect(calendarDayAfter(DateTime(2026, 11, 1)), DateTime(2026, 11, 2));
  });
}
