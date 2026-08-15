// JobStore 域测试(W1-B):帧收敛、排序、角标、耗时边界、clock 注入;
// 附 360dp 窄屏 widget 测试(行高≥44、无任务不渲染触发器)。
// 模式:自建最小假主机(describe + 双 WS 下行),不 import 共享 helper。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/job_store.dart';
import 'package:singleman/ui/jobs_sheet.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 最小假主机:host.describe + 双 WS 下行;可编程推 mux 帧。
class _FakeHost {
  _FakeHost._(this._server);
  final HttpServer _server;
  final List<WebSocket> _mux = <WebSocket>[];
  final List<WebSocket> _host = <WebSocket>[];
  int _frameNo = 0;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': {
          'ok': true,
          'value': {
            'version': '0.0.1-fake',
            'cwd': '/tmp/fake',
            'provider': 'fake',
            'model': 'fake-model',
            'attachedSessions': 0,
            'canOpenPath': false,
          },
        },
      }));
      await req.response.close();
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

  /// 推一条 session/jobs 帧(server-request 信封,mux 流)。
  void pushJobs(String sessionId, List<Map<String, dynamic>> jobs) {
    _frameNo += 1;
    final payload = <String, dynamic>{
      'type': 'session/jobs',
      'sessionId': sessionId,
      'jobs': jobs,
    };
    for (final ws in _mux) {
      ws.add(jsonEncode({
        'type': 'server-request',
        'rpcId': 'fake-jobs-$_frameNo',
        'method': 'session/jobs',
        'payload': payload,
      }));
    }
  }

  /// 推一条任意 mux 帧(验证非 jobs 帧被忽略)。
  void pushFrame(Map<String, dynamic> payload) {
    _frameNo += 1;
    for (final ws in _mux) {
      ws.add(jsonEncode({
        'type': 'server-request',
        'rpcId': 'fake-frame-$_frameNo',
        'method': payload['type'],
        'payload': payload,
      }));
    }
  }

  Future<void> stop() async {
    for (final ws in [..._mux, ..._host]) {
      try {
        await ws.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

/// TaskView 的 JSON 便捷构造(wire 形状)。
Map<String, dynamic> job({
  required String id,
  required String kind,
  required String label,
  required String status,
  String? detail,
  required int startedAt,
  int? finishedAt,
}) =>
    <String, dynamic>{
      'id': id,
      'kind': kind,
      'label': label,
      'status': status,
      if (detail != null) 'detail': detail,
      'startedAt': startedAt,
      if (finishedAt != null) 'finishedAt': finishedAt,
    };

/// widget 测试用假 JobStoreView(广播快照,可编程 emit)。
class _FakeJobStore implements JobStoreView {
  final _controller = StreamController<Map<String, List<JobEntry>>>.broadcast();
  Map<String, List<JobEntry>> _current = <String, List<JobEntry>>{};

  void emit(Map<String, List<JobEntry>> next) {
    _current = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  @override
  Stream<Map<String, List<JobEntry>>> get jobs => _controller.stream;

  @override
  List<JobEntry> jobsFor(String sessionId) =>
      List<JobEntry>.unmodifiable(_current[sessionId] ?? const <JobEntry>[]);

  @override
  int badgeFor(String sessionId) =>
      jobsFor(sessionId).where((e) => e.active).length;

  Future<void> dispose() => _controller.close();
}

/// TaskView 便捷构造(widget 测试用)。
TaskView taskView({
  required String id,
  required String kind,
  required String label,
  required String status,
  String? detail,
  required int startedAt,
  int? finishedAt,
}) =>
    TaskView(
      id: id,
      kind: kind,
      label: label,
      status: status,
      detail: detail,
      startedAt: startedAt,
      finishedAt: finishedAt,
    );

void main() {
  group('JobStore 域', () {
    late _FakeHost host;
    late ConnectionController controller;
    late ApiClient api;
    late JobStore store;
    late int fakeNow;
    late HttpOverrides? previousOverrides;

    int clock() => fakeNow;

    setUp(() async {
      // 本文件含 testWidgets → flutter_test binding 在注册期装上了 mock
      // HttpClient(整文件生效);域测试需要真实 socket,先摘掉,tearDown 恢复。
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      host = await _FakeHost.start();
      fakeNow = 200000;
      controller = ConnectionController(
        baseUri: host.baseUri,
        initialBackoff: const Duration(milliseconds: 30),
        maxBackoff: const Duration(milliseconds: 150),
        probeTimeout: const Duration(milliseconds: 400),
      );
      api = ApiClient(baseUri: host.baseUri);
      store = JobStore(api: api, connection: controller, clock: clock);
      controller.start();
      await controller.snapshots
          .firstWhere((s) => s.phase == ConnectionPhase.ready)
          .timeout(const Duration(seconds: 3));
    });

    tearDown(() async {
      await store.dispose();
      await controller.dispose();
      api.dispose();
      await host.stop();
      HttpOverrides.global = previousOverrides;
    });

    /// 推帧并等 store 广播(先订阅再推,避免 broadcast 丢事件)。
    Future<void> pushAndWait(
        String sessionId, List<Map<String, dynamic>> jobs) async {
      final emission = store.jobs.first.timeout(const Duration(seconds: 3));
      host.pushJobs(sessionId, jobs);
      await emission;
    }

    test('session/jobs 帧整帧收敛:替换而非追加', () async {
      await pushAndWait('session-s1', [
        job(id: 'a', kind: 'bash', label: 'build', status: 'running', startedAt: 1000),
        job(id: 'b', kind: 'bash', label: 'test', status: 'success', startedAt: 1000, finishedAt: 9000),
      ]);
      expect(store.jobsFor('session-s1'), hasLength(2));

      // 下一帧只含 b:整帧替换,a 被移除(终态行也在其中,一并消失)。
      await pushAndWait('session-s1', [
        job(id: 'b', kind: 'bash', label: 'test', status: 'success', startedAt: 1000, finishedAt: 9000),
      ]);
      final after = store.jobsFor('session-s1');
      expect(after, hasLength(1));
      expect(after.single.task.id, 'b');
    });

    test('排序:活跃在前,活跃按 startedAt 升序', () async {
      await pushAndWait('session-s1', [
        job(id: 'done', kind: 'bash', label: 'done', status: 'success', startedAt: 5000, finishedAt: 9000),
        job(id: 'r1', kind: 'bash', label: 'r1', status: 'running', startedAt: 1000),
        job(id: 's1', kind: 'bash', label: 's1', status: 'stopping', startedAt: 2000),
        job(id: 'r2', kind: 'bash', label: 'r2', status: 'running', startedAt: 3000),
      ]);
      final ids = store.jobsFor('session-s1').map((e) => e.task.id).toList();
      expect(ids, ['r1', 's1', 'r2', 'done']);
    });

    test('排序:终态按 finishedAt 降序', () async {
      await pushAndWait('session-s1', [
        job(id: 'ok', kind: 'bash', label: 'ok', status: 'success', startedAt: 1000, finishedAt: 3000),
        job(id: 'err', kind: 'bash', label: 'err', status: 'error', startedAt: 2000, finishedAt: 9000),
        job(id: 'cancel', kind: 'bash', label: 'cancel', status: 'cancelled', startedAt: 1500, finishedAt: 5000),
      ]);
      final ids = store.jobsFor('session-s1').map((e) => e.task.id).toList();
      expect(ids, ['err', 'cancel', 'ok']);
    });

    test('毫秒并列按帧内顺序(稳定排序)', () async {
      await pushAndWait('session-s1', [
        job(id: 'ra', kind: 'bash', label: 'ra', status: 'running', startedAt: 1000),
        job(id: 'rb', kind: 'bash', label: 'rb', status: 'running', startedAt: 1000),
        job(id: 'ta', kind: 'bash', label: 'ta', status: 'success', startedAt: 100, finishedAt: 5000),
        job(id: 'tb', kind: 'bash', label: 'tb', status: 'success', startedAt: 200, finishedAt: 5000),
      ]);
      final ids = store.jobsFor('session-s1').map((e) => e.task.id).toList();
      // 活跃并列按帧内顺序 ra,rb;终态同 finishedAt 按帧内顺序 ta,tb。
      expect(ids, ['ra', 'rb', 'ta', 'tb']);
    });

    test('角标 = running+stopping 计数,为 0 无角标', () async {
      await pushAndWait('session-s1', [
        job(id: 'r', kind: 'bash', label: 'r', status: 'running', startedAt: 1000),
        job(id: 's', kind: 'bash', label: 's', status: 'stopping', startedAt: 2000),
        job(id: 'ok', kind: 'bash', label: 'ok', status: 'success', startedAt: 3000, finishedAt: 9000),
      ]);
      expect(store.badgeFor('session-s1'), 2);

      await pushAndWait('session-s1', [
        job(id: 'ok', kind: 'bash', label: 'ok', status: 'success', startedAt: 3000, finishedAt: 9000),
      ]);
      expect(store.badgeFor('session-s1'), 0);
    });

    test('耗时:活跃 = now-startedAt(clock 注入)', () async {
      fakeNow = 200000;
      await pushAndWait('session-s1', [
        job(id: 'r', kind: 'bash', label: 'r', status: 'running', startedAt: 120000),
      ]);
      expect(store.jobsFor('session-s1').single.elapsedMs, 80000);
    });

    test('耗时:终态 = finishedAt-startedAt;缺 finishedAt 读 0', () async {
      await pushAndWait('session-s1', [
        job(id: 'ok', kind: 'bash', label: 'ok', status: 'success', startedAt: 100000, finishedAt: 150000),
        job(id: 'weird', kind: 'bash', label: 'weird', status: 'error', startedAt: 100000),
      ]);
      final byId = {for (final e in store.jobsFor('session-s1')) e.task.id: e};
      expect(byId['ok']!.elapsedMs, 50000);
      expect(byId['weird']!.elapsedMs, 0);
    });

    test('耗时格式化:>1h 停在小时,其余 m:ss', () {
      expect(formatJobDuration(2 * 3600000 + 5 * 60000), '2h');
      expect(formatJobDuration(90 * 60000), '1h');
      expect(formatJobDuration(65 * 1000), '1:05');
      expect(formatJobDuration(5 * 1000), '0:05');
      expect(formatJobDuration(-10), '0:00');
    });

    test('非 jobs 帧忽略(不产生条目也不报错)', () async {
      host.pushFrame({
        'type': 'session/event',
        'sessionId': 'session-s1',
        'event': {'type': 'user/message', 'seq': 1, 'time': 1786723605000, 'data': {'n': 1}},
      });
      host.pushFrame({
        'type': 'session/subscribed',
        'sessionId': 'session-s1',
        'lastSeq': 1,
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(store.jobsFor('session-s1'), isEmpty);
    });

    test('多会话隔离', () async {
      await pushAndWait('session-s1', [
        job(id: 'a', kind: 'bash', label: 'a', status: 'running', startedAt: 1000),
      ]);
      await pushAndWait('session-s2', [
        job(id: 'b', kind: 'bash', label: 'b', status: 'success', startedAt: 1000, finishedAt: 9000),
      ]);
      expect(store.jobsFor('session-s1').single.task.id, 'a');
      expect(store.jobsFor('session-s2').single.task.id, 'b');
      expect(store.badgeFor('session-s1'), 1);
      expect(store.badgeFor('session-s2'), 0);
    });

    test('广播流:每次帧后推整表快照', () async {
      final snapshotFuture = store.jobs.first.timeout(const Duration(seconds: 3));
      host.pushJobs('session-s1', [
        job(id: 'a', kind: 'bash', label: 'a', status: 'running', startedAt: 1000),
      ]);
      final snap = await snapshotFuture;
      expect(snap.keys, contains('session-s1'));
      expect(snap['session-s1']!.single.task.id, 'a');
      // 快照与 currentJobs 一致。
      expect(snap['session-s1'], store.currentJobs['session-s1']);
    });

    test('终态行保留(失败 detail 是唯一可读处),直到下一帧不再含它', () async {
      await pushAndWait('session-s1', [
        job(id: 'r', kind: 'bash', label: 'r', status: 'running', startedAt: 1000),
        job(id: 'f', kind: 'bash', label: 'f', status: 'error',
            detail: 'exit 127: command not found', startedAt: 500, finishedAt: 700),
      ]);
      // 终态失败行不因排序/过滤被丢弃。
      expect(store.jobsFor('session-s1'), hasLength(2));
      expect(store.jobsFor('session-s1').last.task.detail, contains('exit 127'));

      // 下一帧不再含 f → 整帧替换移除。
      await pushAndWait('session-s1', [
        job(id: 'r', kind: 'bash', label: 'r', status: 'running', startedAt: 1000),
      ]);
      final ids = store.jobsFor('session-s1').map((e) => e.task.id).toList();
      expect(ids, ['r']);
    });
  });

  group('JobsTrigger widget(360dp 窄屏)', () {
    testWidgets('无任务完全不渲染触发器', (tester) async {
      final fake = _FakeJobStore();
      addTearDown(fake.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: JobsTrigger(store: fake, sessionId: 'session-s1'),
        ),
      ));
      expect(find.byIcon(Icons.work_outline), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('360dp 窄屏:行高≥44、角标、弹层开合、每秒走表', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var fakeNow = 200000;
      final fake = _FakeJobStore();
      addTearDown(fake.dispose);
      fake.emit({
        'session-s1': [
          JobEntry(
            task: taskView(id: 'r1', kind: 'bash', label: 'build', status: 'running', startedAt: 190000),
            active: true,
            elapsedMs: 10000,
          ),
          JobEntry(
            task: taskView(id: 'd1', kind: 'bash', label: 'deploy', status: 'success', startedAt: 100000, finishedAt: 150000),
            active: false,
            elapsedMs: 50000,
          ),
        ],
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: JobsTrigger(store: fake, sessionId: 'session-s1', clock: () => fakeNow),
          ),
        ),
      ));

      // 有任务 → 渲染触发器 + 角标(1 个 running)。
      expect(find.byIcon(Icons.work_outline), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      // 打开弹层。
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('后台任务'), findsOneWidget);

      // 行高 ≥44(移动可用性硬性)。
      final row1 = tester.getSize(find.byKey(const ValueKey('job-row-r1')));
      final row2 = tester.getSize(find.byKey(const ValueKey('job-row-d1')));
      expect(row1.height, greaterThanOrEqualTo(44));
      expect(row2.height, greaterThanOrEqualTo(44));

      // detail 取代状态词:失败行无 detail,状态词 success 在徽章中。
      expect(find.text('success'), findsOneWidget);

      // 活跃行耗时每秒走表:推进 1s 后耗时文本变化(10s → 11s)。
      fakeNow = 201000;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:11'), findsOneWidget);

      // 弹层关闭即停表:点遮罩关闭,再推进 1s 不报错(定时器已取消)。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.textContaining('后台任务'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
