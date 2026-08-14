part of 'wire_generated.dart';

// workspace domain models.

/// Wire model WorkspaceArchiveSessionRequest.
final class WorkspaceArchiveSessionRequest {
  const WorkspaceArchiveSessionRequest({required this.sessionId});
  final ApprovalRequestId sessionId;
  factory WorkspaceArchiveSessionRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceArchiveSessionRequest(
      sessionId: (json['sessionId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
  };
}

/// Wire model WorkspaceArchiveSessionValue.
final class WorkspaceArchiveSessionValue {
  const WorkspaceArchiveSessionValue({required this.archivedSessionIds});
  final List<ApprovalRequestId> archivedSessionIds;
  factory WorkspaceArchiveSessionValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceArchiveSessionValue(
      archivedSessionIds: [for (final e in (json['archivedSessionIds'] as List)) (e as String)],
    );
  }
  Map<String, dynamic> toJson() => {
      'archivedSessionIds': [for (final e in archivedSessionIds) e],
  };
}

/// Wire model WorkspaceCreateRequest.
final class WorkspaceCreateRequest {
  const WorkspaceCreateRequest({required this.path});
  final RpcId path;
  factory WorkspaceCreateRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceCreateRequest(
      path: (json['path'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': path,
  };
}

/// Wire model WorkspaceCreateValue.
final class WorkspaceCreateValue {
  const WorkspaceCreateValue({required this.workspace, required this.created});
  final WorkspaceView workspace;
  final bool created;
  factory WorkspaceCreateValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceCreateValue(
      workspace: WorkspaceView.fromJson(json['workspace'] as Map<String, dynamic>),
      created: (json['created'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'workspace': workspace.toJson(),
      'created': created,
  };
}

/// Wire model WorkspaceDeleteRequest.
final class WorkspaceDeleteRequest {
  const WorkspaceDeleteRequest({required this.workspaceId});
  final ApprovalRequestId workspaceId;
  factory WorkspaceDeleteRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceDeleteRequest(
      workspaceId: (json['workspaceId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'workspaceId': workspaceId,
  };
}

/// Wire model WorkspaceDeleteValue.
final class WorkspaceDeleteValue {
  const WorkspaceDeleteValue({required this.deleted});
  final bool deleted;
  factory WorkspaceDeleteValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceDeleteValue(
      deleted: (json['deleted'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'deleted': deleted,
  };
}

/// Wire model WorkspaceInsertBeforeRequest.
final class WorkspaceInsertBeforeRequest {
  const WorkspaceInsertBeforeRequest({required this.workspaceId, this.beforeWorkspaceId});
  final ApprovalRequestId workspaceId;
  final ApprovalRequestId? beforeWorkspaceId;
  factory WorkspaceInsertBeforeRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceInsertBeforeRequest(
      workspaceId: (json['workspaceId'] as String),
      beforeWorkspaceId: json.containsKey('beforeWorkspaceId') ? (json['beforeWorkspaceId'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'workspaceId': workspaceId,
      if (beforeWorkspaceId != null) 'beforeWorkspaceId': beforeWorkspaceId!,
  };
}

/// Wire model WorkspaceInsertBeforeValue.
final class WorkspaceInsertBeforeValue {
  const WorkspaceInsertBeforeValue({required this.workspaceIds});
  final List<ApprovalRequestId> workspaceIds;
  factory WorkspaceInsertBeforeValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceInsertBeforeValue(
      workspaceIds: [for (final e in (json['workspaceIds'] as List)) (e as String)],
    );
  }
  Map<String, dynamic> toJson() => {
      'workspaceIds': [for (final e in workspaceIds) e],
  };
}

/// Wire model WorkspaceInsertSessionBeforeRequest.
final class WorkspaceInsertSessionBeforeRequest {
  const WorkspaceInsertSessionBeforeRequest({required this.workspaceId, required this.sessionId, this.beforeSessionId});
  final ApprovalRequestId workspaceId;
  final ApprovalRequestId sessionId;
  final ApprovalRequestId? beforeSessionId;
  factory WorkspaceInsertSessionBeforeRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceInsertSessionBeforeRequest(
      workspaceId: (json['workspaceId'] as String),
      sessionId: (json['sessionId'] as String),
      beforeSessionId: json.containsKey('beforeSessionId') ? (json['beforeSessionId'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'workspaceId': workspaceId,
      'sessionId': sessionId,
      if (beforeSessionId != null) 'beforeSessionId': beforeSessionId!,
  };
}

/// Wire model WorkspaceInsertSessionBeforeValue.
final class WorkspaceInsertSessionBeforeValue {
  const WorkspaceInsertSessionBeforeValue({required this.workspace});
  final WorkspaceView workspace;
  factory WorkspaceInsertSessionBeforeValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceInsertSessionBeforeValue(
      workspace: WorkspaceView.fromJson(json['workspace'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'workspace': workspace.toJson(),
  };
}

/// Wire model WorkspaceListRequest.
final class WorkspaceListRequest {
  const WorkspaceListRequest();
  factory WorkspaceListRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceListRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model WorkspaceListValue.
final class WorkspaceListValue {
  const WorkspaceListValue({required this.items, required this.archivedSessionIds});
  final List<WorkspaceView> items;
  final List<ApprovalRequestId> archivedSessionIds;
  factory WorkspaceListValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceListValue(
      items: [for (final e in (json['items'] as List)) WorkspaceView.fromJson(e as Map<String, dynamic>)],
      archivedSessionIds: [for (final e in (json['archivedSessionIds'] as List)) (e as String)],
    );
  }
  Map<String, dynamic> toJson() => {
      'items': [for (final e in items) e.toJson()],
      'archivedSessionIds': [for (final e in archivedSessionIds) e],
  };
}

/// Wire model WorkspaceRenameRequest.
final class WorkspaceRenameRequest {
  const WorkspaceRenameRequest({required this.workspaceId, required this.title});
  final ApprovalRequestId workspaceId;
  final RpcId title;
  factory WorkspaceRenameRequest.fromJson(Map<String, dynamic> json) {
    return WorkspaceRenameRequest(
      workspaceId: (json['workspaceId'] as String),
      title: (json['title'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'workspaceId': workspaceId,
      'title': title,
  };
}

/// Wire model WorkspaceRenameValue.
final class WorkspaceRenameValue {
  const WorkspaceRenameValue({required this.workspace});
  final WorkspaceView workspace;
  factory WorkspaceRenameValue.fromJson(Map<String, dynamic> json) {
    return WorkspaceRenameValue(
      workspace: WorkspaceView.fromJson(json['workspace'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'workspace': workspace.toJson(),
  };
}

/// Wire model WorkspaceView.
final class WorkspaceView {
  const WorkspaceView({required this.workspaceId, required this.path, required this.title, required this.sessionIds, required this.createdAt, required this.updatedAt});
  final ApprovalRequestId workspaceId;
  final RpcId path;
  final RpcId title;
  final List<ApprovalRequestId> sessionIds;
  final RpcId createdAt;
  final RpcId updatedAt;
  factory WorkspaceView.fromJson(Map<String, dynamic> json) {
    return WorkspaceView(
      workspaceId: (json['workspaceId'] as String),
      path: (json['path'] as String),
      title: (json['title'] as String),
      sessionIds: [for (final e in (json['sessionIds'] as List)) (e as String)],
      createdAt: (json['createdAt'] as String),
      updatedAt: (json['updatedAt'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'workspaceId': workspaceId,
      'path': path,
      'title': title,
      'sessionIds': [for (final e in sessionIds) e],
      'createdAt': createdAt,
      'updatedAt': updatedAt,
  };
}

