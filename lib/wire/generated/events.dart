part of 'wire_generated.dart';

// events domain models.

/// Wire model AskUserQuestionItem.
final class AskUserQuestionItem {
  const AskUserQuestionItem({required this.id, required this.question, this.header, this.detail, this.options, this.multiSelect, this.intent});
  final RpcId id;
  final RpcId question;
  final RpcId? header;
  final RpcId? detail;
  final List<Map<String, dynamic>>? options;
  final bool? multiSelect;
  final Object? intent;
  factory AskUserQuestionItem.fromJson(Map<String, dynamic> json) {
    return AskUserQuestionItem(
      id: (json['id'] as String),
      question: (json['question'] as String),
      header: json.containsKey('header') ? (json['header'] as String) : null,
      detail: json.containsKey('detail') ? (json['detail'] as String) : null,
      options: json.containsKey('options') ? [for (final e in (json['options'] as List)) (e as Map<String, dynamic>)] : null,
      multiSelect: json.containsKey('multiSelect') ? (json['multiSelect'] as bool) : null,
      intent: json.containsKey('intent') ? json['intent'] : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'question': question,
      if (header != null) 'header': header!,
      if (detail != null) 'detail': detail!,
      if (options != null) 'options': [for (final e in options!) e],
      if (multiSelect != null) 'multiSelect': multiSelect!,
      if (intent != null) 'intent': intent!,
  };
}

/// Sealed union HostFrame, discriminated by "type".
sealed class HostFrame {
  const HostFrame();
  Map<String, dynamic> toJson();
  factory HostFrame.fromJson(Map<String, dynamic> json) {
    final tag = json['type'] as String;
    switch (tag) {
      case 'host/session-added':
        return HostFrameHostSessionAdded.fromJson(json);
      case 'host/session-removed':
        return HostFrameHostSessionRemoved.fromJson(json);
      case 'host/session-status':
        return HostFrameHostSessionStatus.fromJson(json);
      case 'host/agent-error':
        return HostFrameHostAgentError.fromJson(json);
      case 'host/workspace-changed':
        return HostFrameHostWorkspaceChanged.fromJson(json);
      case 'host/workspace-removed':
        return HostFrameHostWorkspaceRemoved.fromJson(json);
      case 'host/workspace-order-changed':
        return HostFrameHostWorkspaceOrderChanged.fromJson(json);
      case 'host/archived-sessions-changed':
        return HostFrameHostArchivedSessionsChanged.fromJson(json);
      case 'host/remote-event':
        return HostFrameHostRemoteEvent.fromJson(json);
      case 'stream/error':
        return HostFrameStreamError.fromJson(json);
      default:
        throw FormatException('HostFrame: unknown type ' + tag);
    }
  }
}

/// "host/session-added" variant of HostFrame.
final class HostFrameHostSessionAdded extends HostFrame {
  const HostFrameHostSessionAdded({required this.sessionId, required this.blank, this.parentSessionId, this.origin, this.cwd, this.agentPreset});
  final ApprovalRequestId sessionId;
  final bool blank;
  final ApprovalRequestId? parentSessionId;
  final String? origin;
  final RpcId? cwd;
  final RpcId? agentPreset;
  factory HostFrameHostSessionAdded.fromJson(Map<String, dynamic> json) {
    return HostFrameHostSessionAdded(
      sessionId: (json['sessionId'] as String),
      blank: (json['blank'] as bool),
      parentSessionId: json.containsKey('parentSessionId') ? (json['parentSessionId'] as String) : null,
      origin: json.containsKey('origin') ? (json['origin'] as String) : null,
      cwd: json.containsKey('cwd') ? (json['cwd'] as String) : null,
      agentPreset: json.containsKey('agentPreset') ? (json['agentPreset'] as String) : null,
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/session-added',
      'sessionId': sessionId,
      'blank': blank,
      if (parentSessionId != null) 'parentSessionId': parentSessionId!,
      if (origin != null) 'origin': origin!,
      if (cwd != null) 'cwd': cwd!,
      if (agentPreset != null) 'agentPreset': agentPreset!,
  };
}

/// "host/session-removed" variant of HostFrame.
final class HostFrameHostSessionRemoved extends HostFrame {
  const HostFrameHostSessionRemoved({required this.sessionId});
  final ApprovalRequestId sessionId;
  factory HostFrameHostSessionRemoved.fromJson(Map<String, dynamic> json) {
    return HostFrameHostSessionRemoved(
      sessionId: (json['sessionId'] as String),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/session-removed',
      'sessionId': sessionId,
  };
}

/// "host/session-status" variant of HostFrame.
final class HostFrameHostSessionStatus extends HostFrame {
  const HostFrameHostSessionStatus({required this.sessionId, required this.running});
  final ApprovalRequestId sessionId;
  final bool running;
  factory HostFrameHostSessionStatus.fromJson(Map<String, dynamic> json) {
    return HostFrameHostSessionStatus(
      sessionId: (json['sessionId'] as String),
      running: (json['running'] as bool),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/session-status',
      'sessionId': sessionId,
      'running': running,
  };
}

/// "host/agent-error" variant of HostFrame.
final class HostFrameHostAgentError extends HostFrame {
  const HostFrameHostAgentError({required this.sessionId, required this.message});
  final ApprovalRequestId sessionId;
  final RpcId message;
  factory HostFrameHostAgentError.fromJson(Map<String, dynamic> json) {
    return HostFrameHostAgentError(
      sessionId: (json['sessionId'] as String),
      message: (json['message'] as String),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/agent-error',
      'sessionId': sessionId,
      'message': message,
  };
}

/// "host/workspace-changed" variant of HostFrame.
final class HostFrameHostWorkspaceChanged extends HostFrame {
  const HostFrameHostWorkspaceChanged({required this.workspace});
  final WorkspaceView workspace;
  factory HostFrameHostWorkspaceChanged.fromJson(Map<String, dynamic> json) {
    return HostFrameHostWorkspaceChanged(
      workspace: WorkspaceView.fromJson(json['workspace'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/workspace-changed',
      'workspace': workspace.toJson(),
  };
}

/// "host/workspace-removed" variant of HostFrame.
final class HostFrameHostWorkspaceRemoved extends HostFrame {
  const HostFrameHostWorkspaceRemoved({required this.workspaceId});
  final ApprovalRequestId workspaceId;
  factory HostFrameHostWorkspaceRemoved.fromJson(Map<String, dynamic> json) {
    return HostFrameHostWorkspaceRemoved(
      workspaceId: (json['workspaceId'] as String),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/workspace-removed',
      'workspaceId': workspaceId,
  };
}

/// "host/workspace-order-changed" variant of HostFrame.
final class HostFrameHostWorkspaceOrderChanged extends HostFrame {
  const HostFrameHostWorkspaceOrderChanged({required this.workspaceIds});
  final List<ApprovalRequestId> workspaceIds;
  factory HostFrameHostWorkspaceOrderChanged.fromJson(Map<String, dynamic> json) {
    return HostFrameHostWorkspaceOrderChanged(
      workspaceIds: [for (final e in (json['workspaceIds'] as List)) (e as String)],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/workspace-order-changed',
      'workspaceIds': [for (final e in workspaceIds) e],
  };
}

/// "host/archived-sessions-changed" variant of HostFrame.
final class HostFrameHostArchivedSessionsChanged extends HostFrame {
  const HostFrameHostArchivedSessionsChanged({required this.archivedSessionIds});
  final List<ApprovalRequestId> archivedSessionIds;
  factory HostFrameHostArchivedSessionsChanged.fromJson(Map<String, dynamic> json) {
    return HostFrameHostArchivedSessionsChanged(
      archivedSessionIds: [for (final e in (json['archivedSessionIds'] as List)) (e as String)],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/archived-sessions-changed',
      'archivedSessionIds': [for (final e in archivedSessionIds) e],
  };
}

/// "host/remote-event" variant of HostFrame.
final class HostFrameHostRemoteEvent extends HostFrame {
  const HostFrameHostRemoteEvent({required this.event, required this.args});
  final ApprovalRequestId event;
  final List<dynamic> args;
  factory HostFrameHostRemoteEvent.fromJson(Map<String, dynamic> json) {
    return HostFrameHostRemoteEvent(
      event: (json['event'] as String),
      args: (json['args'] as List).toList(),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'host/remote-event',
      'event': event,
      'args': args,
  };
}

/// "stream/error" variant of HostFrame.
final class HostFrameStreamError extends HostFrame {
  const HostFrameStreamError({required this.error});
  final RpcError error;
  factory HostFrameStreamError.fromJson(Map<String, dynamic> json) {
    return HostFrameStreamError(
      error: RpcError.fromJson(json['error'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'stream/error',
      'error': error.toJson(),
  };
}

/// Sealed union MuxFrame, discriminated by "type".
sealed class MuxFrame {
  const MuxFrame();
  Map<String, dynamic> toJson();
  factory MuxFrame.fromJson(Map<String, dynamic> json) {
    final tag = json['type'] as String;
    switch (tag) {
      case 'session/event':
        return MuxFrameSessionEvent.fromJson(json);
      case 'session/subscribed':
        return MuxFrameSessionSubscribed.fromJson(json);
      case 'approval/requested':
        return MuxFrameApprovalRequested.fromJson(json);
      case 'approval/resolved':
        return MuxFrameApprovalResolved.fromJson(json);
      case 'question/requested':
        return MuxFrameQuestionRequested.fromJson(json);
      case 'question/resolved':
        return MuxFrameQuestionResolved.fromJson(json);
      case 'session/queue':
        return MuxFrameSessionQueue.fromJson(json);
      case 'session/jobs':
        return MuxFrameSessionJobs.fromJson(json);
      case 'session/projection':
        return MuxFrameSessionProjection.fromJson(json);
      case 'stream/error':
        return MuxFrameStreamError.fromJson(json);
      default:
        throw FormatException('MuxFrame: unknown type ' + tag);
    }
  }
}

/// "session/event" variant of MuxFrame.
final class MuxFrameSessionEvent extends MuxFrame {
  const MuxFrameSessionEvent({required this.sessionId, required this.event, this.view});
  final ApprovalRequestId sessionId;
  final SessionEvent event;
  final ToolEventView? view;
  factory MuxFrameSessionEvent.fromJson(Map<String, dynamic> json) {
    return MuxFrameSessionEvent(
      sessionId: (json['sessionId'] as String),
      event: SessionEvent.fromJson(json['event'] as Map<String, dynamic>),
      view: json.containsKey('view') ? ToolEventView.fromJson(json['view'] as Map<String, dynamic>) : null,
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'session/event',
      'sessionId': sessionId,
      'event': event.toJson(),
      if (view != null) 'view': view!.toJson(),
  };
}

/// "session/subscribed" variant of MuxFrame.
final class MuxFrameSessionSubscribed extends MuxFrame {
  const MuxFrameSessionSubscribed({required this.sessionId, required this.lastSeq});
  final ApprovalRequestId sessionId;
  final int lastSeq;
  factory MuxFrameSessionSubscribed.fromJson(Map<String, dynamic> json) {
    return MuxFrameSessionSubscribed(
      sessionId: (json['sessionId'] as String),
      lastSeq: (json['lastSeq'] as num).toInt(),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'session/subscribed',
      'sessionId': sessionId,
      'lastSeq': lastSeq,
  };
}

/// "approval/requested" variant of MuxFrame.
final class MuxFrameApprovalRequested extends MuxFrame {
  const MuxFrameApprovalRequested({required this.sessionId, required this.approvalId, required this.toolName, this.callId, this.reason});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId approvalId;
  final RpcId toolName;
  final RpcId? callId;
  final RpcId? reason;
  factory MuxFrameApprovalRequested.fromJson(Map<String, dynamic> json) {
    return MuxFrameApprovalRequested(
      sessionId: (json['sessionId'] as String),
      approvalId: (json['approvalId'] as String),
      toolName: (json['toolName'] as String),
      callId: json.containsKey('callId') ? (json['callId'] as String) : null,
      reason: json.containsKey('reason') ? (json['reason'] as String) : null,
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'approval/requested',
      'sessionId': sessionId,
      'approvalId': approvalId,
      'toolName': toolName,
      if (callId != null) 'callId': callId!,
      if (reason != null) 'reason': reason!,
  };
}

/// "approval/resolved" variant of MuxFrame.
final class MuxFrameApprovalResolved extends MuxFrame {
  const MuxFrameApprovalResolved({required this.sessionId, required this.approvalId, required this.outcome});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId approvalId;
  final Object outcome;
  factory MuxFrameApprovalResolved.fromJson(Map<String, dynamic> json) {
    return MuxFrameApprovalResolved(
      sessionId: (json['sessionId'] as String),
      approvalId: (json['approvalId'] as String),
      outcome: json['outcome'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'approval/resolved',
      'sessionId': sessionId,
      'approvalId': approvalId,
      'outcome': outcome,
  };
}

/// "question/requested" variant of MuxFrame.
final class MuxFrameQuestionRequested extends MuxFrame {
  const MuxFrameQuestionRequested({required this.sessionId, required this.questions});
  final ApprovalRequestId sessionId;
  final List<AskUserQuestionItem> questions;
  factory MuxFrameQuestionRequested.fromJson(Map<String, dynamic> json) {
    return MuxFrameQuestionRequested(
      sessionId: (json['sessionId'] as String),
      questions: [for (final e in (json['questions'] as List)) AskUserQuestionItem.fromJson(e as Map<String, dynamic>)],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'question/requested',
      'sessionId': sessionId,
      'questions': [for (final e in questions) e.toJson()],
  };
}

/// "question/resolved" variant of MuxFrame.
final class MuxFrameQuestionResolved extends MuxFrame {
  const MuxFrameQuestionResolved({required this.sessionId, required this.questionRpcId, required this.outcome});
  final ApprovalRequestId sessionId;
  final RpcId questionRpcId;
  final Object outcome;
  factory MuxFrameQuestionResolved.fromJson(Map<String, dynamic> json) {
    return MuxFrameQuestionResolved(
      sessionId: (json['sessionId'] as String),
      questionRpcId: (json['questionRpcId'] as String),
      outcome: json['outcome'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'question/resolved',
      'sessionId': sessionId,
      'questionRpcId': questionRpcId,
      'outcome': outcome,
  };
}

/// "session/queue" variant of MuxFrame.
final class MuxFrameSessionQueue extends MuxFrame {
  const MuxFrameSessionQueue({required this.sessionId, required this.items});
  final ApprovalRequestId sessionId;
  final List<Map<String, dynamic>> items;
  factory MuxFrameSessionQueue.fromJson(Map<String, dynamic> json) {
    return MuxFrameSessionQueue(
      sessionId: (json['sessionId'] as String),
      items: [for (final e in (json['items'] as List)) (e as Map<String, dynamic>)],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'session/queue',
      'sessionId': sessionId,
      'items': [for (final e in items) e],
  };
}

/// "session/jobs" variant of MuxFrame.
final class MuxFrameSessionJobs extends MuxFrame {
  const MuxFrameSessionJobs({required this.sessionId, required this.jobs});
  final ApprovalRequestId sessionId;
  final List<TaskView> jobs;
  factory MuxFrameSessionJobs.fromJson(Map<String, dynamic> json) {
    return MuxFrameSessionJobs(
      sessionId: (json['sessionId'] as String),
      jobs: [for (final e in (json['jobs'] as List)) TaskView.fromJson(e as Map<String, dynamic>)],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'session/jobs',
      'sessionId': sessionId,
      'jobs': [for (final e in jobs) e.toJson()],
  };
}

/// "session/projection" variant of MuxFrame.
final class MuxFrameSessionProjection extends MuxFrame {
  const MuxFrameSessionProjection({required this.sessionId, required this.key, required this.value, required this.seq});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId key;
  final SessionLogQuery value;
  final int seq;
  factory MuxFrameSessionProjection.fromJson(Map<String, dynamic> json) {
    return MuxFrameSessionProjection(
      sessionId: (json['sessionId'] as String),
      key: (json['key'] as String),
      value: json['value'],
      seq: (json['seq'] as num).toInt(),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'session/projection',
      'sessionId': sessionId,
      'key': key,
      'value': value,
      'seq': seq,
  };
}

/// "stream/error" variant of MuxFrame.
final class MuxFrameStreamError extends MuxFrame {
  const MuxFrameStreamError({required this.error});
  final RpcError error;
  factory MuxFrameStreamError.fromJson(Map<String, dynamic> json) {
    return MuxFrameStreamError(
      error: RpcError.fromJson(json['error'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'stream/error',
      'error': error.toJson(),
  };
}

