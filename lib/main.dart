import 'package:flutter/material.dart';

import 'app.dart';
import 'services/study_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = StudyController();
  await store.load();
  runApp(StudyOrbitApp(store: store));
}
