import 'package:flutter/material.dart';

import 'app.dart';
import 'services/store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = StudyStore();
  await store.load();
  runApp(StudyOrbitApp(store: store));
}
