import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:studyorbit/services/hosted_ai.dart';

void main() {
  final origin = Uri.parse('http://127.0.0.1:8787');
  Map<String, dynamic> session({bool authenticated = true, bool configured = true, int remaining = 20}) => {
    'authenticated': authenticated, 'configured': configured, 'requiresInvite': true,
    'provider': 'provider.invalid', 'model': 'test-model', 'remaining': remaining,
    'dailyLimit': 20, if (authenticated) 'csrfToken': List.filled(64, 'a').join(),
  };
  http.Response json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json'});

  test('missing consent and unsupported operations never contact service', () async {
    var calls = 0;
    final gateway = HostedAiGateway(origin: origin, client: MockClient((_) async {
      calls++; return json(session());
    }));
    addTearDown(gateway.close);
    await expectLater(gateway.send('extract', {}, consent: false), throwsA(isA<HostedAiException>()));
    await expectLater(gateway.send('chat', {}, consent: true), throwsA(isA<HostedAiException>()));
    expect(calls, 0);
  });

  for (final state in ['anonymous', 'unconfigured', 'exhausted']) {
    test('$state prevents AI dispatch', () async {
      var calls = 0;
      final gateway = HostedAiGateway(origin: origin, client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/api/session');
        return json(session(authenticated: state != 'anonymous',
          configured: state != 'unconfigured', remaining: state == 'exhausted' ? 0 : 20));
      }));
      addTearDown(gateway.close);
      await expectLater(gateway.send('extract', {}, consent: true), throwsA(isA<HostedAiException>()));
      expect(calls, 1);
    });
  }

  for (final status in [401, 403, 429, 502, 503, 504]) {
    test('HTTP $status never reflects private server error bodies', () async {
      final gateway = HostedAiGateway(origin: origin, client: MockClient((_) async =>
        http.Response('private homework and provider credential', status)));
      addTearDown(gateway.close);
      final result = await gateway.status();
      expect(result.authenticated, isFalse);
      expect(result.configured, isFalse);
      expect(result.error, isNot(contains('private homework')));
      expect(result.error, isNot(contains('credential')));
      expect(gateway.unavailableReason, result.error);
    });
  }

  test('redirects are refused without replay or retry', () async {
    var calls = 0;
    final gateway = HostedAiGateway(origin: origin, client: MockClient((request) async {
      calls++;
      expect(request.followRedirects, isFalse);
      return http.Response('', 302, headers: {'location': 'https://attacker.invalid/'});
    }));
    addTearDown(gateway.close);
    expect((await gateway.status()).error, isNotNull);
    expect(calls, 1);
  });

  test('invalid session and non-JSON responses fail closed', () async {
    final gateway = HostedAiGateway(origin: origin, client: MockClient((_) async =>
      json(session()..['csrfToken'] = 'invalid')));
    addTearDown(gateway.close);
    expect((await gateway.status()).authenticated, isFalse);
    final html = HostedAiGateway(origin: origin, client: MockClient((_) async =>
      http.Response(jsonEncode(session()), 200, headers: {'content-type': 'text/html'})));
    addTearDown(html.close);
    expect((await html.status()).error, isNotNull);
  });

  test('response sizes and unsafe origins fail closed', () async {
    final large = HostedAiGateway(origin: origin, client: MockClient((_) async =>
      http.Response('x' * (512 * 1024 + 1), 200, headers: {'content-type': 'application/json'})));
    addTearDown(large.close);
    expect((await large.status()).error, isNotNull);
    var calls = 0;
    final unsafe = HostedAiGateway(origin: Uri.parse('http://public.invalid'),
      client: MockClient((_) async { calls++; return json(session()); }));
    addTearDown(unsafe.close);
    expect((await unsafe.status()).configured, isFalse);
    expect(calls, 0);
  });

  test('invite and sign-out target only session endpoint and clear session', () async {
    final requests = <http.Request>[];
    final gateway = HostedAiGateway(origin: origin, client: MockClient((request) async {
      requests.add(request);
      expect(request.url.path, '/api/session');
      if (request.method == 'POST') {
        expect(jsonDecode(request.body), {'inviteCode': 'synthetic-invite'});
        expect(request.headers['Origin'], origin.origin);
        return json(session());
      }
      expect(request.method, 'DELETE');
      expect(request.headers['X-CSRF-Token'], List.filled(64, 'a').join());
      return json(session(authenticated: false, remaining: 0));
    }));
    addTearDown(gateway.close);
    await gateway.signIn('synthetic-invite');
    await gateway.signOut();
    expect(requests.length, 2);
  });
}
