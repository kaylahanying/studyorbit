import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hosted_ai_platform.dart'
    if (dart.library.js_interop) 'hosted_ai_platform_web.dart'
    as platform;

class HostedAiException implements Exception {
  const HostedAiException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class HostedAiStatus {
  const HostedAiStatus({
    required this.authenticated,
    required this.configured,
    required this.requiresInvite,
    required this.provider,
    required this.model,
    required this.remaining,
    required this.dailyLimit,
    this.error,
  });
  final bool authenticated;
  final bool configured;
  final bool requiresInvite;
  final String provider;
  final String model;
  final int remaining;
  final int dailyLimit;
  final String? error;
}

/// Same-origin hosted study operations. No provider key or prompt lives here.
class HostedAiGateway {
  HostedAiGateway({http.Client? client, Uri? origin})
    : _client = client ?? platform.createHostedClient(),
      _origin = _validOrigin(origin ?? platform.hostedOrigin()) {
    if (platform.hostedUsesBrowserCookies &&
        origin != null &&
        origin.origin != platform.hostedOrigin()?.origin) {
      throw ArgumentError('Hosted web AI must use the app origin.');
    }
  }

  final http.Client _client;
  final Uri? _origin;
  String? _csrf;
  String? _cookie;
  String? _lastError;
  bool _closed = false;
  static const _timeout = Duration(seconds: 45);
  static const _maxResponseBytes = 512 * 1024;

  String? get unavailableReason {
    if (_closed) return 'The hosted AI connection is closed.';
    if (_origin == null) {
      return 'Hosted AI needs the same-origin web app. Native builds require an explicit STUDYORBIT_API_ORIGIN and have not been release-verified.';
    }
    return _lastError;
  }

  Future<HostedAiStatus> status() async {
    try {
      final value = await _request('GET', '/api/session');
      return _status(value);
    } on HostedAiException catch (error) {
      _lastError = error.message;
      return HostedAiStatus(
        authenticated: false,
        configured: false,
        requiresInvite: true,
        provider: '',
        model: '',
        remaining: 0,
        dailyLimit: 0,
        error: error.message,
      );
    }
  }

  Future<HostedAiStatus> signIn(String inviteCode) async {
    if (inviteCode.trim().isEmpty || inviteCode.length > 256) {
      throw const HostedAiException('invite', 'Enter your pilot invitation.');
    }
    return _status(
      await _request(
        'POST',
        '/api/session',
        body: {'inviteCode': inviteCode.trim()},
      ),
    );
  }

  Future<void> signOut() async {
    if (_csrf == null) {
      final current = await status();
      if (current.error != null) {
        throw HostedAiException('session', current.error!);
      }
      if (!current.authenticated) return;
    }
    await _request('DELETE', '/api/session', csrf: true);
    _csrf = null;
    _cookie = null;
    _lastError = null;
  }

  Future<Map<String, dynamic>> send(
    String operation,
    Map<String, dynamic> input, {
    required bool consent,
  }) async {
    if (!consent) {
      throw const HostedAiException(
        'consent',
        'Allow text-only AI processing before sending study context.',
      );
    }
    if (operation != 'extract' && operation != 'plan') {
      throw const HostedAiException('input', 'Unsupported study operation.');
    }
    final current = await status();
    if (current.error != null) {
      throw HostedAiException('configuration', current.error!);
    }
    if (!current.authenticated) {
      throw const HostedAiException(
        'session',
        'Enter your pilot invitation to continue.',
      );
    }
    if (!current.configured) {
      throw const HostedAiException(
        'configuration',
        'Hosted study AI is unavailable. Manual tasks remain available.',
      );
    }
    if (current.remaining <= 0) {
      throw const HostedAiException(
        'limit',
        'The hosted daily allowance is used. Manual tasks remain available.',
      );
    }
    return _request(
      'POST',
      '/api/ai',
      csrf: true,
      body: {'operation': operation, 'input': input, 'consent': true},
    );
  }

  HostedAiStatus _status(Map<String, dynamic> value) {
    final authenticated = value['authenticated'];
    final configured = value['configured'];
    final requiresInvite = value['requiresInvite'];
    final remaining = value['remaining'];
    final dailyLimit = value['dailyLimit'];
    final provider = value['provider'];
    final model = value['model'];
    final token = value['csrfToken'];
    final error = value['error'];
    if (authenticated is! bool ||
        configured is! bool ||
        requiresInvite is! bool ||
        remaining is! int ||
        dailyLimit is! int ||
        remaining < 0 ||
        dailyLimit < 0 ||
        dailyLimit > 1000 ||
        remaining > dailyLimit ||
        provider is! String ||
        provider.length > 300 ||
        model is! String ||
        model.length > 200 ||
        (error != null && (error is! String || error.length > 500)) ||
        (authenticated &&
            (token is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)))) {
      throw const HostedAiException(
        'response',
        'The study service returned an invalid session.',
      );
    }
    _csrf = authenticated ? token as String : null;
    _lastError = error == null ? null : 'Hosted study AI is unavailable. Manual tasks remain available.';
    return HostedAiStatus(
      authenticated: authenticated,
      configured: configured,
      requiresInvite: requiresInvite,
      provider: provider,
      model: model,
      remaining: remaining,
      dailyLimit: dailyLimit,
      error: _lastError,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool csrf = false,
  }) async {
    final origin = _origin;
    if (_closed || origin == null) {
      throw HostedAiException('configuration', unavailableReason!);
    }
    try {
      return await (() async {
        final request = http.Request(method, origin.resolve(path))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        if (!platform.hostedUsesBrowserCookies) {
          request.headers['Origin'] = origin.origin;
          if (_cookie != null) request.headers['Cookie'] = _cookie!;
        }
        if (csrf) {
          if (_csrf == null) {
            throw const HostedAiException('csrf', 'Refresh the study session.');
          }
          request.headers['X-CSRF-Token'] = _csrf!;
        }
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
          if (request.bodyBytes.length > 384 * 1024) {
            throw const HostedAiException(
              'input',
              'The study context is too large. Shorten the capture or retained history.',
            );
          }
        }
        final response = await _client.send(request);
        if ((response.contentLength ?? 0) > _maxResponseBytes) {
          await response.stream.listen((_) {}).cancel();
          throw const HostedAiException(
            'response',
            'The study service response is too large.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > _maxResponseBytes) {
            throw const HostedAiException(
              'response',
              'The study service response is too large.',
            );
          }
          bytes.addAll(chunk);
        }
        if (!platform.hostedUsesBrowserCookies) {
          final header = response.headers['set-cookie'];
          if (header != null) {
            final match = RegExp(
              r'(?:^|,\s*)studyorbit_session=([A-Za-z0-9_-]{43})(?:;|$)',
            ).firstMatch(header);
            if (match != null) _cookie = 'studyorbit_session=${match.group(1)}';
          }
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Never echo arbitrary server/proxy error bodies or HTML pages.
          throw _httpError(response.statusCode);
        }
        if (!RegExp(r'^application/json(?:\s*;|$)', caseSensitive: false)
            .hasMatch(response.headers['content-type'] ?? '')) {
          throw const HostedAiException('response', 'The study service returned non-JSON data.');
        }
        final text = utf8.decode(bytes);
        _checkDepth(text);
        final value = jsonDecode(text);
        if (value is! Map<String, dynamic>) {
          throw const HostedAiException(
            'response',
            'The study service returned malformed data.',
          );
        }
        _lastError = null;
        return value;
      })().timeout(_timeout);
    } on HostedAiException {
      rethrow;
    } on TimeoutException {
      throw const HostedAiException(
        'timeout',
        'The study service timed out. No drafts or advice were applied.',
      );
    } on FormatException {
      throw const HostedAiException(
        'response',
        'The study service returned malformed data.',
      );
    } catch (_) {
      throw const HostedAiException(
        'network',
        'The hosted study service is unreachable. Manual tasks remain available.',
      );
    }
  }

  static HostedAiException _httpError(int status) => switch (status) {
    400 || 413 || 415 => const HostedAiException(
      'input',
      'The study service accepts bounded text-only study context. Shorten the capture if needed.',
    ),
    401 => const HostedAiException(
      'session',
      'Your pilot invitation or session was not accepted. Sign in again.',
    ),
    403 => const HostedAiException(
      'session',
      'Refresh this app from its hosted address before continuing.',
    ),
    429 => const HostedAiException(
      'limit',
      'The hosted service is busy or its allowance is used. Try later; manual tasks remain available.',
    ),
    503 => const HostedAiException(
      'configuration',
      'Hosted study AI is unavailable. Manual tasks remain available.',
    ),
    504 => const HostedAiException(
      'timeout',
      'The study provider timed out. No drafts or advice were applied.',
    ),
    _ => const HostedAiException(
      'provider',
      'The study service could not complete a safe response. No drafts or advice were applied.',
    ),
  };

  static Uri? _validOrigin(Uri? uri) {
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
    return Uri.parse(uri.origin);
  }

  static void _checkDepth(String text) {
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
        if (++depth > 32) throw const FormatException('JSON depth');
      } else if (c == 125 || c == 93) {
        depth--;
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cookie = null;
    _csrf = null;
    _client.close();
  }
}
