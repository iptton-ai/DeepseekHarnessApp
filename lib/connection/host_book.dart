// 主机簿协调器(方案 A 多主机,2026-08-16):配对 upsert / 切换 / 删除的
// 唯一变更通路 —— 维护簿一致性(活动指针有效、同网关幂等去重)+ 持久化
// + ValueNotifier 通知 UI(设置页主机列表实时重建)。
//
// 单活动语义:簿只记数据,「切到哪台就整代重装到哪台」由 main.dart 的
// reboot 闭包实现(与 onLoginDone 换 base 重装同一条路径)。
import 'package:flutter/foundation.dart';

import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/remote_auth.dart';

class HostCoordinator {
  HostCoordinator(this._store);

  final CredentialStore _store;
  final _book = ValueNotifier<HostBook>(const HostBook());

  /// 主机簿(监听以重建 UI;boot 后 hydrate 一次即真)。
  ValueListenable<HostBook> get book => _book;

  Future<void> hydrate() async {
    try {
      _book.value = await _store.load();
    } on Object {
      // 读失败按空簿处理(重新配对),不崩。
    }
  }

  /// 配对/登录成功 → upsert 条目并激活。同网关重复配对只刷新令牌/机器名。
  Future<StoredCredentials> adopt(RemoteLoginSuccess success) async {
    final next = _book.value.upsert(StoredCredentials(
      id: hostIdForBase(success.baseUri),
      baseUri: success.baseUri,
      token: success.token,
      hostLabel: success.hostLabel,
    ));
    await _persist(next);
    return next.active!;
  }

  /// 切换活动主机。id 不命中任何条目时簿不变(防误切)。
  Future<StoredCredentials?> switchTo(String id) async {
    final next = _book.value.withActive(id);
    if (identical(next, _book.value)) return _book.value.active;
    await _persist(next);
    return next.active;
  }

  /// 删除主机条目;若删的是活动条目,指针自动滑到剩余首条(簿空则 null)。
  Future<StoredCredentials?> remove(String id) async {
    await _persist(_book.value.remove(id));
    return _book.value.active;
  }

  Future<void> _persist(HostBook next) async {
    _book.value = next;
    await _store.save(next);
  }
}
