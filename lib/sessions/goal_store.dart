// GoalStore(M4):goal 六方法。goal 是目标对象的引用操作面(id+revision 乐观锁),
// create/edit/pause/resume/complete 各回 GoalRef(revision 递增);clear 无引用。
// SkillMenu:skill.list 一次拉取;/name 调用即普通 prompt(无专线,DSH-PROTOCOL §5)。
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class GoalStore {
  GoalStore({required this.api});
  final ApiClient api;

  Future<GoalRef> create(String objective, {int? maxRounds}) => api.call(
        RpcMethods.goalCreate,
        <String, dynamic>{
          'objective': objective,
          if (maxRounds != null) 'maxRounds': maxRounds,
        },
        parse: GoalCreateValue.fromJson,
      ).then((v) => v.ref);

  Future<GoalRef> edit(GoalRef ref, {String? objective, int? maxRounds}) => api.call(
        RpcMethods.goalEdit,
        <String, dynamic>{
          'goalId': ref.id,
          'revision': ref.revision,
          if (objective != null) 'objective': objective,
          if (maxRounds != null) 'maxRounds': maxRounds,
        },
        parse: GoalEditValue.fromJson,
      ).then((v) => v.ref);

  Future<GoalRef> pause(GoalRef ref) => _refOp(RpcMethods.goalPause, ref);
  Future<GoalRef> resume(GoalRef ref) => _refOp(RpcMethods.goalResume, ref);
  Future<GoalRef> complete(GoalRef ref) => _refOp(RpcMethods.goalComplete, ref);

  Future<GoalRef> _refOp(String method, GoalRef ref) => api.call(
        method,
        <String, dynamic>{'goalId': ref.id, 'revision': ref.revision},
        parse: (j) => GoalRef.fromJson(j['ref'] as Map<String, dynamic>),
      );

  Future<void> clear() => api.call(
        RpcMethods.goalClear,
        <String, dynamic>{},
        parse: GoalClearValue.fromJson,
      );
}

/// skill 目录(M4):名称 + 描述 + whenToUse;调用 = prompt 文本 '/name ...'。
class SkillCatalog {
  SkillCatalog({required this.api});
  final ApiClient api;
  List<SkillEntry>? _cache;

  Future<List<SkillEntry>> list({bool force = false}) {
    if (!force && _cache != null) return Future.value(_cache);
    return api.call(
      RpcMethods.skillList,
      <String, dynamic>{},
      parse: SkillListValue.fromJson,
    ).then((v) => _cache = v.skills);
  }

  /// 生成调用某 skill 的 prompt 文本(斜杠命令 = 单个 '/' 开头文本块)。
  String promptFor(String name, [String? args]) =>
      args == null || args.isEmpty ? '/' + name : '/' + name + ' ' + args;
}
