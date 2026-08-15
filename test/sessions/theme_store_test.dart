// ThemeStore 域测试(W3-C):薄通道读写 CAS、冲突重读、失效重读、本机回退、
// 映射;端到端:自建最小假主机(describe/mutate/providers/credentials + 双 WS)
// + SettingsStore + SettingsStore.scope 适配通道(参考 command_store_test 模式,
// 不 import 共享 helper)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

// ---------------------------------------------------------------------------
// 假通道(ThemeStore 视角的最小假「主机设置面」)。
// ---------------------------------------------------------------------------
class _FakeChannel implements ThemeSettingsChannel {
  _FakeChannel({
    String preference = 'system',
    double revision = 1.0,
    bool loaded = false,
    this.loadFails = false,
  }) : _preference = preference,
       _revision = revision,
       _loaded = loaded;

  String _preference;
  double _revision;
  bool _loaded;
  bool loadFails;
  bool setFails = false;
  bool conflictOnNextSet = false;
  int loadCalls = 0;
  String? lastWritten;
  final _inv = StreamController<void>.broadcast();

  @override
  SettingsMutateValue? get snapshot =>
      _loaded ? _ns(_preference, _revision) : null;

  @override
  Future<void> load() async {
    loadCalls += 1;
    if (loadFails) throw Exception('read failed');
    _loaded = true;
  }

  @override
  Future<void> setPreference(String wireValue) async {
    if (setFails) throw Exception('write failed');
    if (conflictOnNextSet) {
      conflictOnNextSet = false;
      // 模拟底层 settings-conflict 已重读:权威值回到他端写的值。
      _preference = 'system';
      _revision = 5.0;
      throw ThemeSettingsConflictError(
        'ui-theme',
        expectedRevision: 1.0,
        latestRevision: 5.0,
      );
    }
    lastWritten = wireValue;
    _preference = wireValue;
    _revision += 1.0;
    _loaded = true;
  }

  @override
  Stream<void> get invalidations => _inv.stream;

  /// 模拟外部变更 + settings/document-updated 失效信号。
  void invalidate(String preference, [double? revision]) {
    _preference = preference;
    if (revision != null) _revision = revision;
    _inv.add(null);
  }

  Future<void> dispose() => _inv.close();
}

SettingsMutateValue _ns(String preference, double revision) =>
    SettingsMutateValue(
      ns: 'ui-theme',
      schema: <String, dynamic>{},
      value: <String, dynamic>{'preference': preference},
      applies: 'live',
      secrets: const <SettingsSecretView>[],
      revision: revision,
    );

// ---------------------------------------------------------------------------
// 端到端:最小假 DSH 主机 + SettingsStore + SettingsStore.scope 适配通道。
// ---------------------------------------------------------------------------
class _FakeThemeHost {
  _FakeThemeHost._(this._server);
  final HttpServer _server;
  final List<WebSocket> _mux = <WebSocket>[];
  final List<WebSocket> _host = <WebSocket>[];
  int _frameNo = 0;

  /// ns -> {schema, value, revision, applies}。
  final namespaces = <String, Map<String, dynamic>>{};
  final mutateRequests = <Map<String, dynamic>>[];

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_FakeThemeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeThemeHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{
        'version': '0.0.1-fake',
        'cwd': '/tmp/fake',
        'provider': 'fake',
        'model': 'fake-model',
        'attachedSessions': 0,
        'canOpenPath': false,
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/settings.describe') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{
        'writable': true,
        'hasDocument': true,
        'namespaces': [
          for (final e in namespaces.entries)
            <String, dynamic>{
              'ns': e.key,
              'schema': e.value['schema'],
              'value': e.value['value'],
              'applies': e.value['applies'] ?? 'live',
              'secrets': <Map<String, dynamic>>[],
              'revision': (e.value['revision'] as num).toDouble(),
            },
        ],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/settings.mutate') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      mutateRequests.add(payload);
      final ns = payload['ns'] as String;
      final state = namespaces[ns]!;
      final expected = payload['expectedRevision'];
      final currentRev = (state['revision'] as num).toDouble();
      if (expected != null && (expected as num).toDouble() != currentRev) {
        await _bizError(
          req,
          envelope['rpcId'] as String,
          'settings-conflict',
          <String, dynamic>{'ns': ns},
        );
        return;
      }
      final value = state['value'] as Map<String, dynamic>;
      for (final op in payload['ops'] as List) {
        final path = (op['path'] as List).cast<String>();
        if (op['op'] == 'set') {
          _setAt(value, path, op['value']);
        } else if (op['op'] == 'unset') {
          if (path.isEmpty) {
            value.clear();
          } else {
            _removeAt(value, path);
          }
        }
      }
      final newRev = currentRev + 1;
      state['revision'] = newRev;
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{
        'ns': ns,
        'schema': state['schema'],
        'value': value,
        'applies': 'live',
        'secrets': <Map<String, dynamic>>[],
        'revision': newRev,
      });
      // 真实主机写后推 document-updated(失效路径端到端验证)。
      sendHostFrame(<String, dynamic>{
        'type': 'host/remote-event',
        'event': 'settings/document-updated',
        'args': <dynamic>[ns],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/llm.providers') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{
        'providers': <Map<String, dynamic>>[],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/credentials.describe') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{
        'credentials': <String, dynamic>{},
      });
      return;
    }
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      (path.endsWith('mux') ? _mux : _host).add(ws);
      ws.listen((_) {}, onDone: () {});
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  /// host 下行推帧(server-request 信封)。
  void sendHostFrame(Map<String, dynamic> payload) {
    _frameNo += 1;
    for (final ws in _host) {
      try {
        ws.add(
          jsonEncode(<String, dynamic>{
            'type': 'server-request',
            'rpcId': 'fake-host-$_frameNo',
            'method': payload['type'] as String,
            'payload': payload,
          }),
        );
      } catch (_) {
        // 已关闭的旧 socket 忽略。
      }
    }
  }

  Future<void> _ok(
    HttpRequest req,
    String rpcId,
    Map<String, dynamic> value,
  ) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode(<String, dynamic>{
        'type': 'server-response',
        'rpcId': rpcId,
        'result': <String, dynamic>{'ok': true, 'value': value},
      }),
    );
    await req.response.close();
  }

  Future<void> _bizError(
    HttpRequest req,
    String rpcId,
    String code,
    Map<String, dynamic> details,
  ) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode(<String, dynamic>{
        'type': 'server-response',
        'rpcId': rpcId,
        'result': <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': code,
            'message': code,
            'details': details,
          },
        },
      }),
    );
    await req.response.close();
  }

  static void _setAt(Map<String, dynamic> root, List<String> path, Object? v) {
    var cur = root;
    for (var i = 0; i < path.length - 1; i++) {
      final seg = path[i];
      final next = cur[seg];
      if (next is! Map<String, dynamic>) {
        final m = <String, dynamic>{};
        cur[seg] = m;
        cur = m;
      } else {
        cur = next;
      }
    }
    if (path.isNotEmpty) cur[path.last] = v;
  }

  static void _removeAt(Map<String, dynamic> root, List<String> path) {
    var cur = root;
    for (var i = 0; i < path.length - 1; i++) {
      final next = cur[path[i]];
      if (next is! Map<String, dynamic>) return;
      cur = next;
    }
    if (path.isNotEmpty) cur.remove(path.last);
  }

  Future<void> stop() async {
    for (final ws in [..._mux, ..._host]) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _mux.clear();
    _host.clear();
    await _server.close(force: true);
  }
}

/// ui-theme schema(对齐活体:preference 是 union → const 枚举,默认 system)。
Map<String, dynamic> _uiThemeSchema() => <String, dynamic>{
  'uid': '9',
  'refs': <String, dynamic>{
    '0': <String, dynamic>{
      'type': 'const',
      'meta': <String, dynamic>{'required': true},
      'value': 'light',
    },
    '1': <String, dynamic>{
      'type': 'const',
      'meta': <String, dynamic>{'required': true},
      'value': 'dark',
    },
    '2': <String, dynamic>{
      'type': 'const',
      'meta': <String, dynamic>{'required': true},
      'value': 'system',
    },
    '3': <String, dynamic>{
      'type': 'union',
      'meta': <String, dynamic>{'default': 'system'},
      'list': <Object>['0', '1', '2'],
    },
    '9': <String, dynamic>{
      'type': 'object',
      'meta': <String, dynamic>{'default': <String, dynamic>{}},
      'dict': <String, dynamic>{'preference': '3'},
    },
  },
};

/// SettingsStore.scope('ui-theme') 适配通道 —— 集成方参考实现:
/// snapshot/load/setField + hostFrames 过滤 settings/document-updated 转发。
class _ScopeChannel implements ThemeSettingsChannel {
  _ScopeChannel(this._settings, this._connection) {
    _sub = _connection.hostFrames.listen((frame) {
      if (frame is HostFrameHostRemoteEvent &&
          frame.event == 'settings/document-updated') {
        _inv.add(null);
      }
    });
  }

  final SettingsStoreView _settings;
  final ConnectionController _connection;
  final _inv = StreamController<void>.broadcast();
  StreamSubscription<HostFrame>? _sub;

  SettingsScope get _scope => _settings.scope('ui-theme');

  @override
  SettingsMutateValue? get snapshot => _scope.snapshot;

  @override
  Future<void> load() => _scope.load();

  @override
  Future<void> setPreference(String wireValue) async {
    try {
      await _scope.setField(<String>['preference'], wireValue);
    } on SettingsConflictError catch (e) {
      throw ThemeSettingsConflictError(
        'ui-theme',
        expectedRevision: e.expectedRevision,
        latestRevision: e.latestRevision,
      );
    }
  }

  @override
  Stream<void> get invalidations => _inv.stream;

  Future<void> dispose() async {
    await _sub?.cancel();
    await _inv.close();
  }
}

void main() {
  group('ThemeStore 域(假通道)', () {
    test('初始读:通道已有快照 → 直接应用,不额外读', () async {
      final ch = _FakeChannel(preference: 'light', revision: 3.0, loaded: true);
      final store = ThemeStore(channel: ch);
      await pumpEventQueue();
      expect(store.current, ThemePreference.light);
      expect(ch.loadCalls, 0);
      await store.dispose();
      await ch.dispose();
    });

    test('初始读:快照缺省 → load 后取 preference', () async {
      final ch = _FakeChannel(preference: 'dark', loaded: false);
      final store = ThemeStore(channel: ch);
      await pumpEventQueue();
      expect(store.current, ThemePreference.dark);
      expect(ch.loadCalls, 1);
      await store.dispose();
      await ch.dispose();
    });

    test('初始读失败 → 本机回退 system,不抛异常', () async {
      final ch = _FakeChannel(
        preference: 'dark',
        loaded: false,
        loadFails: true,
      );
      final store = ThemeStore(channel: ch);
      await pumpEventQueue();
      expect(store.current, ThemePreference.system);
      await store.dispose();
      await ch.dispose();
    });

    test('非法 preference 值 → 本机回退 system', () async {
      final ch = _FakeChannel(preference: 'blue', loaded: true);
      final store = ThemeStore(channel: ch);
      await pumpEventQueue();
      expect(store.current, ThemePreference.system);
      await store.dispose();
      await ch.dispose();
    });

    test('setMode 成功:乐观即时生效 + CAS 写 preference + 流发出', () async {
      final ch = _FakeChannel(preference: 'system', loaded: true);
      final store = ThemeStore(channel: ch);
      final seen = <ThemePreference>[];
      final sub = store.preferences.listen(seen.add);
      await store.setMode(ThemePreference.dark);
      expect(store.current, ThemePreference.dark);
      expect(ch.lastWritten, 'dark');
      expect(ch.snapshot!.revision, 2.0);
      expect(seen, <ThemePreference>[ThemePreference.dark]);
      await sub.cancel();
      await store.dispose();
      await ch.dispose();
    });

    test('setMode 冲突 → 重读权威值 + 抛 typed ThemeSettingsConflictError', () async {
      final ch = _FakeChannel(preference: 'system', loaded: true);
      final store = ThemeStore(channel: ch);
      ch.conflictOnNextSet = true;
      await expectLater(
        store.setMode(ThemePreference.dark),
        throwsA(isA<ThemeSettingsConflictError>()),
      );
      expect(store.current, ThemePreference.system); // 权威值回滚。
      expect(ch.snapshot!.revision, 5.0);
      await store.dispose();
      await ch.dispose();
    });

    test('setMode 传输失败 → 重读恢复权威值 + 抛原异常', () async {
      final ch = _FakeChannel(preference: 'light', loaded: true);
      final store = ThemeStore(channel: ch);
      ch.setFails = true;
      await expectLater(
        store.setMode(ThemePreference.dark),
        throwsA(isA<Exception>()),
      );
      expect(store.current, ThemePreference.light); // 恢复。
      await store.dispose();
      await ch.dispose();
    });

    test('失效(settings/document-updated)→ 重读并应用新值', () async {
      final ch = _FakeChannel(preference: 'system', loaded: true);
      final store = ThemeStore(channel: ch);
      ch.invalidate('dark', 2.0);
      await pumpEventQueue();
      expect(store.current, ThemePreference.dark);
      expect(ch.loadCalls, 1); // 失效 → 显式重读。
      await store.dispose();
      await ch.dispose();
    });

    test('失效重读失败 → 保持现值,不打扰 UI', () async {
      final ch = _FakeChannel(preference: 'system', loaded: true);
      final store = ThemeStore(channel: ch);
      ch.loadFails = true;
      ch.invalidate('dark', 2.0);
      await pumpEventQueue();
      expect(store.current, ThemePreference.system);
      await store.dispose();
      await ch.dispose();
    });

    test('setMode 同值 → no-op 不写', () async {
      final ch = _FakeChannel(preference: 'system', loaded: true);
      final store = ThemeStore(channel: ch);
      await store.setMode(ThemePreference.system);
      expect(ch.lastWritten, isNull);
      await store.dispose();
      await ch.dispose();
    });

    test('映射:wireValue / tryParse round-trip + 未知值', () {
      expect(ThemePreference.system.wireValue, 'system');
      expect(ThemePreference.light.wireValue, 'light');
      expect(ThemePreference.dark.wireValue, 'dark');
      expect(ThemePreference.tryParse('system'), ThemePreference.system);
      expect(ThemePreference.tryParse('light'), ThemePreference.light);
      expect(ThemePreference.tryParse('dark'), ThemePreference.dark);
      expect(ThemePreference.tryParse('blue'), isNull);
      expect(ThemePreference.tryParse(null), isNull);
    });
  });

  group('ThemeStore 端到端(最小假主机 + SettingsStore.scope 适配)', () {
    late _FakeThemeHost host;
    late ConnectionController controller;
    late ApiClient api;
    late SettingsStore settings;
    late _ScopeChannel channel;
    late ThemeStore store;

    setUp(() async {
      host = await _FakeThemeHost.start();
      host.namespaces['ui-theme'] = <String, dynamic>{
        'schema': _uiThemeSchema(),
        'value': <String, dynamic>{'preference': 'light'},
        'revision': 1.0,
        'applies': 'live',
      };
      controller = ConnectionController(
        baseUri: host.baseUri,
        initialBackoff: const Duration(milliseconds: 30),
        maxBackoff: const Duration(milliseconds: 150),
        probeTimeout: const Duration(milliseconds: 400),
      );
      api = ApiClient(
        baseUri: host.baseUri,
        defaultTimeout: const Duration(milliseconds: 300),
      );
      settings = SettingsStore(api: api, connection: controller);
      channel = _ScopeChannel(settings, controller);
      controller.start();
      await controller.snapshots
          .firstWhere((s) => s.phase == ConnectionPhase.ready)
          .timeout(const Duration(seconds: 3));
      await settings.snapshots
          .firstWhere((s) => s.namespaces.containsKey('ui-theme'))
          .timeout(const Duration(seconds: 3));
      store = ThemeStore(channel: channel);
    });

    tearDown(() async {
      await store.dispose();
      await channel.dispose();
      await settings.dispose();
      await controller.dispose();
      api.dispose();
      await host.stop();
    });

    test('describe 解析 ui-theme.preference → ThemePreference', () {
      expect(store.current, ThemePreference.light);
    });

    test(
      'setMode 走 settings.mutate:set preference + expectedRevision CAS',
      () async {
        await store.setMode(ThemePreference.dark);
        expect(host.namespaces['ui-theme']!['value'], <String, dynamic>{
          'preference': 'dark',
        });
        expect(host.mutateRequests.last['expectedRevision'], 1.0);
        final ops = host.mutateRequests.last['ops'] as List;
        expect(ops.single['op'], 'set');
        expect(ops.single['path'], <String>['preference']);
        expect(ops.single['value'], 'dark');
      },
    );

    test('CAS 冲突(他端已改 revision)→ typed 错误 + 权威值回滚', () async {
      host.namespaces['ui-theme']!['revision'] = 9.0;
      host.namespaces['ui-theme']!['value'] = <String, dynamic>{
        'preference': 'system',
      };
      await expectLater(
        store.setMode(ThemePreference.dark),
        throwsA(isA<ThemeSettingsConflictError>()),
      );
      expect(store.current, ThemePreference.system); // 冲突后重读权威值。
    });

    test('settings/document-updated(host 帧)→ 失效重读生效', () async {
      host.namespaces['ui-theme']!['value'] = <String, dynamic>{
        'preference': 'dark',
      };
      host.namespaces['ui-theme']!['revision'] = 2.0;
      host.sendHostFrame(<String, dynamic>{
        'type': 'host/remote-event',
        'event': 'settings/document-updated',
        'args': <dynamic>['ui-theme'],
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(store.current, ThemePreference.dark);
    });
  });
}
