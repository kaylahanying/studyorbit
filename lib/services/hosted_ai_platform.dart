import 'package:http/http.dart' as http;

http.Client createHostedClient() => http.Client();
bool get hostedUsesBrowserCookies => false;

Uri? hostedOrigin() {
  const value = String.fromEnvironment('STUDYORBIT_API_ORIGIN');
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      !(uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              {'localhost', '127.0.0.1', '::1', '[::1]'}.contains(uri.host)))) {
    return null;
  }
  return uri.replace(path: '');
}
