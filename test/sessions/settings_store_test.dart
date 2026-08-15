// SettingsStore 域测试(自建最小假主机,不 import 共享 helper):
// describe/mutate CAS 成功与冲突重读、credentials 徽标合并、discoverModels
// 参数、失效事件重拉、非冲突业务错误透传(PLAN W1-D 验收的域层一半)。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/settings_store.dart';

// ---------------------------------------------------------------------------
// 最小假 DSH 主机:describe + 双 WS 下行 + settings/credentials/llm 五方法。
// 只覆盖本测试所需面;CAS 冲突与业务错误可编程注入。
// ---------------------------------------------------------------------------
class _FakeSettingsHost {
  _FakeSettingsHost._(this._server);
  final HttpServer _server;
  final muxSockets = <WebSocket>[];
  final hostSockets = <WebSocket>[];
  final _allSockets = <WebSocket>{};

  /// ns -> {schema, value, revision, applies}。
  final namespaces = <String, Map<String, dynamic>>{};
  final providers = <Map<String, dynamic>>[];
  /// ref -> {configured, source?, writable}。
  final credentials = <String, Map<String, dynamic>>{};
  final mutateRequests = <Map<String, dynamic>>[];
  final credentialSetRequests = <Map<String, dynamic>>[];
  final credentialUnsetRequests = <Map<String, dynamic>>[];
  final discoverRequests = <Map<String, dynamic>>[];
  int describeCalls = 0;
  int mutateCalls = 0;
  int discoverCalls = 0;
  int openDocumentCalls = 0;

  /// 下一次 mutate 强制 settings-conflict(用后即焚)。
  bool rejectNextMutateWithConflict = false;
  /// 注入其他业务错误码(如 settings-rejected)。
  String? forcedMutateErrorCode;

  static Future<_FakeSettingsHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeSettingsHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {
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
      describeCalls += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {
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
      mutateCalls += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      mutateRequests.add(payload);
      final ns = payload['ns'] as String;
      final state = namespaces[ns]!;
      if (rejectNextMutateWithConflict) {
        rejectNextMutateWithConflict = false;
        await _bizError(req, envelope['rpcId'] as String, 'settings-conflict', {'ns': ns});
        return;
      }
      if (forcedMutateErrorCode != null) {
        await _bizError(req, envelope['rpcId'] as String, forcedMutateErrorCode!, {});
        return;
      }
      // CAS:expectedRevision 与当前 revision 不符 → settings-conflict。
      final expected = payload['expectedRevision'];
      final currentRev = (state['revision'] as num).toDouble();
      if (expected != null && (expected as num).toDouble() != currentRev) {
        await _bizError(req, envelope['rpcId'] as String, 'settings-conflict', {'ns': ns});
        return;
      }
      final value = (state['value'] as Map<String, dynamic>);
      final ops = payload['ops'] as List;
      _applyOps(value, ops);
      final newRev = currentRev + 1;
      state['revision'] = newRev;
      await _ok(req, envelope['rpcId'] as String, {
        'ns': ns,
        'schema': state['schema'],
        'value': value,
        'applies': 'live',
        'secrets': <Map<String, dynamic>>[],
        'revision': newRev,
      });
      // 真实主机在写入后推 document-updated(失效路径顺带验证)。
      sendHostFrame({
        'type': 'host/remote-event',
        'event': 'settings/document-updated',
        'args': [ns],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/credentials.describe') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final refs = (payload['refs'] as List).cast<String>();
      final out = <String, dynamic>{};
      for (final ref in refs) {
        out[ref] = credentials[ref] ??
            <String, dynamic>{'configured': false, 'writable': true};
      }
      await _ok(req, envelope['rpcId'] as String, {'credentials': out});
      return;
    }
    if (req.method == 'POST' && path == '/api/credentials.set') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      credentialSetRequests.add(payload);
      credentials[payload['ref'] as String] = <String, dynamic>{
        'configured': true,
        'source': 'file',
        'writable': true,
      };
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{});
      sendHostFrame({
        'type': 'host/remote-event',
        'event': 'credentials/updated',
        'args': [payload['ref']],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/credentials.unset') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      credentialUnsetRequests.add(payload);
      credentials[payload['ref'] as String] = <String, dynamic>{
        'configured': false,
        'writable': true,
      };
      await _ok(req, envelope['rpcId'] as String, <String, dynamic>{});
      sendHostFrame({
        'type': 'host/remote-event',
        'event': 'credentials/updated',
        'args': [payload['ref']],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/llm.providers') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {'providers': providers});
      return;
    }
    if (req.method == 'POST' && path == '/api/llm.discoverModels') {
      discoverCalls += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      discoverRequests.add(envelope['payload'] as Map<String, dynamic>);
      await _ok(req, envelope['rpcId'] as String, {
        'models': [
          <String, dynamic>{
            'id': 'glm-4.7',
            'name': 'GLM-4.7',
            'contextWindow': 204800,
            'maxTokens': 131072,
          },
          <String, dynamic>{
            'id': 'glm-5.3',
            'name': 'GLM-5.3',
            'contextWindow': 1000000,
            'maxTokens': 131072,
          },
        ],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/settings.openDocument') {
      openDocumentCalls += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {'opened': true});
      return;
    }
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      _allSockets.add(ws);
      (path.endsWith('mux') ? muxSockets : hostSockets).add(ws);
      ws.listen((_) {}, onDone: () => _allSockets.remove(ws));
      return;
    }
    req.response.statusCode = 404;
    req.response.write('not found');
    await req.response.close();
  }

  /// host 下行推帧(server-request 信封)。
  void sendHostFrame(Map<String, dynamic> payload) {
    for (final ws in hostSockets) {
      ws.add(jsonEncode(<String, dynamic>{
        'type': 'server-request',
        'rpcId': 'host-${DateTime.now().microsecondsSinceEpoch}',
        'method': payload['type'] as String,
        'payload': payload,
      }));
    }
  }

  Future<void> _ok(HttpRequest req, String rpcId, Map<String, dynamic> value) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(<String, dynamic>{
      'type': 'server-response',
      'rpcId': rpcId,
      'result': <String, dynamic>{'ok': true, 'value': value},
    }));
    await req.response.close();
  }

  Future<void> _bizError(HttpRequest req, String rpcId, String code, Map<String, dynamic> details) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(<String, dynamic>{
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
    }));
    await req.response.close();
  }

  static void _applyOps(Map<String, dynamic> value, List<dynamic> ops) {
    for (final op in ops) {
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
    for (final ws in _allSockets.toList()) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _allSockets.clear();
    muxSockets.clear();
    hostSockets.clear();
    await _server.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// fixture:schema 形状对齐活体主机(uid/refs 结构;enum 走 union → const)。
// ---------------------------------------------------------------------------
Map<String, dynamic> _permissionSchema() => <String, dynamic>{
      'uid': '10',
      'refs': <String, dynamic>{
        '0': <String, dynamic>{'type': 'const', 'meta': {'required': true}, 'value': 'read-only'},
        '1': <String, dynamic>{'type': 'const', 'meta': {'required': true}, 'value': 'workspace-write'},
        '2': <String, dynamic>{'type': 'const', 'meta': {'required': true}, 'value': 'danger-full-access'},
        '3': <String, dynamic>{'type': 'union', 'meta': {'required': true}, 'list': <Object>['0', '1', '2']},
        '10': <String, dynamic>{'type': 'object', 'meta': {'default': {}}, 'dict': {'defaultPreset': '3'}},
      },
    };

/// llm-deepseek:apiKeyEnv 只在 schema 里带 credential-ref 默认(值里没有),
/// 用于验证「值缺失 → schema 默认回退」的凭据引用推导。
Map<String, dynamic> _deepseekSchema() => <String, dynamic>{
      'uid': '20',
      'refs': <String, dynamic>{
        '0': <String, dynamic>{
          'type': 'string',
          'meta': <String, dynamic>{'role': 'credential-ref', 'default': 'DEEPSEEK_API_KEY'},
        },
        '1': <String, dynamic>{'type': 'string', 'meta': {}},
        '20': <String, dynamic>{
          'type': 'object',
          'meta': {'default': {}},
          'dict': <String, dynamic>{'apiKeyEnv': '0', 'baseURL': '1', 'models': '2'},
        },
      },
    };

Map<String, dynamic> _piAiSchema() => <String, dynamic>{
      'uid': '30',
      'refs': <String, dynamic>{
        '30': <String, dynamic>{
          'type': 'object',
          'meta': {'default': {}},
          'dict': <String, dynamic>{'providers': '31'},
        },
        '31': <String, dynamic>{'type': 'dict', 'meta': {}, 'inner': '32', 'sKey': '33'},
        '32': <String, dynamic>{
          'type': 'object',
          'meta': {},
          'dict': <String, dynamic>{'apiKeyEnv': '34', 'baseURL': '35', 'models': '36'},
        },
        '33': <String, dynamic>{'type': 'string', 'meta': {}},
        '34': <String, dynamic>{'type': 'string', 'meta': {}},
        '35': <String, dynamic>{'type': 'string', 'meta': {}},
        '36': <String, dynamic>{'type': 'array', 'meta': {'default': []}, 'inner': '37'},
        '37': <String, dynamic>{
          'type': 'object',
          'meta': {},
          'dict': <String, dynamic>{'id': '38', 'name': '39'},
        },
        '38': <String, dynamic>{'type': 'string', 'meta': {}},
        '39': <String, dynamic>{'type': 'string', 'meta': {}},
      },
    };

void _seedFixture(_FakeSettingsHost host) {
  host.namespaces['permission'] = <String, dynamic>{
    'schema': _permissionSchema(),
    'value': <String, dynamic>{'defaultPreset': 'workspace-write'},
    'revision': 0.0,
    'applies': 'live',
  };
  host.namespaces['llm-deepseek'] = <String, dynamic>{
    'schema': _deepseekSchema(),
    'value': <String, dynamic>{
      'baseURL': 'https://api.deepseek.com',
      'models': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'deepseek-v4-flash',
          'name': 'DeepSeek-V4-Flash',
          'contextWindow': 1000000,
          'maxTokens': 131072,
        },
      ],
    },
    'revision': 1.0,
    'applies': 'live',
  };
  host.namespaces['llm-pi-ai'] = <String, dynamic>{
    'schema': _piAiSchema(),
    'value': <String, dynamic>{
      'providers': <String, dynamic>{
        'openai': <String, dynamic>{
          'apiKeyEnv': 'OPENAI_API_KEY',
          'baseURL': 'https://api.openai.com/v1',
          'models': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'gpt-4o', 'name': 'GPT-4o'},
          ],
        },
      },
    },
    'revision': 2.0,
    'applies': 'live',
  };
  host.providers.addAll(<Map<String, dynamic>>[
    <String, dynamic>{
      'provider': 'deepseek-official',
      'displayName': 'DeepSeek',
      'settingsNs': 'llm-deepseek',
      'settingsPath': <String>[],
      'active': true,
    },
    <String, dynamic>{
      'provider': 'openai',
      'displayName': 'OpenAI',
      'settingsNs': 'llm-pi-ai',
      'settingsPath': <String>['providers', 'openai'],
      'active': false,
      'declared': true,
    },
    <String, dynamic>{
      'provider': 'anthropic',
      'displayName': 'Anthropic',
      'settingsNs': 'llm-pi-ai',
      'settingsPath': <String>['providers', 'anthropic'],
      'active': false,
      'declared': false,
    },
  ]);
  host.credentials['DEEPSEEK_API_KEY'] = <String, dynamic>{
    'configured': true,
    'source': 'file',
    'writable': true,
  };
  // OPENAI_API_KEY 未配置 → openai 提供方应显示红点(引用缺失)。
}

Future<void> _pollUntil(bool Function() cond) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(cond(), isTrue, reason: '轮询条件未在超时内满足');
}

void main() {
  late _FakeSettingsHost host;
  late ConnectionController controller;
  late ApiClient api;
  late SettingsStore store;

  setUp(() async {
    host = await _FakeSettingsHost.start();
    _seedFixture(host);
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    api = ApiClient(baseUri: host.baseUri);
    store = SettingsStore(api: api, connection: controller);
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
  });

  test('ready → refresh 装载 namespaces/providers 与凭据徽标(绿/红/无)', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));

    final snap = store.current;
    expect(snap.providers, hasLength(3));
    expect(snap.writable, isTrue);
    expect(snap.hasDocument, isTrue);
    // llm-deepseek:值里无 apiKeyEnv,回退 schema 的 credential-ref 默认。
    final deepseek = snap.providers.firstWhere((p) => p.providerId == 'deepseek-official');
    expect(deepseek.credentialRef, 'DEEPSEEK_API_KEY');
    expect(deepseek.credentialStatus, CredentialStatus.configured);
    expect(deepseek.routable, isTrue);
    expect(deepseek.custom, isFalse);
    expect(deepseek.models, hasLength(1));
    expect(deepseek.models.first['contextWindow'], 1000000);
    // openai:引用 OPENAI_API_KEY 未配置 → 红点。
    final openai = snap.providers.firstWhere((p) => p.providerId == 'openai');
    expect(openai.credentialRef, 'OPENAI_API_KEY');
    expect(openai.credentialStatus, CredentialStatus.missing);
    expect(openai.custom, isTrue);
    // anthropic:无配置无引用 → 无点。
    final anthropic = snap.providers.firstWhere((p) => p.providerId == 'anthropic');
    expect(anthropic.credentialStatus, CredentialStatus.none);
    expect(anthropic.credentialRef, isNull);
    // 权限预设从 schema 动态读。
    expect(store.permissionPresetOptions,
        <String>['read-only', 'workspace-write', 'danger-full-access']);
    expect(store.permissionNamespace, 'permission');
    expect(store.currentPermissionPreset, 'workspace-write');
    // 快照里 namespace 的 revision 已落地。
    expect(store.namespace('permission')!.revision, 0.0);
  });

  test('mutate CAS 成功:expectedRevision 取自快照,响应覆盖本地 revision', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));

    final value = await store.scope('permission').setField(['defaultPreset'], 'read-only');
    expect(value.revision, 1.0);
    expect(host.mutateRequests, hasLength(1));
    final payload = host.mutateRequests.single;
    expect(payload['ns'], 'permission');
    expect(payload['expectedRevision'], 0.0);
    expect(payload['ops'], <Map<String, dynamic>>[
      <String, dynamic>{'op': 'set', 'path': <String>['defaultPreset'], 'value': 'read-only'},
    ]);
    // 响应已覆盖本地快照(新 revision 供下一次 CAS)。
    expect(store.namespace('permission')!.revision, 1.0);
    expect(store.currentPermissionPreset, 'read-only');
  });

  test('mutate settings-conflict → 自动重读 + 抛 SettingsConflictError', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));
    final before = host.describeCalls;
    host.rejectNextMutateWithConflict = true;

    await expectLater(
      store.scope('permission').setField(['defaultPreset'], 'read-only'),
      throwsA(isA<SettingsConflictError>()),
    );
    // 冲突后已自动重读(settings.describe 再次被调)。
    expect(host.describeCalls, greaterThan(before));
  });

  test('冲突后重试(最新写入优先)成功:expectedRevision 用重读后的新值', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));
    // 外部修改把 permission revision 推到 3(别处改过)。
    host.namespaces['permission']!['revision'] = 3.0;
    host.rejectNextMutateWithConflict = true;

    await expectLater(
      store.scope('permission').setField(['defaultPreset'], 'read-only'),
      throwsA(isA<SettingsConflictError>()),
    );
    // 重读后本地 revision = 3,重试不再冲突。
    final value = await store.scope('permission').setField(['defaultPreset'], 'read-only');
    expect(value.revision, 4.0);
    expect(host.mutateRequests.last['expectedRevision'], 3.0);
    expect(store.currentPermissionPreset, 'read-only');
  });

  test('setCredential/unsetCredential 信封 + 徽标刷新(credentials/updated 事件)', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));
    ProviderEntry openai() => store.current.providers.firstWhere((p) => p.providerId == 'openai');
    expect(openai().credentialStatus, CredentialStatus.missing);

    await store.setCredential('OPENAI_API_KEY', 'sk-abc');
    expect(host.credentialSetRequests.single, <String, dynamic>{
      'ref': 'OPENAI_API_KEY',
      'value': 'sk-abc',
    });
    // 主机推 credentials/updated → store 重拉 → 徽标翻绿。
    await _pollUntil(() => openai().credentialStatus == CredentialStatus.configured);

    await store.unsetCredential('OPENAI_API_KEY');
    expect(host.credentialUnsetRequests.single, <String, dynamic>{'ref': 'OPENAI_API_KEY'});
    await _pollUntil(() => openai().credentialStatus == CredentialStatus.missing);
  });

  test('discoverModels 带草稿端点/密钥参数', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));

    final result = await store.discoverModels(
      settingsNs: 'llm-deepseek',
      provider: 'deepseek-official',
      baseURL: 'https://draft.example.com/v1',
      apiKey: 'sk-draft',
    );
    expect(host.discoverRequests.single, <String, dynamic>{
      'settingsNs': 'llm-deepseek',
      'provider': 'deepseek-official',
      'baseURL': 'https://draft.example.com/v1',
      'apiKey': 'sk-draft',
    });
    expect(result.models, hasLength(2));
    expect(result.models.first.id, 'glm-4.7');
  });

  test('失效事件三件套触发重拉;无关事件不触发', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));

    Future<void> expectReload() async {
      final before = host.describeCalls;
      await _pollUntil(() => host.describeCalls > before);
    }
    host.sendHostFrame({
      'type': 'host/remote-event',
      'event': 'settings/document-updated',
      'args': <String>['permission'],
    });
    await expectReload();
    host.sendHostFrame({
      'type': 'host/remote-event',
      'event': 'credentials/updated',
      'args': <String>['DEEPSEEK_API_KEY'],
    });
    await expectReload();
    host.sendHostFrame({
      'type': 'host/remote-event',
      'event': 'llm/adapters-updated',
      'args': <dynamic>[],
    });
    await expectReload();
    // 无关事件不触发重拉。
    final before = host.describeCalls;
    host.sendHostFrame({
      'type': 'host/remote-event',
      'event': 'session/something-else',
      'args': <dynamic>[],
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(host.describeCalls, before);
  });

  test('非冲突业务错误原样抛出且不触发重读', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));
    final before = host.describeCalls;
    host.forcedMutateErrorCode = 'settings-rejected';

    await expectLater(
      store.scope('permission').setField(['defaultPreset'], 'read-only'),
      throwsA(isA<RpcBusinessError>()),
    );
    // settings-rejected 不是 conflict:不重读,异常原样透传给 UI。
    expect(host.describeCalls, before);
    expect(store.currentPermissionPreset, 'workspace-write');
  });

  test('unsetField 信封与提供方删除语义(清配置+清派生凭据)', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));
    final anthropic = store.current.providers.firstWhere((p) => p.providerId == 'anthropic');
    // anthropic 无凭据引用 → 只清配置。
    await store.scope('llm-pi-ai').unsetField(<String>['providers', 'anthropic']);
    final payload = host.mutateRequests.last;
    expect(payload['ns'], 'llm-pi-ai');
    expect(payload['expectedRevision'], 2.0);
    expect(payload['ops'], <Map<String, dynamic>>[
      <String, dynamic>{'op': 'unset', 'path': <String>['providers', 'anthropic']},
    ]);
    // 假主机已把该 key 从 value 里移除。
    final piValue = host.namespaces['llm-pi-ai']!['value'] as Map<String, dynamic>;
    expect((piValue['providers'] as Map).containsKey('anthropic'), isFalse);
    expect(anthropic.credentialRef, isNull);
  });

  test('openDocument 信封(外壳「打开配置文件」)', () async {
    controller.start();
    await store.snapshots.first.timeout(const Duration(seconds: 3));
    final value = await store.openDocument();
    expect(value.opened, isTrue);
    expect(host.openDocumentCalls, 1);
  });
}