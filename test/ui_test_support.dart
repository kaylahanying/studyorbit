import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:studyorbit/data/local_repository.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/services/hosted_ai.dart';
import 'package:studyorbit/services/study_controller.dart';

class MemoryStudyRepository extends LocalRepository {
  MemoryStudyRepository({StudySnapshot? initial}) : value = initial ?? StudySnapshot();
  StudySnapshot value;
  bool failWrites = false;
  StudySnapshot? imported;
  int previews = 0;
  @override
  Future<StudySnapshot> importBackup(Uint8List bytes, String password) async {
    previews++;
    if (password != 'correct password' || imported == null) {
      throw const FormatException('Incorrect password or invalid backup');
    }
    return imported!;
  }
  @override
  Future<StudySnapshot> load() async => value;
  @override
  Future<void> save(StudySnapshot snapshot) async {
    if (failWrites) throw StateError('Storage unavailable');
    value = snapshot;
  }
  @override
  Future<void> replace(StudySnapshot snapshot) => save(snapshot);
  @override
  Future<void> deleteAll() async { value = StudySnapshot(); }
  @override
  Future<void> close() async {}
}

class FakeHostedGateway extends HostedAiGateway {
  int statusCalls = 0;
  final requests = <Map<String, dynamic>>[];
  FutureOr<Map<String, dynamic>> Function(String, Map<String, dynamic>)? respond;
  @override
  Future<HostedAiStatus> status() async {
    statusCalls++;
    return const HostedAiStatus(authenticated: true, configured: true,
        requiresInvite: true, provider: 'Test provider', model: 'Test model',
        remaining: 10, dailyLimit: 10);
  }
  @override
  Future<Map<String, dynamic>> send(String operation, Map<String, dynamic> input,
      {required bool consent}) async {
    if (!consent) throw StateError('Consent missing');
    requests.add({'operation': operation, 'input': input});
    final content = respond != null
        ? await respond!(operation, input)
        : operation == 'plan'
            ? {'order': <String>[], 'dependencies': <String, dynamic>{},
                'reasons': <String, dynamic>{}, 'suggestions': <dynamic>[]}
            : {'tasks': <dynamic>[]};
    return {'choices': [
      {'finish_reason': 'stop', 'message': {'content': jsonEncode(content)}},
    ]};
  }
}

class RecordingStudyController extends StudyController {
  RecordingStudyController({required super.repository, required super.gateway});
  final attempts = <String>[];
  @override
  Future<void> recordFocus({required String recordId, required String taskId,
    required int seconds, required DateTime startedAt, required DateTime endedAt}) {
    attempts.add(recordId);
    return super.recordFocus(recordId: recordId, taskId: taskId, seconds: seconds,
        startedAt: startedAt, endedAt: endedAt);
  }
}
