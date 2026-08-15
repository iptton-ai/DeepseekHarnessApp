// DirectoryBrowserStore + DirectoryBrowseSheet 测试(W2-B)。
// 模式:域测试自建最小假主机(仅 host.listDirectory / host.createDirectory 两个
// unary RPC,无需 WS/describe — 本 store 不依赖 ConnectionController);
// widget 测试注入假 DirectoryBrowserView。不 import 共享 helper。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/ui/directory_browse_sheet.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 最小假主机:只服务 host.listDirectory / host.createDirectory 两个 POST;
/// 路由可编程(成功 value map 或 {'code':...} 错误 map)。
class _FakeHost {
  _FakeHost._(this._server);
  final HttpServer _server;

  /// list 路由:key = 请求 path ?? `'<home>'`;值 = 成功 value 或错误 map。
  final Map<String, Object> listRoutes = <String, Object>{};

  /// create 路由:key = 'path|name';值同上。
  final Map<String, Object> createRoutes = <String, Object>{};

  /// 收到的信封调用记录(method + payload)。
  final List<({String method, Map<String, dynamic> payload})> calls =
      <({String method, Map<String, dynamic> payload})>[];

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.method != 'POST') {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final body = await utf8.decoder.bind(req).join();
    final envelope = jsonDecode(body) as Map<String, dynamic>;
    final method = envelope['method'] as String;
    final payload = (envelope['payload'] as Map<String, dynamic>?) ?? const {};
    calls.add((method: method, payload: payload));

    final Map<String, dynamic> result;
    if (method == 'host.listDirectory') {
      final key = payload['path'] as String? ?? '<home>';
      result = _routeResult(listRoutes, key, payload, '<home>');
    } else if (method == 'host.createDirectory') {
      final key = "${payload['path']}|${payload['name']}";
      final route = createRoutes[key];
      if (route is Map<String, dynamic> && route.containsKey('code')) {
        result = _errorFrom(route);
      } else if (route is Map<String, dynamic>) {
        result = {'ok': true, 'value': route};
      } else {
        // 创建默认成功(错误由路由注入)。
        result = {'ok': true,
            'value': {'path': "${payload['path']}/${payload['name']}"}};
      }
    } else {
      result = _errorResult('internal', 'unknown method: $method');
    }

    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'type': 'server-response',
      'rpcId': envelope['rpcId'],
      'result': result,
    }));
    await req.response.close();
  }

  /// 路由折叠:无路由 → directory-unreadable;有 'code' → 错误;否则成功 value。
  Map<String, dynamic> _routeResult(
      Map<String, Object> routes, String key, Map<String, dynamic> payload,
      String fallbackPath) {
    final route = routes[key];
    if (route is Map<String, dynamic>) {
      if (route.containsKey('code')) return _errorFrom(route);
      return {'ok': true, 'value': route};
    }
    return _errorResult('directory-unreadable', 'no route for $key',
        path: payload['path'] as String? ?? fallbackPath);
  }

  Map<String, dynamic> _errorFrom(Map<String, dynamic> route) =>
      {'ok': false, 'error': route};

  Map<String, dynamic> _errorResult(String code, String message,
      {String path = ''}) =>
      {'ok': false, 'error': {'code': code, 'message': message, 'details': {'path': path}}};

  Future<void> stop() async => _server.close(force: true);
}

/// DirectoryEntry 便捷构造(wire 形状)。
DirectoryEntry _entry(String name, String path, {bool hidden = false}) =>
    DirectoryEntry(name: name, path: path, hidden: hidden);

/// host.listDirectory 成功 value 的 wire JSON。
Map<String, dynamic> _listing({
  required String path,
  required String home,
  List<DirectoryEntry> crumbs = const <DirectoryEntry>[],
  List<DirectoryEntry> entries = const <DirectoryEntry>[],
  bool truncated = false,
}) =>
    <String, dynamic>{
      'path': path,
      'home': home,
      'crumbs': [for (final c in crumbs) c.toJson()],
      'entries': [for (final e in entries) e.toJson()],
      'truncated': truncated,
    };

/// 目录域错误 map(放进路由即命中错误分支)。
Map<String, dynamic> _err(String code, String message, {String path = ''}) =>
    <String, dynamic>{'code': code, 'message': message, 'details': {'path': path}};

/// widget 测试用假 DirectoryBrowserView:可编程 emit 快照 + 记录调用。
class _FakeBrowseStore implements DirectoryBrowserView {
  final _controller = StreamController<DirectoryBrowserSnapshot>.broadcast();
  DirectoryBrowserSnapshot _current = const DirectoryBrowserSnapshot(
      currentPath: null, home: '', crumbs: <DirectoryEntry>[],
      entries: <DirectoryEntry>[], truncated: false, loading: false,
      error: null, failedPath: null, showHidden: false);

  final List<String?> listCalls = <String?>[];
  final List<({String path, String name})> createCalls =
      <({String path, String name})>[];
  final List<bool> hiddenCalls = <bool>[];

  /// 一次性注入:listDirectory / createDirectory 抛出的异常。
  Object? listError;
  Object? createError;

  void emit(DirectoryBrowserSnapshot s) {
    _current = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  @override
  Stream<DirectoryBrowserSnapshot> get snapshots => _controller.stream;

  @override
  DirectoryBrowserSnapshot get current => _current;

  @override
  bool get showHidden => _current.showHidden;

  @override
  Future<HostListDirectoryValue> listDirectory({String? path}) async {
    listCalls.add(path);
    final err = listError;
    if (err != null) {
      listError = null;
      throw err;
    }
    return HostListDirectoryValue(
      path: path ?? '/home',
      home: '/home',
      crumbs: const <DirectoryEntry>[],
      entries: const <DirectoryEntry>[],
      truncated: false,
    );
  }

  @override
  Future<HostCreateDirectoryValue> createDirectory(String path, String name) async {
    createCalls.add((path: path, name: name));
    final err = createError;
    if (err != null) {
      createError = null;
      throw err;
    }
    return HostCreateDirectoryValue(path: '$path/$name');
  }

  @override
  void setShowHidden(bool value) {
    hiddenCalls.add(value);
    emit(DirectoryBrowserSnapshot(
      currentPath: _current.currentPath,
      home: _current.home,
      crumbs: _current.crumbs,
      entries: _current.entries,
      truncated: _current.truncated,
      loading: _current.loading,
      error: _current.error,
      failedPath: _current.failedPath,
      showHidden: value,
    ));
  }

  Future<void> dispose() => _controller.close();
}

/// 快照便捷构造。
DirectoryBrowserSnapshot _snapFor({
  String? currentPath,
  String home = '',
  List<DirectoryEntry> crumbs = const <DirectoryEntry>[],
  List<DirectoryEntry> entries = const <DirectoryEntry>[],
  bool truncated = false,
  bool loading = false,
  String? error,
  String? failedPath,
  bool showHidden = false,
}) =>
    DirectoryBrowserSnapshot(
      currentPath: currentPath,
      home: home,
      crumbs: crumbs,
      entries: entries,
      truncated: truncated,
      loading: loading,
      error: error,
      failedPath: failedPath,
      showHidden: showHidden,
    );

/// 泵一个带「打开浏览」按钮的 app 并点开 sheet。
Future<void> _openSheet(WidgetTester tester, _FakeBrowseStore fake,
    {List<String>? confirmations}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDirectoryBrowseSheet(
              context,
              store: fake,
              onConfirm: (p) => confirmations?.add(p),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('DirectoryBrowserStore 域', () {
    late _FakeHost host;
    late ApiClient api;
    late DirectoryBrowserStore store;
    late HttpOverrides? previousOverrides;

    setUp(() async {
      // 本文件含 testWidgets → flutter_test binding 在注册期装上了 mock
      // HttpClient(整文件生效);域测试需要真实 socket,先摘掉,tearDown 恢复。
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      host = await _FakeHost.start();
      api = ApiClient(baseUri: host.baseUri);
      store = DirectoryBrowserStore(api: api);
    });

    tearDown(() async {
      await store.dispose();
      api.dispose();
      await host.stop();
      HttpOverrides.global = previousOverrides;
    });

    test('listDirectory 缺省 → payload 无 path,装载家目录', () async {
      host.listRoutes['<home>'] = _listing(
        path: '/home',
        home: '/home',
        entries: [_entry('docs', '/home/docs'), _entry('notes.txt', '/home/notes.txt')],
      );
      final value = await store.listDirectory();
      expect(host.calls.single.method, 'host.listDirectory');
      expect(host.calls.single.payload.containsKey('path'), isFalse);
      expect(value.path, '/home');
      expect(store.current.currentPath, '/home');
      expect(store.current.home, '/home');
      expect(store.current.entries.map((e) => e.name).toList(),
          ['docs', 'notes.txt']);
      expect(store.listCalls, 1);
    });

    test('listDirectory 带 path → payload 带 path,下钻 + 面包屑落地', () async {
      host.listRoutes['<home>'] = _listing(
          path: '/home', home: '/home', entries: [_entry('a', '/home/a')]);
      await store.listDirectory();
      host.listRoutes['/home/a'] = _listing(
        path: '/home/a',
        home: '/home',
        crumbs: [_entry('home', '/home'), _entry('a', '/home/a')],
        entries: [_entry('b', '/home/a/b')],
      );
      await store.listDirectory(path: '/home/a');
      final last = host.calls.last;
      expect(last.method, 'host.listDirectory');
      expect(last.payload['path'], '/home/a');
      expect(store.current.currentPath, '/home/a');
      expect(store.current.crumbs.map((c) => c.name).toList(), ['home', 'a']);
      expect(store.current.entries.single.name, 'b');
    });

    test('下钻过回跳后「目录在前」:已知目录优先,组内服务端顺序', () async {
      // 服务端顺序:f1 在前,a 在中间 —— 首次装载原样;
      // 下钻 a 后再回跳,a 因「已下钻过」提到最前。
      host.listRoutes['<home>'] = _listing(path: '/home', home: '/home', entries: [
        _entry('f1', '/home/f1'),
        _entry('a', '/home/a'),
        _entry('f2', '/home/f2'),
      ]);
      await store.listDirectory();
      expect(store.current.entries.map((e) => e.path).toList(),
          ['/home/f1', '/home/a', '/home/f2']);
      host.listRoutes['/home/a'] = _listing(
        path: '/home/a', home: '/home',
        crumbs: [_entry('home', '/home'), _entry('a', '/home/a')],
        entries: [],
      );
      await store.listDirectory(path: '/home/a');
      await store.listDirectory();
      expect(store.current.entries.map((e) => e.path).toList(),
          ['/home/a', '/home/f1', '/home/f2']);
    });

    test('下钻失败不清空当前层:error/failedPath 上报,rethrow 原异常', () async {
      host.listRoutes['<home>'] = _listing(
          path: '/home', home: '/home', entries: [_entry('a', '/home/a')]);
      await store.listDirectory();
      host.listRoutes['/home/a'] = _err('directory-unreadable', 'Permission denied', path: '/home/a');
      await expectLater(
        store.listDirectory(path: '/home/a'),
        throwsA(isA<RpcBusinessError>()),
      );
      final s = store.current;
      expect(s.currentPath, '/home'); // 层不变
      expect(s.entries.map((e) => e.path).toList(), ['/home/a']); // 条目保持
      expect(s.error, contains('无法读取「/home/a」'));
      expect(s.error, contains('Permission denied'));
      expect(s.failedPath, '/home/a');
      expect(s.loading, isFalse);
    });

    test('重试路径 = failedPath:失败后重试成功并清错误', () async {
      host.listRoutes['<home>'] = _listing(path: '/home', home: '/home', entries: []);
      await store.listDirectory();
      host.listRoutes['/home/x'] = _err('directory-unreadable', '', path: '/home/x');
      await expectLater(
        store.listDirectory(path: '/home/x'),
        throwsA(isA<RpcBusinessError>()),
      );
      expect(store.current.failedPath, '/home/x');
      host.listRoutes['/home/x'] = _listing(
        path: '/home/x', home: '/home',
        crumbs: [_entry('home', '/home'), _entry('x', '/home/x')],
        entries: [],
      );
      await store.listDirectory(path: store.current.failedPath!);
      expect(store.current.currentPath, '/home/x');
      expect(store.current.error, isNull);
      expect(store.current.failedPath, isNull);
    });

    test('隐藏过滤:默认过滤 hidden,开关揭开', () async {
      host.listRoutes['<home>'] = _listing(path: '/home', home: '/home', entries: [
        _entry('.config', '/home/.config', hidden: true),
        _entry('docs', '/home/docs'),
        _entry('.bashrc', '/home/.bashrc', hidden: true),
      ]);
      await store.listDirectory();
      expect(store.current.showHidden, isFalse);
      expect(store.current.entries.map((e) => e.name).toList(), ['docs']);
      store.setShowHidden(true);
      expect(store.current.showHidden, isTrue);
      expect(store.current.entries.map((e) => e.name).toList(),
          ['.config', 'docs', '.bashrc']);
    });

    test('createDirectory 信封:payload {path,name},成功返回创建路径', () async {
      host.listRoutes['<home>'] = _listing(path: '/home', home: '/home', entries: []);
      await store.listDirectory();
      final value = await store.createDirectory('/home', 'newdir');
      final call = host.calls.last;
      expect(call.method, 'host.createDirectory');
      expect(call.payload, {'path': '/home', 'name': 'newdir'});
      expect(value.path, '/home/newdir');
      expect(store.createCalls, 1);
    });

    test('createDirectory 冲突 directory-exists → RpcBusinessError(RpcErrorDirectoryExists)',
        () async {
      host.createRoutes['/home|dup'] =
          _err('directory-exists', 'already exists', path: '/home/dup');
      await expectLater(
        store.createDirectory('/home', 'dup'),
        throwsA(isA<RpcBusinessError>().having(
            (e) => e.error, 'error', isA<RpcErrorDirectoryExists>())),
      );
      expect(store.createCalls, 1);
    });

    test('createDirectory 失败 directory-create-failed → 映射「创建文件夹失败」', () async {
      host.createRoutes['/home|locked'] =
          _err('directory-create-failed', '', path: '/home/locked');
      try {
        await store.createDirectory('/home', 'locked');
        fail('should throw');
      } on RpcBusinessError catch (e) {
        expect(directoryCreateErrorMessage(e), '创建文件夹失败');
      }
    });

    test('错误消息映射:不可读/冲突/载波/超时', () {
      final unreadable = RpcBusinessError(RpcErrorDirectoryUnreadable(
          message: 'perm', details: const HostCreateDirectoryValue(path: '/x')));
      expect(directoryListErrorMessage(unreadable, path: '/x'),
          '无法读取「/x」: perm');
      final exists = RpcBusinessError(RpcErrorDirectoryExists(
          message: '', details: const HostCreateDirectoryValue(path: '/x')));
      expect(directoryCreateErrorMessage(exists), '已存在同名文件夹');
      expect(directoryListErrorMessage(const CarrierError('conn refused')),
          '无法连接主机: conn refused');
      expect(
          directoryListErrorMessage(
              const ApiTimeout('m', Duration(seconds: 1))),
          '加载目录超时');
    });

    test('广播流:list 成功/失败/开关各推快照', () async {
      final emissions = <DirectoryBrowserSnapshot>[];
      final sub = store.snapshots.listen(emissions.add);
      addTearDown(() => sub.cancel());
      host.listRoutes['<home>'] = _listing(
          path: '/home', home: '/home', entries: [_entry('a', '/home/a')]);
      await store.listDirectory();
      host.listRoutes['/home/bad'] =
          _err('directory-unreadable', '', path: '/home/bad');
      await expectLater(
        store.listDirectory(path: '/home/bad'),
        throwsA(isA<RpcBusinessError>()),
      );
      store.setShowHidden(true);
      // broadcast 流事件在微任务里投递,flush 后再断言。
      await Future<void>.delayed(Duration.zero);
      // loading, ok, loading, fail, toggle = 5 次广播。
      expect(emissions.length, greaterThanOrEqualTo(5));
      expect(emissions.first.loading, isTrue);
      expect(emissions.any((s) => s.error != null), isTrue);
      expect(emissions.last.showHidden, isTrue);
    });
  });

  group('DirectoryBrowseSheet widget(360dp 窄屏)', () {
    void narrow(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('打开即装载家目录;条目渲染;行高≥48', (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      await _openSheet(tester, fake);

      // 进入即装载家目录(缺省 path)。
      expect(fake.listCalls, [null]);

      fake.emit(_snapFor(
        home: '/home', currentPath: '/home',
        entries: [_entry('docs', '/home/docs'), _entry('notes.txt', '/home/notes.txt')],
      ));
      await tester.pumpAndSettle();
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);

      // 行高 ≥48(移动可用性硬性)。
      final row = tester.getSize(find.byKey(const ValueKey('dir-row-/home/docs')));
      expect(row.height, greaterThanOrEqualTo(48));
    });

    testWidgets('单列下钻:点行 → listDirectory(path);快照更新渲染子层', (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      await _openSheet(tester, fake);
      fake.emit(_snapFor(
          home: '/home', currentPath: '/home', entries: [_entry('a', '/home/a')]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('dir-row-/home/a')));
      await tester.pump();
      expect(fake.listCalls.last, '/home/a');

      fake.emit(_snapFor(
        home: '/home', currentPath: '/home/a',
        crumbs: [_entry('home', '/home'), _entry('a', '/home/a')],
        entries: [_entry('b', '/home/a/b')],
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dir-row-/home/a/b')), findsOneWidget);
      expect(find.byKey(const ValueKey('dir-row-/home/a')), findsNothing);
    });

    testWidgets('失败态内联 + 重试:错误横幅显示,重试重发 failedPath', (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      await _openSheet(tester, fake);
      fake.emit(_snapFor(
          home: '/home', currentPath: '/home', entries: [_entry('a', '/home/a')]));
      await tester.pumpAndSettle();

      // 下钻失败:error 快照不清空当前层条目。
      fake.emit(_snapFor(
        home: '/home', currentPath: '/home',
        entries: [_entry('a', '/home/a')],
        error: '无法读取「/home/x」: perm',
        failedPath: '/home/x',
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法读取「/home/x」'), findsOneWidget);
      // 条目仍在(错误不清空当前层)。
      expect(find.byKey(const ValueKey('dir-row-/home/a')), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(fake.listCalls.last, '/home/x');
    });

    testWidgets('隐藏开关常显:切换后 showHidden 更新', (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      await _openSheet(tester, fake);
      fake.emit(_snapFor(
          home: '/home', currentPath: '/home', entries: [_entry('docs', '/home/docs')]));
      await tester.pumpAndSettle();
      expect(find.text('显示隐藏条目'), findsOneWidget);
      await tester.tap(find.text('显示隐藏条目'));
      await tester.pumpAndSettle();
      expect(fake.hiddenCalls, [true]);
      expect(fake.showHidden, isTrue);
    });

    testWidgets('新建文件夹:输入+创建 → createDirectory(current,name);成功刷新当前层',
        (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      await _openSheet(tester, fake);
      fake.emit(_snapFor(home: '/home', currentPath: '/home', entries: []));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'newdir');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(fake.createCalls, hasLength(1));
      expect(fake.createCalls.single.path, '/home');
      expect(fake.createCalls.single.name, 'newdir');
      // 成功后刷新当前层(新文件夹出现),输入清空。
      expect(fake.listCalls.last, '/home');
      expect(find.text('newdir'), findsNothing);
    });

    testWidgets('新建文件夹冲突:错误在输入区下方提示', (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      await _openSheet(tester, fake);
      fake.emit(_snapFor(home: '/home', currentPath: '/home', entries: []));
      await tester.pumpAndSettle();

      fake.createError = RpcBusinessError(RpcErrorDirectoryExists(
          message: '', details: const HostCreateDirectoryValue(path: '/home/dup')));
      await tester.enterText(find.byType(TextField), 'dup');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(find.text('已存在同名文件夹'), findsOneWidget);
    });

    testWidgets('选择此目录:onConfirm 回调当前层路径并关闭;取消不回调', (tester) async {
      narrow(tester);
      final fake = _FakeBrowseStore();
      addTearDown(fake.dispose);
      final confirmations = <String>[];
      await _openSheet(tester, fake, confirmations: confirmations);
      fake.emit(_snapFor(
        home: '/home', currentPath: '/home/a',
        crumbs: [_entry('home', '/home'), _entry('a', '/home/a')],
        entries: [],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('选择此目录'));
      await tester.pumpAndSettle();
      expect(confirmations, ['/home/a']);
      expect(find.text('选择目录'), findsNothing); // sheet 已关闭

      // 取消不回调。
      await _openSheet(tester, fake, confirmations: confirmations);
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(confirmations, ['/home/a']);
      expect(find.text('选择目录'), findsNothing);
    });
  });
}
