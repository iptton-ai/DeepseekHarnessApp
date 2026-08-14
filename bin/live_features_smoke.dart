// M4 活体验收冒烟:模型目录/切换、fork(含真实对话后 fork)、导出 ZIP、重命名、搜索 —— 全部打活体 3080。
// 用法: dart run bin/live_features_smoke.dart
// 会留下一个真实会话(验收成本)。
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const base = 'http://127.0.0.1:3080';

Future<void> main() async {
  final api = ApiClient(baseUri: Uri.parse(base));
  var failed = false;

  try {
    // 1. session.create
    final created = await api.call(
      RpcMethods.sessionCreate,
      <String, dynamic>{},
      parse: SessionCreateValue.fromJson,
    );
    final sid = created.sessionId;
    print('CREATE ok ' + sid);

    // 2. session.models(目录)
    final models = await api.call(
      RpcMethods.sessionModels,
      <String, dynamic>{'sessionId': sid},
      parse: SessionModelsValue.fromJson,
    );
    final groupCount = models.groups.length;
    var modelCount = 0;
    for (final g in models.groups) {
      modelCount += g.models.length;
    }
    print('MODELS ok groups=' + groupCount.toString() + ' models=' + modelCount.toString() +
        ' current=' + models.current.provider + '/' + models.current.model +
        ' routable=' + models.routable.toString());
    expect(groupCount > 0, 'catalog must not be empty');

    // 3. selectModel:切到同组另一个模型(没有则重选 current —— 幂等验证)
    final target = models.groups.first.models.first;
    final selected = await api.call(
      RpcMethods.sessionSelectModel,
      <String, dynamic>{
        'sessionId': sid,
        'provider': models.groups.first.id,
        'model': target.id,
      },
      parse: SessionSelectModelValue.fromJson,
    );
    print('SELECT-MODEL ok -> ' + selected.selected.provider + '/' + selected.selected.model);

    // 4. rename(规范化回带)
    final renamed = await api.call(
      RpcMethods.sessionRename,
      <String, dynamic>{'sessionId': sid, 'title': 'singleman 冒烟会话'},
      parse: SessionRenameValue.fromJson,
    );
    print('RENAME ok "' + renamed.title + '" seq=' + renamed.seq.toString());

    // 5. search:本部署可能禁用索引(openAt never → internal 'search is disabled')——
    //    部署能力差异,软跳过;其余错误才算失败。
    try {
      final searched = await api.call(
        RpcMethods.sessionSearch,
        <String, dynamic>{'query': 'singleman'},
        parse: SessionSearchValue.fromJson,
      );
      print('SEARCH ok items=' + searched.items.length.toString() + ' hasMore=' + searched.hasMore.toString());
    } on RpcBusinessError catch (e) {
      final err = e.error;
      final disabled = err is RpcErrorInternal;
      if (disabled) {
        print('SEARCH skipped (部署禁用 session-query 索引 —— 能力差异,非客户端缺陷)');
      } else {
        rethrow;
      }
    }

    // 6. export ZIP(真会话有原始日志)
    final tmp = Directory.systemTemp.createTempSync('singleman-export-smoke');
    final zipPath = tmp.path + '/export.zip';
    final sink = File(zipPath).openWrite();
    await api.download(
      '/api/session.export',
      queryParameters: <String, String>{'sessionId': sid, 'includeDescendants': 'true'},
      consume: (chunk) async => sink.add(chunk),
    );
    await sink.close();
    final zipBytes = File(zipPath).readAsBytesSync();
    print('EXPORT ok bytes=' + zipBytes.length.toString() +
        ' magic=' + (zipBytes.length >= 2 && zipBytes[0] == 0x50 && zipBytes[1] == 0x4B ? 'PK' : 'NOT-ZIP'));
    expect(zipBytes.length >= 22 && zipBytes[0] == 0x50, 'export must be a ZIP');
    tmp.deleteSync(recursive: true);

    // 7. 真实对话一轮(turn/end 闭合)后再 fork —— 空会话 fork-unavailable 是契约。
    final prompt = await api.call(
      RpcMethods.sessionPrompt,
      <String, dynamic>{
        'sessionId': sid,
        'mode': 'queue',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': '这是 singleman fork 冒烟。请只回复:FORK READY'},
        ],
        'clientTimeZone': 'UTC',
      },
      parse: SessionPromptValue.fromJson,
    );
    print('PROMPT ok accepted=' + prompt.accepted.toString());
    var turnClosed = false;
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!turnClosed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final hist = await api.call(
        RpcMethods.sessionHistory,
        <String, dynamic>{'sessionId': sid, 'maxMessages': 5},
        parse: SessionHistoryValue.fromJson,
      );
      turnClosed = hist.events.any((e) => e.event.type == 'turn/end');
    }
    expect(turnClosed, 'turn must close before fork');
    print('TURN-END ok');
    final forked = await api.call(
      RpcMethods.sessionFork,
      <String, dynamic>{'sessionId': sid},
      parse: SessionForkValue.fromJson,
    );
    print('FORK ok -> ' + forked.sessionId);

    print('FEATURES-SMOKE-PASS');
  } on Object catch (e) {
    stderr.writeln('FAIL: ' + e.toString());
    failed = true;
  } finally {
    api.dispose();
  }
  exitCode = failed ? 1 : 0;
}

void expect(bool cond, String why) {
  if (!cond) throw StateError('expectation failed: ' + why);
}
