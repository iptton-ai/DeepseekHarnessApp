// M4:goal 六方法 + skill 目录 + 斜杠 prompt 生成。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/goal_store.dart';

import '../helpers/fake_dsh_host.dart';

void main() {
  late FakeDshHost host;
  late ApiClient api;
  late GoalStore goals;
  late SkillCatalog skills;

  setUp(() async {
    host = await FakeDshHost.start();
    api = ApiClient(baseUri: host.baseUri);
    goals = GoalStore(api: api);
    skills = SkillCatalog(api: api);
  });

  tearDown(() async {
    api.dispose();
    await host.stop();
  });

  test('goal.create returns ref; ops bump revision', () async {
    final r1 = await goals.create('完成某事', maxRounds: 5);
    expect(r1.id, isNotEmpty);
    expect(r1.revision, 1);
    final r2 = await goals.pause(r1);
    expect(r2.revision, 2);
    final r3 = await goals.resume(r2);
    expect(r3.revision, 3);
    final r4 = await goals.complete(r3);
    expect(r4.revision, 4);
    final r5 = await goals.edit(r4, objective: '改一下');
    expect(r5.revision, 5);
    await goals.clear(); // 无引用,不抛即过
  });

  test('skill.list caches; promptFor builds slash command text', () async {
    // skill.list 按 sessionId 寻址(实测 rc.6:缺参 bad-request)。
    final list = await skills.list('session-s1');
    expect(list, hasLength(2));
    expect(list.first.name, 'deploy');
    expect(list.first.whenToUse, isNotNull);
    expect(list.last.modelInvocable, isFalse);
    // 缓存:第二次不再打网络(无新请求即返回同实例)。
    final again = await skills.list('session-s1');
    expect(again, same(list));
    // 斜杠命令文本。
    expect(skills.promptFor('deploy'), '/deploy');
    expect(skills.promptFor('deploy', 'prod 环境'), '/deploy prod 环境');
  });
}
