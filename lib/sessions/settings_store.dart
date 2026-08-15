// SettingsStore — W1-D settings/credentials/llm 配置域(纯 Dart)。
//
// 契约(docs/audit/conversation.md §1/2/3/6/7 + DSH-PROTOCOL §6):
// - settings.*/credentials.*/llm.discoverModels 是特权方法,仅 loopback 可用
//   (LAN 403);UI 层按 lib/ui/connect_config.dart 的 PrivilegeScope 门控,
//   本 store 不重复判断
// - settings.describe 一次读全部 namespace(快照 + schema + revision)
// - settings.mutate 走路径 op(set/unset),携带 expectedRevision 乐观锁(CAS);
//   冲突 settings-conflict → 自动重读并抛 SettingsConflictError(UI 提示重试)
// - credentials.describe 只报 configured/source/writable,不含值
// - providers 目录 = llm.providers(active=可路由)+ settings 值 + credentials
//   徽标合并:绿点=密钥已配置,红点=引用缺失,无引用=无点
// - 失效事件 settings/document-updated、credentials/updated、
//   llm/adapters-updated 经 host/remote-event 到达 → 收到即重拉
//
// 上层只消费 SettingsStoreView(窄接口),不碰 wire。
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 凭据徽标状态(绿=已配置,红=引用缺失,无=无引用/无法判定)。
enum CredentialStatus { configured, missing, none }

/// 提供方目录条目:llm.providers 视图 + settings 配置值 + credentials 徽标。
class ProviderEntry {
  const ProviderEntry({
    required this.view,
    required this.config,
    required this.credentialRef,
    required this.credentialStatus,
    required this.namespace,
    required this.settingsPath,
    required this.revision,
  });

  final ConfigurableProviderView view;

  /// 该提供方在 settings 里的配置值(settingsPath 下钻后的 map)。
  final Map<String, dynamic> config;

  /// 关联凭据引用(apiKeyEnv);无引用 = null。
  final String? credentialRef;
  final CredentialStatus credentialStatus;

  /// 配置所在的 settings namespace(scope 的 CAS 目标)。
  final String namespace;
  final List<String> settingsPath;

  /// 目录构建时刻的 namespace revision(仅信息;写入走 scope 的新快照)。
  final double revision;

  String get providerId => view.provider;
  String get displayName => view.displayName;

  /// 适配器当前是否服务该 provider(routable)。
  bool get routable => view.active;

  /// 自定义提供方标签(declared == true)。
  bool get custom => view.declared == true;

  bool get configured => credentialStatus == CredentialStatus.configured;
  bool get missingCredential => credentialStatus == CredentialStatus.missing;

  /// 配置字段便捷读(值缺失时返回 null)。
  String? field(String key) {
    final v = config[key];
    return v is String ? v : null;
  }

  /// 配置里的模型数组(元素为 map: id/name/contextWindow/maxTokens)。
  List<Map<String, dynamic>> get models {
    final m = config['models'];
    if (m is List) {
      return [
        for (final e in m)
          if (e is Map<String, dynamic>) e
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}

/// 整体目录快照(providers + namespaces + credentials 徽标)。
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.providers,
    required this.namespaces,
    required this.credentials,
    required this.writable,
    required this.hasDocument,
  });

  final List<ProviderEntry> providers;
  final Map<String, SettingsMutateValue> namespaces;
  final Map<String, CredentialView> credentials;
  final bool writable;
  final bool hasDocument;

  static const empty = SettingsSnapshot(
    providers: <ProviderEntry>[],
    namespaces: <String, SettingsMutateValue>{},
    credentials: <String, CredentialView>{},
    writable: false,
    hasDocument: false,
  );
}

/// CAS 冲突:mutate 被 settings-conflict 拒绝后已自动重读,UI 提示用户重试。
class SettingsConflictError implements Exception {
  const SettingsConflictError(this.namespace, {this.expectedRevision, this.latestRevision});
  final String namespace;
  final double? expectedRevision;
  final double? latestRevision;
  @override
  String toString() =>
      'SettingsConflictError($namespace: expected $expectedRevision, latest $latestRevision)';
}

/// settingsScope(namespace):绑定单命名空间的快照 + 单字段写入(CAS)。
/// 对应 web 端 ctx.settingsScope:每条偏好持 {snapshot, set(field,value), load()}。
class SettingsScope {
  SettingsScope(this._view, this.namespace);
  final SettingsStoreView _view;
  final String namespace;

  /// 当前快照(读时取最新)。
  SettingsMutateValue? get snapshot => _view.namespace(namespace);
  double? get revision => snapshot?.revision;

  /// 重读(失效后调用)。
  Future<void> load() => _view.refresh();

  /// 单字段/多 op 写入;expectedRevision 自动取当前快照(乐观锁)。
  Future<SettingsMutateValue> mutate(List<SettingsPathOp> ops) =>
      _view.mutate(namespace, ops, expectedRevision: revision);

  /// 单字段写入(op set)。
  Future<SettingsMutateValue> setField(List<String> path, Object value) =>
      _view.mutate(namespace, [SettingsPathOpSet(path: path, value: value)], expectedRevision: revision);

  /// 单字段清除(op unset)。
  Future<SettingsMutateValue> unsetField(List<String> path) =>
      _view.mutate(namespace, [SettingsPathOpUnset(path: path)], expectedRevision: revision);
}

/// UI 依赖的窄视图(便于 widget 测试注入假实现,不碰 socket)。
abstract class SettingsStoreView {
  Stream<SettingsSnapshot> get snapshots;
  SettingsSnapshot get current;

  /// 全量重拉目录(describe + providers + credentials)。
  Future<void> refresh();

  SettingsMutateValue? namespace(String ns);

  /// settingsScope(namespace):快照 + revision + 单字段 CAS 写入。
  SettingsScope scope(String namespace);

  /// 写一个 namespace(单字段 op 由调用方拼);冲突自动重读后抛
  /// [SettingsConflictError]。
  Future<SettingsMutateValue> mutate(
    String namespace,
    List<SettingsPathOp> ops, {
    double? expectedRevision,
  });

  Future<void> setCredential(String ref, String value);
  Future<void> unsetCredential(String ref);

  /// 获取可用模型(带未保存的草稿端点/密钥,web 同款语义)。
  Future<LlmDiscoverModelsValue> discoverModels({
    required String settingsNs,
    String? provider,
    String? baseURL,
    String? api,
    String? apiKey,
  });

  /// settings.openDocument(外壳「打开配置文件」;仅 loopback 可达)。
  Future<SettingsOpenDocumentValue> openDocument();

  /// 默认权限预设:从 permission namespace 的 schema 动态读枚举;
  /// 读不到返回 null → UI 隐藏该行(web 同款降级)。
  List<String>? get permissionPresetOptions;

  /// 持有 defaultPreset 字段的 namespace 名(写权限预设用)。
  String? get permissionNamespace;

  /// 当前默认权限预设值(无则 null)。
  String? get currentPermissionPreset;
}

class SettingsStore implements SettingsStoreView {
  SettingsStore({required this.api, required this.connection}) {
    _snapshots = StreamController<SettingsSnapshot>.broadcast();
    _snapshotsSub = connection.snapshots.listen(_onSnapshot);
    _hostSub = connection.hostFrames.listen(_onHostFrame);
    final cur = connection.current;
    // 构造时连接已就绪(如 main 里先 start 后建 store):立即全量重取。
    if (cur != null && cur.phase == ConnectionPhase.ready) {
      _lastReadyGeneration = cur.generation;
      unawaited(refresh().catchError((Object _) {}));
    }
  }

  final ApiClient api;
  final ConnectionController connection;

  @override
  SettingsScope scope(String namespace) => SettingsScope(this, namespace);

  late final StreamController<SettingsSnapshot> _snapshots;
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _disposed = false;

  Map<String, SettingsMutateValue> _namespaces = <String, SettingsMutateValue>{};
  Map<String, CredentialView> _credentials = <String, CredentialView>{};
  List<ConfigurableProviderView> _providerViews = <ConfigurableProviderView>[];
  bool _writable = false;
  bool _hasDocument = false;

  /// 测试观察点:三类 RPC 的调用次数(失效重拉断言用)。
  int describeCalls = 0;
  int providersCalls = 0;
  int credentialsCalls = 0;

  @override
  Stream<SettingsSnapshot> get snapshots => _snapshots.stream;

  @override
  SettingsSnapshot get current => _buildSnapshot();

  @override
  SettingsMutateValue? namespace(String ns) => _namespaces[ns];

  /// 全量重拉:settings.describe → llm.providers → credentials.describe。
  /// 顺序依赖:凭据引用(apiKeyEnv)要从 describe 的配置值里推导。
  @override
  Future<void> refresh() async {
    if (_disposed) return;
    final desc = await api.call(
      RpcMethods.settingsDescribe,
      <String, dynamic>{},
      parse: SettingsDescribeValue.fromJson,
    );
    describeCalls += 1;
    final namespaces = <String, SettingsMutateValue>{};
    for (final n in desc.namespaces) {
      namespaces[n.ns] = n;
    }
    final provs = await api.call(
      RpcMethods.llmProviders,
      <String, dynamic>{},
      parse: LlmProvidersValue.fromJson,
    );
    providersCalls += 1;
    final refs = <String>{};
    for (final p in provs.providers) {
      final ref = _credentialRefOf(p, namespaces);
      if (ref != null) refs.add(ref);
    }
    final creds = await api.call(
      RpcMethods.credentialsDescribe,
      <String, dynamic>{'refs': refs.toList()},
      parse: CredentialsDescribeValue.fromJson,
    );
    credentialsCalls += 1;
    final credMap = <String, CredentialView>{};
    creds.credentials.forEach((k, v) {
      credMap[k] = CredentialView.fromJson(v as Map<String, dynamic>);
    });
    _namespaces = namespaces;
    _providerViews = provs.providers;
    _credentials = credMap;
    _writable = desc.writable;
    _hasDocument = desc.hasDocument;
    _emit();
  }

  /// settings.mutate:成功 → 本地快照用响应覆盖(新 revision 供下次 CAS),
  /// 并写后重读(最新写入优先);settings-conflict → 自动重读再抛 typed 异常。
  @override
  Future<SettingsMutateValue> mutate(
    String namespace,
    List<SettingsPathOp> ops, {
    double? expectedRevision,
  }) async {
    if (_disposed) throw StateError('SettingsStore disposed');
    try {
      final value = await api.call(
        RpcMethods.settingsMutate,
        <String, dynamic>{
          'ns': namespace,
          'ops': [for (final op in ops) op.toJson()],
          if (expectedRevision != null) 'expectedRevision': expectedRevision,
        },
        parse: SettingsMutateValue.fromJson,
      );
      // 用响应覆盖本地快照(权威 revision 落地,下一次 CAS 用它)。
      _namespaces = Map<String, SettingsMutateValue>.of(_namespaces)..[namespace] = value;
      _emit();
      unawaited(refresh().catchError((Object _) {}));
      return value;
    } on RpcBusinessError catch (e) {
      if (e.error is RpcErrorSettingsConflict) {
        // 冲突恢复语义:自动重读(权威 revision 落地),再抛给 UI 提示重试。
        await refresh().catchError((Object _) {});
        throw SettingsConflictError(
          namespace,
          expectedRevision: expectedRevision,
          latestRevision: _namespaces[namespace]?.revision,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> setCredential(String ref, String value) async {
    await api.call(
      RpcMethods.credentialsSet,
      <String, dynamic>{'ref': ref, 'value': value},
      parse: CredentialsSetValue.fromJson,
    );
    // 徽标对齐交给 credentials/updated 事件(host 会推);这里再保险重拉一次。
    unawaited(refresh().catchError((Object _) {}));
  }

  @override
  Future<void> unsetCredential(String ref) async {
    await api.call(
      RpcMethods.credentialsUnset,
      <String, dynamic>{'ref': ref},
      parse: CredentialsUnsetValue.fromJson,
    );
    unawaited(refresh().catchError((Object _) {}));
  }

  @override
  Future<LlmDiscoverModelsValue> discoverModels({
    required String settingsNs,
    String? provider,
    String? baseURL,
    String? api,
    String? apiKey,
  }) {
    // 注意:命名参数 api 会遮蔽字段,必须显式 this.api。
    return this.api.call(
      RpcMethods.llmDiscoverModels,
      <String, dynamic>{
        'settingsNs': settingsNs,
        if (provider != null) 'provider': provider,
        if (baseURL != null) 'baseURL': baseURL,
        if (api != null) 'api': api,
        if (apiKey != null) 'apiKey': apiKey,
      },
      parse: LlmDiscoverModelsValue.fromJson,
    );
  }

  @override
  Future<SettingsOpenDocumentValue> openDocument() => api.call(
        RpcMethods.settingsOpenDocument,
        <String, dynamic>{},
        parse: SettingsOpenDocumentValue.fromJson,
      );

  /// 失效事件三件套:settings/document-updated、credentials/updated、
  /// llm/adapters-updated → 收到即重拉对应目录(describe 是全局读,一次全拉)。
  void _onHostFrame(HostFrame frame) {
    if (frame is! HostFrameHostRemoteEvent) return;
    final event = frame.event;
    if (event == 'settings/document-updated' ||
        event == 'credentials/updated' ||
        event == 'llm/adapters-updated') {
      unawaited(refresh().catchError((Object _) {}));
    }
  }

  void _onSnapshot(ConnectionSnapshot snap) {
    if (_disposed) return;
    if (snap.phase == ConnectionPhase.ready && snap.generation > _lastReadyGeneration) {
      _lastReadyGeneration = snap.generation;
      // 重连=全量重取(无 since 续传,与 SessionStore 同语义)。
      unawaited(refresh().catchError((Object _) {}));
    }
  }

  SettingsSnapshot _buildSnapshot() {
    return SettingsSnapshot(
      providers: List<ProviderEntry>.unmodifiable([
        for (final p in _providerViews) _buildProviderEntry(p),
      ]),
      namespaces: Map<String, SettingsMutateValue>.unmodifiable(_namespaces),
      credentials: Map<String, CredentialView>.unmodifiable(_credentials),
      writable: _writable,
      hasDocument: _hasDocument,
    );
  }

  ProviderEntry _buildProviderEntry(ConfigurableProviderView p) {
    final ns = _namespaces[p.settingsNs];
    final config = ns == null ? null : _configAt(ns.value, p.settingsPath);
    final ref = _credentialRefOf(p, _namespaces);
    final status = ref == null
        ? CredentialStatus.none
        : (_credentials[ref]?.configured == true
            ? CredentialStatus.configured
            : CredentialStatus.missing);
    return ProviderEntry(
      view: p,
      config: config is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(config)
          : const <String, dynamic>{},
      credentialRef: ref,
      credentialStatus: status,
      namespace: p.settingsNs,
      settingsPath: List<String>.unmodifiable(p.settingsPath),
      revision: ns?.revision ?? 0,
    );
  }

  /// 凭据引用 = 配置值的 apiKeyEnv;值里没有则回退 schema 的
  /// credential-ref 默认(如 llm-deepseek 默认 DEEPSEEK_API_KEY)。
  String? _credentialRefOf(ConfigurableProviderView p, Map<String, SettingsMutateValue> namespaces) {
    final ns = namespaces[p.settingsNs];
    if (ns == null) return null;
    final config = _configAt(ns.value, p.settingsPath);
    if (config is Map<String, dynamic>) {
      final v = config['apiKeyEnv'];
      if (v is String && v.isNotEmpty) return v;
    }
    final refId = _schemaFieldRef(ns.schema, [...p.settingsPath, 'apiKeyEnv']);
    if (refId != null) {
      final node = _schemaRef(ns.schema, refId);
      final meta = node?['meta'];
      if (meta is Map<String, dynamic> && meta['role'] == 'credential-ref') {
        final d = meta['default'];
        if (d is String && d.isNotEmpty) return d;
      }
    }
    return null;
  }

  // ---- schema 走查(设置面板的动态读:枚举选项/默认值) ----

  /// 沿 path 下钻 schema 的 object dict,返回末端字段的 ref id。
  Object? _schemaFieldRef(dynamic schema, List<String> path) {
    if (schema is! Map<String, dynamic>) return null;
    final refs = schema['refs'];
    if (refs is! Map<String, dynamic>) return null;
    Object? current = schema['uid'];
    for (final seg in path) {
      final node = current == null ? null : refs[current];
      if (node is! Map<String, dynamic>) return null;
      if (node['type'] != 'object') return null;
      final dict = node['dict'];
      if (dict is! Map<String, dynamic>) return null;
      final next = dict[seg];
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  Map<String, dynamic>? _schemaRef(dynamic schema, Object? refId) {
    if (schema is! Map<String, dynamic>) return null;
    final refs = schema['refs'];
    if (refs is! Map<String, dynamic>) return null;
    final node = refs[refId];
    return node is Map<String, dynamic> ? node : null;
  }

  /// 读某字段路径的 const 枚举选项(union → const 值);读不到返回 null。
  List<String>? _schemaEnumOptions(dynamic schema, List<String> path) {
    final refId = _schemaFieldRef(schema, path);
    final node = _schemaRef(schema, refId);
    if (node == null || node['type'] != 'union') return null;
    final list = node['list'];
    if (list is! List) return null;
    final out = <String>[];
    for (final id in list) {
      final n = _schemaRef(schema, id);
      if (n != null && n['type'] == 'const') {
        final v = n['value'];
        if (v is String) out.add(v);
      }
    }
    return out.isEmpty ? null : out;
  }

  /// 找根 schema 里含 defaultPreset 字段的 namespace(schema 动态读)。
  SettingsMutateValue? _permissionNamespaceView() {
    for (final ns in _namespaces.values) {
      final schema = ns.schema;
      if (schema is! Map<String, dynamic>) continue;
      final root = _schemaRef(schema, schema['uid']);
      final dict = root?['dict'];
      if (dict is Map<String, dynamic> && dict.containsKey('defaultPreset')) return ns;
    }
    return null;
  }

  @override
  List<String>? get permissionPresetOptions {
    final ns = _permissionNamespaceView();
    if (ns == null) return null;
    return _schemaEnumOptions(ns.schema, ['defaultPreset']);
  }

  @override
  String? get permissionNamespace => _permissionNamespaceView()?.ns;

  @override
  String? get currentPermissionPreset {
    final ns = _permissionNamespaceView();
    if (ns == null) return null;
    final v = ns.value;
    if (v is Map<String, dynamic>) {
      final cur = v['defaultPreset'];
      return cur is String ? cur : null;
    }
    return null;
  }

  /// 沿 path 下钻 value(中间必须是 map;缺失返回 null)。
  Object? _configAt(dynamic value, List<String> path) {
    Object? current = value;
    for (final seg in path) {
      if (current is! Map<String, dynamic>) return null;
      current = current[seg];
    }
    return current;
  }

  void _emit() {
    if (!_snapshots.isClosed) _snapshots.add(current);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _hostSub?.cancel();
    await _snapshots.close();
  }
}
