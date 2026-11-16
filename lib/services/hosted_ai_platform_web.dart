import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

http.Client createHostedClient() => BrowserClient()..withCredentials = true;
bool get hostedUsesBrowserCookies => true;
Uri? hostedOrigin() {
  final uri = Uri.base;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  return Uri.parse(uri.origin);
}
