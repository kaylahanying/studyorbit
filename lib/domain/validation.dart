// Shared, bounded JSON validation. Never coerce malformed imported records.
void jsonFields(Map<String, dynamic> value, Set<String> allowed,
    {Set<String> required = const {}}) {
  if (value.keys.any((key) => !allowed.contains(key)) ||
      required.any((key) => !value.containsKey(key))) {
    throw const FormatException('Unsupported or incomplete study record.');
  }
}

String jsonString(dynamic value, {int max = 2000, bool empty = false}) {
  if (value is! String || value.length > max || (!empty && value.trim().isEmpty)) {
    throw const FormatException('Invalid study text.');
  }
  return value;
}

int jsonInt(dynamic value, {int min = 0, int max = 315360000}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid study number.');
  }
  return value;
}

bool jsonBool(dynamic value) {
  if (value is! bool) throw const FormatException('Invalid study flag.');
  return value;
}

Map<String, dynamic> jsonObject(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid study record.');
  }
  return value;
}

List<dynamic> jsonList(dynamic value, {int max = 10000}) {
  if (value is! List || value.length > max) {
    throw const FormatException('Invalid study collection.');
  }
  return value;
}

List<String> jsonStrings(dynamic value, {int max = 100, int textMax = 2000}) =>
    jsonList(value, max: max)
        .map((item) => jsonString(item, max: textMax))
        .toList();

/// DateTime.parse normalizes impossible calendar dates; reject those instead.
DateTime jsonDate(dynamic value, {bool dateOnly = false}) {
  final text = jsonString(value, max: 40);
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})?)?$',
  ).firstMatch(text);
  if (match == null || (dateOnly && match[4] != null)) {
    throw const FormatException('Invalid study date.');
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final calendar = DateTime(year, month, day);
  if (year < 1900 || year > 2200 || calendar.month != month || calendar.day != day ||
      (match[4] != null && (int.parse(match[4]!) > 23 ||
          int.parse(match[5]!) > 59 || int.parse(match[6]!) > 59))) {
    throw const FormatException('Invalid study date.');
  }
  final zone = match[8];
  if (zone != null && zone != 'Z' &&
      (int.parse(zone.substring(1, 3)) > 23 ||
          int.parse(zone.substring(4, 6)) > 59)) {
    throw const FormatException('Invalid study timezone.');
  }
  return DateTime.parse(text);
}

void uniqueIds(Iterable<String> ids) {
  final seen = <String>{};
  if (ids.any((id) => !seen.add(id))) {
    throw const FormatException('Duplicate study identifier.');
  }
}
