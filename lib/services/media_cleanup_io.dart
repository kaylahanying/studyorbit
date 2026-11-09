import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const _photoKey = 'studyorbit.retainedPhotos';
Future<void> deleteLocalPhoto(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}

Future<void> retainLocalPhoto(String path) async {
  final prefs = SharedPreferencesAsync();
  final paths = await prefs.getStringList(_photoKey) ?? [];
  if (!paths.contains(path)) {
    paths.add(path);
    await prefs.setStringList(_photoKey, paths);
  }
}

Future<void> clearRetainedPhotos() async {
  final prefs = SharedPreferencesAsync();
  final paths = await prefs.getStringList(_photoKey) ?? [];
  final failed = <String>[];
  for (final path in paths) {
    try {
      await deleteLocalPhoto(path);
    } catch (_) {
      failed.add(path);
    }
  }
  await prefs.setStringList(_photoKey, failed);
  if (failed.isNotEmpty) {
    throw FileSystemException(
      'Unable to remove ${failed.length} temporary photos',
    );
  }
}
