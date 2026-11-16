import 'dart:convert';
import 'dart:typed_data';

import '../domain/study_state.dart';
import '../domain/task.dart';
import '../domain/validation.dart';

class RepositoryException implements Exception {
  const RepositoryException(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

class SnapshotCodec {
  static const maxPayloadBytes = 16 * 1024 * 1024;

  static Uint8List encode(StudySnapshot snapshot) {
    try {
      final json = snapshot.toJson();
      StudySnapshot.fromJson(json);
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      if (bytes.length > maxPayloadBytes) throw const FormatException();
      return bytes;
    } catch (_) {
      throw const RepositoryException('invalid_payload',
        'The study library contains invalid records or exceeds 16 MiB. Nothing was replaced.');
    }
  }

  static StudySnapshot decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxPayloadBytes) _invalid();
    try {
      final text = utf8.decode(bytes);
      checkJsonDepth(text);
      return StudySnapshot.fromJson(jsonObject(jsonDecode(text)));
    } on RepositoryException {
      rethrow;
    } catch (_) {
      _invalid();
    }
  }

  /// Only the exact original application schema can be migrated. Never salvage
  /// a partial library, silently discard a record, or invent dated courses.
  static StudySnapshot decodeLegacy(String text) {
    try {
      if (text.length > maxPayloadBytes || utf8.encode(text).length > maxPayloadBytes) {
        throw const FormatException();
      }
      checkJsonDepth(text);
      final json = jsonObject(jsonDecode(text));
      const fields = {'version', 'tasks', 'history', 'tomorrowSubjects', 'deletePhotos'};
      jsonFields(json, fields, required: fields);
      if (json['version'] != 1) throw const FormatException();
      final tasks = jsonList(json['tasks'], max: 2000).map((item) {
        final task = jsonObject(item);
        const fields = {'id', 'title', 'subject', 'due', 'minutes', 'kind',
          'difficulty', 'weak', 'done', 'spentSeconds', 'steps', 'deferredUntil'};
        jsonFields(task, fields, required: fields);
        if (task['due'] == null) throw const FormatException();
        return StudyTask.fromJson(task);
      }).toList();
      uniqueIds(tasks.map((task) => task.id));
      final subjects = jsonStrings(json['tomorrowSubjects'], max: 100, textMax: 100);
      uniqueIds(subjects);
      final snapshot = StudySnapshot(tasks: tasks,
        history: jsonList(json['history'], max: 10000)
          .map((item) => HistoryEntry.fromJson(jsonObject(item))).toList(),
        tomorrowSubjects: subjects.map(normalizeSubject).toSet(),
        deletePhotos: jsonBool(json['deletePhotos']));
      encode(snapshot);
      return snapshot;
    } catch (_) {
      throw const RepositoryException('legacy_invalid',
        'The previous local library is corrupt or unsupported. It was not migrated, deleted, or overwritten. Restore a backup or explicitly clear local data.');
    }
  }

  static void checkJsonDepth(String text) {
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final c in text.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == 92) {
          escaped = true;
        } else if (c == 34) {
          quoted = false;
        }
      } else if (c == 34) {
        quoted = true;
      } else if (c == 123 || c == 91) {
        if (++depth > 32) _invalid();
      } else if (c == 125 || c == 93) {
        if (--depth < 0) _invalid();
      }
    }
    if (quoted || depth != 0) _invalid();
  }

  static Never _invalid() => throw const RepositoryException('invalid_payload',
    'The library failed its schema or integrity check. Existing data was not changed.');
}
