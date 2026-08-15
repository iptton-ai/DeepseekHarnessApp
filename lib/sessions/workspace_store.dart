// WorkspaceStore — W1-A workspace 分组域状态。
//
// 契约(DSH-PROTOCOL §3/§4 + workspace.schema.js,同 SessionStore 模式):
// - 代际 ready → 全量重取 workspace.list(无 since 续传,重连=重开流+重取)
// - host/workspace-changed、workspace-removed、workspace-order-changed、
//   archived-sessions-changed → 全量重取(简单收敛,不等帧内数据)
// - 变更方法(create/rename/delete/insertBefore/insertSessionBefore/
//   archiveSession)成功后以响应回带的数据落地并广播,不等重取
// - archivedSessionIds 集合暴露,归档会话从分组视图消失由 UI 过滤
//
// 不变式:列表顺序即 wire 顺序;本地落地只发生在 RPC 成功之后。
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// UI 依赖的窄视图(便于 widget 测试用假实现注入,不碰 socket)。
/// 广播流 + 当前快照 + workspace 域全部变更方法。
abstract class WorkspaceStoreView {
  /// 工作区分组快照流(顺序即 wire 顺序)。
  Stream<List<WorkspaceView>> get workspaces;
  List<WorkspaceView> get currentWorkspaces;

  /// 归档会话 id 流 + 当前集合。
  Stream<List<String>> get archivedSessionIds;
  List<String> get currentArchivedSessionIds;

  /// 归档判定(UI 过滤用)。
  bool isArchived(String sessionId);

  Future<WorkspaceCreateValue> create(String path);
  Future<WorkspaceRenameValue> rename(String workspaceId, String title);
  Future<WorkspaceDeleteValue> delete(String workspaceId);
  Future<WorkspaceInsertBeforeValue> insertBefore(String workspaceId,
      {String? beforeWorkspaceId});
  Future<WorkspaceInsertSessionBeforeValue> insertSessionBefore(
      String workspaceId, String sessionId,
      {String? beforeSessionId});
  Future<WorkspaceArchiveSessionValue> archiveSession(String sessionId);
}

class WorkspaceStore implements WorkspaceStoreView {
  WorkspaceStore({required this.api, required this.connection}) {
    _workspacesController = StreamController<List<WorkspaceView>>.broadcast();
    _archivedController = StreamController<List<String>>.broadcast();
  }

  final ApiClient api;
  final ConnectionController connection;

  late final StreamController<List<WorkspaceView>> _workspacesController;
  late final StreamController<List<String>> _archivedController;
  List<WorkspaceView> _workspaces = <WorkspaceView>[];
  List<String> _archivedIds = <String>[];
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _started = false;
  bool _disposed = false;

  /// 测试钩子:workspace.list 调用次数(验证"落地不重取 / 帧触发重取")。
  int listCalls = 0;

  @override
  Stream<List<WorkspaceView>> get workspaces => _workspacesController.stream;

  @override
  List<WorkspaceView> get currentWorkspaces =>
      List<WorkspaceView>.unmodifiable(_workspaces);

  @override
  Stream<List<String>> get archivedSessionIds => _archivedController.stream;

  @override
  List<String> get currentArchivedSessionIds =>
      List<String>.unmodifiable(_archivedIds);

  @override
  bool isArchived(String sessionId) => _archivedIds.contains(sessionId);

  void start() {
    if (_started) return;
    _started = true;
    _snapshotsSub = connection.snapshots.listen((snap) {
      if (!_disposed &&
          snap.phase == ConnectionPhase.ready &&
          snap.generation > _lastReadyGeneration) {
        _lastReadyGeneration = snap.generation;
        // 重连=全量重取(无 since);失败由下一次代际重试。
        unawaited(refresh().catchError((Object _) {}));
      }
    });
    _hostSub = connection.hostFrames.listen(_onHostFrame);
    final current = connection.current;
    if (current != null &&
        current.phase == ConnectionPhase.ready &&
        current.generation > _lastReadyGeneration) {
      _lastReadyGeneration = current.generation;
      unawaited(refresh());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _hostSub?.cancel();
    await _workspacesController.close();
    await _archivedController.close();
  }

  /// 全量重取 workspace.list(items + archivedSessionIds)。
  Future<void> refresh() async {
    if (_disposed) return;
    final value = await api.call(
      RpcMethods.workspaceList,
      <String, dynamic>{},
      parse: WorkspaceListValue.fromJson,
    );
    _workspaces = value.items;
    _archivedIds = value.archivedSessionIds;
    listCalls += 1;
    if (!_workspacesController.isClosed) {
      _workspacesController.add(List<WorkspaceView>.unmodifiable(_workspaces));
    }
    if (!_archivedController.isClosed) {
      _archivedController.add(List<String>.unmodifiable(_archivedIds));
    }
  }

  @override
  Future<WorkspaceCreateValue> create(String path) async {
    final value = await api.call(
      RpcMethods.workspaceCreate,
      <String, dynamic>{'path': path},
      parse: WorkspaceCreateValue.fromJson,
    );
    // 响应回带 WorkspaceView 落地并广播(不等重取);created=false 同样 upsert。
    _upsert(value.workspace);
    return value;
  }

  @override
  Future<WorkspaceRenameValue> rename(String workspaceId, String title) async {
    final value = await api.call(
      RpcMethods.workspaceRename,
      <String, dynamic>{'workspaceId': workspaceId, 'title': title},
      parse: WorkspaceRenameValue.fromJson,
    );
    _upsert(value.workspace);
    return value;
  }

  @override
  Future<WorkspaceDeleteValue> delete(String workspaceId) async {
    final value = await api.call(
      RpcMethods.workspaceDelete,
      <String, dynamic>{'workspaceId': workspaceId},
      parse: WorkspaceDeleteValue.fromJson,
    );
    _workspaces =
        _workspaces.where((w) => w.workspaceId != workspaceId).toList();
    _emitWorkspaces();
    return value;
  }

  @override
  Future<WorkspaceInsertBeforeValue> insertBefore(String workspaceId,
      {String? beforeWorkspaceId}) async {
    final value = await api.call(
      RpcMethods.workspaceInsertBefore,
      <String, dynamic>{
        'workspaceId': workspaceId,
        if (beforeWorkspaceId != null) 'beforeWorkspaceId': beforeWorkspaceId,
      },
      parse: WorkspaceInsertBeforeValue.fromJson,
    );
    // 响应回带完整排序;按序重排本地列表(未知 id 保持原位兜底)。
    final byId = <String, WorkspaceView>{
      for (final w in _workspaces) w.workspaceId: w,
    };
    final next = <WorkspaceView>[];
    for (final id in value.workspaceIds) {
      final w = byId.remove(id);
      if (w != null) next.add(w);
    }
    next.addAll(byId.values);
    _workspaces = next;
    _emitWorkspaces();
    return value;
  }

  @override
  Future<WorkspaceInsertSessionBeforeValue> insertSessionBefore(
      String workspaceId, String sessionId,
      {String? beforeSessionId}) async {
    final value = await api.call(
      RpcMethods.workspaceInsertSessionBefore,
      <String, dynamic>{
        'workspaceId': workspaceId,
        'sessionId': sessionId,
        if (beforeSessionId != null) 'beforeSessionId': beforeSessionId,
      },
      parse: WorkspaceInsertSessionBeforeValue.fromJson,
    );
    _upsert(value.workspace);
    return value;
  }

  @override
  Future<WorkspaceArchiveSessionValue> archiveSession(String sessionId) async {
    final value = await api.call(
      RpcMethods.workspaceArchiveSession,
      <String, dynamic>{'sessionId': sessionId},
      parse: WorkspaceArchiveSessionValue.fromJson,
    );
    // 响应回带完整归档集合(收敛语义),直接替换。
    _archivedIds = value.archivedSessionIds;
    if (!_archivedController.isClosed) {
      _archivedController.add(List<String>.unmodifiable(_archivedIds));
    }
    return value;
  }

  void _upsert(WorkspaceView w) {
    final idx = _workspaces.indexWhere((x) => x.workspaceId == w.workspaceId);
    if (idx >= 0) {
      final next = List<WorkspaceView>.of(_workspaces);
      next[idx] = w;
      _workspaces = next;
    } else {
      _workspaces = List<WorkspaceView>.of(_workspaces)..add(w);
    }
    _emitWorkspaces();
  }

  void _emitWorkspaces() {
    if (!_workspacesController.isClosed) {
      _workspacesController.add(List<WorkspaceView>.unmodifiable(_workspaces));
    }
  }

  void _onHostFrame(HostFrame frame) {
    if (frame is HostFrameHostWorkspaceChanged ||
        frame is HostFrameHostWorkspaceRemoved ||
        frame is HostFrameHostWorkspaceOrderChanged ||
        frame is HostFrameHostArchivedSessionsChanged) {
      // 简单收敛:任意 workspace 域变更整表重取(无 since 续传)。
      unawaited(refresh().catchError((Object _) {}));
    }
  }
}
