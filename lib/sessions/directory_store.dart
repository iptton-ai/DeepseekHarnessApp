// DirectoryBrowserStore — W2-B 应用内目录浏览(web directory-picker-browse 移动化复刻)。
//
// 契约(DSH-PROTOCOL §3/§5 + docs/audit/sidebar-layout.md §3 + 冻结 schema):
// - host.listDirectory(path?):path 缺省 = 主机家目录;响应回带
//   path/home/crumbs(面包屑祖先链)/entries/truncated
// - host.createDirectory(path, name) → {path}:在既有父目录下创建一个子目录
// - 目录域错误码封闭集:directory-unreadable(不可读)、directory-exists(创建冲突)、
//   directory-create-failed(创建失败)、bad-request(名称/路径非法)
// - DirectoryEntry 冻结形状 {name, path, hidden}(无 isHidden/isDirectory 字段):
//   隐藏过滤用 hidden;「目录在前」无法从单次 listing 判定 → 采用「下钻过即优先」
//   的渐进排序(首次装载 = 服务端顺序;host 侧若已按目录优先返回则天然满足)。
//
// 纪律:
// - 纯 Dart 域层,只依赖 ApiClient(两个 unary RPC,无 socket 订阅);UI 只消费
//   DirectoryBrowserView 窄接口(测试注入假实现)
// - 错误不清空当前层:list 失败只置 error + failedPath 并广播,entries/crumbs 保持;
//   重试目标 = failedPath
// - 每次状态变更广播不可变快照(broadcast,无重放)
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 一帧浏览状态(不可变;UI 与测试只消费它,不碰 wire)。
class DirectoryBrowserSnapshot {
  const DirectoryBrowserSnapshot({
    required this.currentPath,
    required this.home,
    required this.crumbs,
    required this.entries,
    required this.truncated,
    required this.loading,
    required this.error,
    required this.failedPath,
    required this.showHidden,
  });

  /// 当前层绝对路径;首次装载完成前为 null。
  final String? currentPath;

  /// 主机家目录(缺省装载的根)。
  final String home;

  /// 面包屑祖先链(自家目录到当前层,wire 原样)。
  final List<DirectoryEntry> crumbs;

  /// 当前层可见条目:默认过滤隐藏,已下钻过的目录优先(组内保持服务端顺序)。
  final List<DirectoryEntry> entries;

  /// 服务端截断标记(host 侧 limit 截断)。
  final bool truncated;

  /// 扫描中(旧视图保持渲染,列表顶部出进度条)。
  final bool loading;

  /// 当前层错误消息(null = 正常);错误不清空 entries。
  final String? error;

  /// 最近一次失败的装载目标路径(重试按钮的目标;首载失败 = null = 家目录)。
  final String? failedPath;

  /// 隐藏条目开关(默认 false = 过滤)。
  final bool showHidden;
}

/// UI 依赖的窄视图(便于 widget 测试注入假实现,不碰 socket)。
abstract class DirectoryBrowserView {
  /// 快照广播流。
  Stream<DirectoryBrowserSnapshot> get snapshots;

  /// 当前快照。
  DirectoryBrowserSnapshot get current;

  /// 隐藏条目开关当前值。
  bool get showHidden;

  /// 装载一层(path 缺省 = 主机家目录)。成功更新当前层并广播;
  /// 失败置 error(不清空当前层)并广播,随后 rethrow 原异常(调用方兜底吞掉)。
  Future<HostListDirectoryValue> listDirectory({String? path});

  /// 在 [path] 下创建名为 [name] 的子目录。冲突/失败 rethrow
  /// RpcBusinessError(UI 用 directoryCreateErrorMessage 展示,目录内提示)。
  Future<HostCreateDirectoryValue> createDirectory(String path, String name);

  /// 隐藏条目开关。
  void setShowHidden(bool value);
}

class DirectoryBrowserStore implements DirectoryBrowserView {
  DirectoryBrowserStore({required this.api});

  final ApiClient api;

  final StreamController<DirectoryBrowserSnapshot> _snapshots =
      StreamController<DirectoryBrowserSnapshot>.broadcast();
  String? _currentPath;
  String _home = '';
  List<DirectoryEntry> _crumbs = const <DirectoryEntry>[];
  List<DirectoryEntry> _rawEntries = const <DirectoryEntry>[];
  bool _truncated = false;
  bool _loading = false;
  String? _error;
  String? _failedPath;
  bool _showHidden = false;

  /// 已成功下钻过的目录路径(「目录在前」的渐进依据;crumbs 祖先一并记录)。
  final Set<String> _knownDirectories = <String>{};
  bool _disposed = false;

  /// 测试钩子:listDirectory / createDirectory 调用次数。
  int listCalls = 0;
  int createCalls = 0;

  @override
  Stream<DirectoryBrowserSnapshot> get snapshots => _snapshots.stream;

  @override
  DirectoryBrowserSnapshot get current => DirectoryBrowserSnapshot(
        currentPath: _currentPath,
        home: _home,
        crumbs: List<DirectoryEntry>.unmodifiable(_crumbs),
        entries: _visibleEntries(),
        truncated: _truncated,
        loading: _loading,
        error: _error,
        failedPath: _failedPath,
        showHidden: _showHidden,
      );

  @override
  bool get showHidden => _showHidden;

  Future<void> dispose() async {
    _disposed = true;
    await _snapshots.close();
  }

  @override
  Future<HostListDirectoryValue> listDirectory({String? path}) async {
    _loading = true;
    _error = null;
    _failedPath = null;
    _emit();
    listCalls += 1;
    try {
      final value = await api.call(
        RpcMethods.hostListDirectory,
        <String, dynamic>{if (path != null) 'path': path},
        parse: HostListDirectoryValue.fromJson,
      );
      _apply(value);
      _emit();
      return value;
    } on RpcBusinessError catch (e) {
      _fail(path, directoryListErrorMessage(e, path: path));
      rethrow;
    } on CarrierError catch (e) {
      _fail(path, directoryListErrorMessage(e, path: path));
      rethrow;
    } on ApiTimeout catch (e) {
      _fail(path, directoryListErrorMessage(e, path: path));
      rethrow;
    }
  }

  /// 装载成功落地:整层替换 + 清错误;下钻成功 → 记入已知目录。
  void _apply(HostListDirectoryValue value) {
    _currentPath = value.path;
    _home = value.home;
    _crumbs = value.crumbs;
    _rawEntries = value.entries;
    _truncated = value.truncated;
    _loading = false;
    _error = null;
    _failedPath = null;
    if (value.path.isNotEmpty) _knownDirectories.add(value.path);
    for (final c in value.crumbs) {
      if (c.path.isNotEmpty) _knownDirectories.add(c.path);
    }
  }

  /// 装载失败:不清空当前层,只置错误 + 失败路径并广播。
  void _fail(String? path, String message) {
    _loading = false;
    _failedPath = path;
    _error = message;
    _emit();
  }

  @override
  Future<HostCreateDirectoryValue> createDirectory(
      String path, String name) async {
    createCalls += 1;
    return api.call(
      RpcMethods.hostCreateDirectory,
      <String, dynamic>{'path': path, 'name': name},
      parse: HostCreateDirectoryValue.fromJson,
    );
  }

  @override
  void setShowHidden(bool value) {
    if (_showHidden == value) return;
    _showHidden = value;
    _emit();
  }

  /// 可见条目:默认过滤隐藏;已下钻过的目录(已知)排前,组内保持服务端顺序。
  List<DirectoryEntry> _visibleEntries() {
    final base = _showHidden
        ? _rawEntries
        : _rawEntries.where((e) => !e.hidden).toList();
    final known = <DirectoryEntry>[
      for (final e in base)
        if (_knownDirectories.contains(e.path)) e,
    ];
    final rest = <DirectoryEntry>[
      for (final e in base)
        if (!_knownDirectories.contains(e.path)) e,
    ];
    return List<DirectoryEntry>.unmodifiable(<DirectoryEntry>[...known, ...rest]);
  }

  void _emit() {
    if (_disposed || _snapshots.isClosed) return;
    _snapshots.add(current);
  }
}

/// RpcError 变体取 message(仅目录域 + bad-request 有可用语义;其余返回空)。
String _errorMessageOf(RpcError e) {
  return switch (e) {
    RpcErrorDirectoryUnreadable(:final message) => message,
    RpcErrorDirectoryExists(:final message) => message,
    RpcErrorDirectoryCreateFailed(:final message) => message,
    RpcErrorBadRequest(:final message) => message,
    _ => '',
  };
}

String _nonEmpty(String v, String fallback) =>
    v.trim().isEmpty ? fallback : v.trim();

String _carrierMessage(Object error) {
  if (error is CarrierError) return '无法连接主机: ${error.reason}';
  if (error is ApiTimeout) return '加载目录超时';
  return '加载目录失败';
}

/// 装载失败折叠成用户可读消息(目录域错误定位到具体路径;载波/超时是全局问题)。
String directoryListErrorMessage(Object error, {String? path}) {
  final code = error is RpcBusinessError ? error.error : null;
  final base = switch (code) {
    RpcErrorDirectoryUnreadable(:final message) =>
        _nonEmpty(message, '该目录不可读(无权限或不是文件夹)'),
    RpcErrorBadRequest(:final message) => _nonEmpty(message, '路径无效'),
    null => _carrierMessage(error),
    _ => _nonEmpty(_errorMessageOf(code), '加载目录失败'),
  };
  if (code == null || path == null) return base;
  return '无法读取「$path」: $base';
}

/// 创建失败折叠成用户可读消息(冲突/失败在同一目录内提示)。
String directoryCreateErrorMessage(Object error) {
  final code = error is RpcBusinessError ? error.error : null;
  return switch (code) {
    RpcErrorDirectoryExists(:final message) =>
        _nonEmpty(message, '已存在同名文件夹'),
    RpcErrorDirectoryCreateFailed(:final message) =>
        _nonEmpty(message, '创建文件夹失败'),
    RpcErrorBadRequest(:final message) => _nonEmpty(message, '文件夹名称无效'),
    null => _carrierMessage(error),
    _ => _nonEmpty(_errorMessageOf(code), '创建文件夹失败'),
  };
}
