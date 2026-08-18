// 远程凭证模型与内存实现(M6 远程形态;多主机簿见文件实现头注)。
//
// 纪律:本文件不得 import 任何 Flutter 依赖 —— bin/ 冒烟脚本会经
// remote_auth.dart 传递引入本文件(bin/*.dart 不沾 flutter,PROGRESS 坑表)。
// 文件实现(带 path_provider)在 credentials_path.dart,仅 main.dart 引。
//
// 主机簿(方案 A,2026-08-16):凭证文件存全部已配对网关 + 活动指针;
// 条目 id = 网关地址归一化(hostIdForBase),同一网关重复配对原地更新。
// 旧单对象文件读入时迁移为一元簿。
import 'dart:convert';

/// 主机簿条目(= 一台已配对宿主)。多宿主网关下同一网关地址可有多条 ——
/// 各带不同 hostRef(宿主稳定标识)。
class StoredCredentials {
  const StoredCredentials({
    required this.id,
    required this.baseUri,
    this.token,
    this.hostLabel = '',
    this.hostRef = '',
  });

  /// 条目 id:网关地址归一化([hostIdForBase])+ 宿主标识复合([hostIdFor])。
  /// 同 id 配对 = 原地刷新;同网关不同宿主 = 不同条目。
  final String id;

  final Uri baseUri;

  /// 远程网关的设备令牌;loopback 直连形态恒为 null。
  final String? token;

  /// 配对来源机器名快照(展示用;密码登录/旧凭证为空)。
  final String hostLabel;

  /// 来源宿主稳定标识(rust = 隧道端口字符串;CF = 隧道主机名;旧网关为空)。
  /// 非空时参与条目 id 复合;持久化以便簿重载后保持键稳定。
  final String hostRef;

  @override
  bool operator ==(Object other) =>
      other is StoredCredentials &&
      other.id == id &&
      other.baseUri == baseUri &&
      other.token == token &&
      other.hostLabel == hostLabel &&
      other.hostRef == hostRef;

  @override
  int get hashCode => Object.hash(id, baseUri, token, hostLabel, hostRef);
}

/// 网关地址归一化(条目去重键):scheme/host 小写,默认端口显式化,
/// path/query 不参与(网关永远部署在根路径)。
/// https://a.com ≡ https://a.com:443;http://a.com:80 ≡ http://a.com。
String hostIdForBase(Uri base) {
  final scheme = base.scheme.toLowerCase();
  final host = base.host.toLowerCase();
  // Uri.port 已按 scheme 补默认端口(https→443);0 仅出现在无默认端口的
  // 未知 scheme,兜底 80。
  final port = base.port == 0 ? 80 : base.port;
  return '$scheme://$host:$port';
}

/// 条目 id:同网关多宿主 = 地址归一化 + '#' + 宿主标识复合(2026-08-18
/// 多宿主网关改造)。[hostRef] 为空(旧网关/密码登录)= 裸网关地址(旧语义,
/// 同网关原地刷新)。
String hostIdFor(Uri base, String hostRef) =>
    hostRef.isEmpty ? hostIdForBase(base) : '${hostIdForBase(base)}#$hostRef';

/// 主机簿:全部已配对主机 + 活动指针。
/// 单活动(方案 A):同一时刻只连一台;切换由上层整代重装实现,
/// 簿本身只维护数据一致性。不可变,变更经 upsert/remove/withActive 拷贝。
class HostBook {
  const HostBook({this.hosts = const [], this.activeId});

  final List<StoredCredentials> hosts;
  final String? activeId;

  /// 活动条目。指针缺失/失效时回落首条(迁移与防损语义)。
  StoredCredentials? get active {
    final id = activeId;
    if (id != null) {
      for (final h in hosts) {
        if (h.id == id) return h;
      }
    }
    return hosts.isEmpty ? null : hosts.first;
  }

  /// upsert:同 id 原地替换(保位),新 id 追加尾部;默认激活。
  HostBook upsert(StoredCredentials host, {bool activate = true}) {
    final next = <StoredCredentials>[];
    var replaced = false;
    for (final h in hosts) {
      if (h.id == host.id) {
        next.add(host);
        replaced = true;
      } else {
        next.add(h);
      }
    }
    if (!replaced) next.add(host);
    return HostBook(
      hosts: next,
      activeId: activate || activeId == host.id ? host.id : activeId,
    );
  }

  /// 删除条目;若删的是活动条目,指针滑到剩余首条。
  HostBook remove(String id) {
    final next = [
      for (final h in hosts)
        if (h.id != id) h,
    ];
    var nextActiveId = activeId;
    if (activeId == id) {
      nextActiveId = next.firstOrNull?.id;
    }
    return HostBook(hosts: next, activeId: nextActiveId);
  }

  /// 指定活动条目;id 不命中任何条目时原样返回(防误切)。
  HostBook withActive(String id) {
    for (final h in hosts) {
      if (h.id == id) return HostBook(hosts: hosts, activeId: id);
    }
    return this;
  }

  @override
  bool operator ==(Object other) =>
      other is HostBook &&
      other.activeId == activeId &&
      other.hosts.length == hosts.length &&
      [
        for (var i = 0; i < hosts.length; i++) other.hosts[i] == hosts[i],
      ].every((v) => v);

  @override
  int get hashCode => Object.hash(activeId, Object.hashAll(hosts));
}

/// 凭证存取抽象(测试用内存实现替换)。整簿读写,空簿 = 无凭证。
abstract class CredentialStore {
  Future<HostBook> load();
  Future<void> save(HostBook book);
}

/// 内存实现(测试)。seed 供测试同步播种。
class MemoryCredentialStore implements CredentialStore {
  HostBook _book = const HostBook();

  void seed(HostBook book) => _book = book;

  @override
  Future<HostBook> load() async => _book;

  @override
  Future<void> save(HostBook book) async => _book = book;
}

Map<String, dynamic> _hostToJson(StoredCredentials c) => <String, dynamic>{
  'id': c.id,
  'baseUri': c.baseUri.toString(),
  if (c.token != null) 'token': c.token,
  if (c.hostLabel.isNotEmpty) 'hostLabel': c.hostLabel,
  if (c.hostRef.isNotEmpty) 'hostRef': c.hostRef,
};

/// 主机簿 JSON 编码(v2 形状;文件实现复用)。
String encodeHostBookJson(HostBook book) => jsonEncode(<String, dynamic>{
  'version': 2,
  if (book.activeId != null) 'active': book.activeId,
  'hosts': [for (final h in book.hosts) _hostToJson(h)],
});

StoredCredentials? _hostFromJson(Map<dynamic, dynamic> raw) {
  final baseStr = raw['baseUri'];
  if (baseStr is! String) return null;
  final base = Uri.tryParse(baseStr);
  if (base == null || !base.hasScheme || base.host.isEmpty) return null;
  final token = raw['token'];
  final hostLabel = raw['hostLabel'];
  final hostRef = raw['hostRef'];
  final id = raw['id'];
  return StoredCredentials(
    // id 缺失/非法时由地址重新归一(旧 v2 文件兜底)。
    id: id is String && id.isNotEmpty ? id : hostIdForBase(base),
    baseUri: base,
    token: token is String && token.isNotEmpty ? token : null,
    hostLabel: hostLabel is String ? hostLabel : '',
    hostRef: hostRef is String ? hostRef : '',
  );
}

/// 主机簿 JSON 解析:null = 不可解析(损坏,调用方按空簿处理)。
/// 兼容三形状:v2 簿 / 旧单对象(迁移一元簿)/ 空 hosts 簿。
HostBook? parseHostBookJson(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<dynamic, dynamic>) return null;
  final hostsRaw = decoded['hosts'];
  if (hostsRaw is List) {
    final hosts = <StoredCredentials>[];
    for (final e in hostsRaw) {
      if (e is Map<dynamic, dynamic>) {
        final h = _hostFromJson(e);
        if (h != null) hosts.add(h);
      }
    }
    final active = decoded['active'];
    return HostBook(
      hosts: hosts,
      activeId: active is String && active.isNotEmpty ? active : null,
    );
  }
  // 旧单对象(M6 形状):迁移为一元簿,原凭证即活动主机。
  final legacy = _hostFromJson(decoded);
  if (legacy == null) return null;
  return HostBook(hosts: [legacy], activeId: legacy.id);
}
