part of 'wire_generated.dart';

// rpc domain models.

/// Wire model ClientRequest.
final class ClientRequest {
  const ClientRequest({required this.type, required this.rpcId, required this.method, required this.payload});
  final String type;
  final RpcId rpcId;
  final RpcId method;
  final SessionLogQuery payload;
  factory ClientRequest.fromJson(Map<String, dynamic> json) {
    return ClientRequest(
      type: (json['type'] as String),
      rpcId: (json['rpcId'] as String),
      method: (json['method'] as String),
      payload: json['payload'],
    );
  }
  Map<String, dynamic> toJson() => {
      'type': type,
      'rpcId': rpcId,
      'method': method,
      'payload': payload,
  };
}

/// Wire model ClientResponse.
final class ClientResponse {
  const ClientResponse({required this.type, required this.rpcId, required this.result});
  final String type;
  final RpcId rpcId;
  final Object result;
  factory ClientResponse.fromJson(Map<String, dynamic> json) {
    return ClientResponse(
      type: (json['type'] as String),
      rpcId: (json['rpcId'] as String),
      result: json['result'],
    );
  }
  Map<String, dynamic> toJson() => {
      'type': type,
      'rpcId': rpcId,
      'result': result,
  };
}

/// Sealed union RpcError, discriminated by "code".
sealed class RpcError {
  const RpcError();
  Map<String, dynamic> toJson();
  factory RpcError.fromJson(Map<String, dynamic> json) {
    final tag = json['code'] as String;
    switch (tag) {
      case 'bad-request':
        return RpcErrorBadRequest.fromJson(json);
      case 'cancelled':
        return RpcErrorCancelled.fromJson(json);
      case 'session-not-found':
        return RpcErrorSessionNotFound.fromJson(json);
      case 'model-unavailable':
        return RpcErrorModelUnavailable.fromJson(json);
      case 'session-conflict':
        return RpcErrorSessionConflict.fromJson(json);
      case 'invalid-time-zone':
        return RpcErrorInvalidTimeZone.fromJson(json);
      case 'workspace-attach-failed':
        return RpcErrorWorkspaceAttachFailed.fromJson(json);
      case 'workspace-not-found':
        return RpcErrorWorkspaceNotFound.fromJson(json);
      case 'workspace-invalid-path':
        return RpcErrorWorkspaceInvalidPath.fromJson(json);
      case 'workspace-name-conflict':
        return RpcErrorWorkspaceNameConflict.fromJson(json);
      case 'workspace-move-invalid':
        return RpcErrorWorkspaceMoveInvalid.fromJson(json);
      case 'directory-unreadable':
        return RpcErrorDirectoryUnreadable.fromJson(json);
      case 'directory-exists':
        return RpcErrorDirectoryExists.fromJson(json);
      case 'directory-create-failed':
        return RpcErrorDirectoryCreateFailed.fromJson(json);
      case 'directory-picker-unavailable':
        return RpcErrorDirectoryPickerUnavailable.fromJson(json);
      case 'agent-preset-read-only':
        return RpcErrorAgentPresetReadOnly.fromJson(json);
      case 'agent-preset-locked':
        return RpcErrorAgentPresetLocked.fromJson(json);
      case 'agent-preset-conflict':
        return RpcErrorAgentPresetConflict.fromJson(json);
      case 'agent-preset-not-found':
        return RpcErrorAgentPresetNotFound.fromJson(json);
      case 'agent-preset-invalid':
        return RpcErrorAgentPresetInvalid.fromJson(json);
      case 'agent-busy':
        return RpcErrorAgentBusy.fromJson(json);
      case 'attachment-error':
        return RpcErrorAttachmentError.fromJson(json);
      case 'queue-item-not-found':
        return RpcErrorQueueItemNotFound.fromJson(json);
      case 'steer-unavailable':
        return RpcErrorSteerUnavailable.fromJson(json);
      case 'command-error':
        return RpcErrorCommandError.fromJson(json);
      case 'unknown-command':
        return RpcErrorUnknownCommand.fromJson(json);
      case 'settings-rejected':
        return RpcErrorSettingsRejected.fromJson(json);
      case 'settings-not-exposed':
        return RpcErrorSettingsNotExposed.fromJson(json);
      case 'settings-conflict':
        return RpcErrorSettingsConflict.fromJson(json);
      case 'credential-rejected':
        return RpcErrorCredentialRejected.fromJson(json);
      case 'model-discovery-failed':
        return RpcErrorModelDiscoveryFailed.fromJson(json);
      case 'title-invalid':
        return RpcErrorTitleInvalid.fromJson(json);
      case 'fork-unavailable':
        return RpcErrorForkUnavailable.fromJson(json);
      case 'subagent-parent-unavailable':
        return RpcErrorSubagentParentUnavailable.fromJson(json);
      case 'subagent-not-found':
        return RpcErrorSubagentNotFound.fromJson(json);
      case 'subagent-catalog-diagnostic':
        return RpcErrorSubagentCatalogDiagnostic.fromJson(json);
      case 'subagent-not-resumable':
        return RpcErrorSubagentNotResumable.fromJson(json);
      case 'subagent-unauthorized':
        return RpcErrorSubagentUnauthorized.fromJson(json);
      case 'subagent-delivery-unavailable':
        return RpcErrorSubagentDeliveryUnavailable.fromJson(json);
      case 'internal':
        return RpcErrorInternal.fromJson(json);
      default:
        throw FormatException('RpcError: unknown code ' + tag);
    }
  }
}

/// "bad-request" variant of RpcError.
final class RpcErrorBadRequest extends RpcError {
  const RpcErrorBadRequest({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorBadRequest.fromJson(Map<String, dynamic> json) {
    return RpcErrorBadRequest(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'bad-request',
      'message': message,
      'details': details,
  };
}

/// "cancelled" variant of RpcError.
final class RpcErrorCancelled extends RpcError {
  const RpcErrorCancelled({required this.message, required this.details});
  final RpcId message;
  final AgentPresetListRequest details;
  factory RpcErrorCancelled.fromJson(Map<String, dynamic> json) {
    return RpcErrorCancelled(
      message: (json['message'] as String),
      details: AgentPresetListRequest.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'cancelled',
      'message': message,
      'details': details.toJson(),
  };
}

/// "session-not-found" variant of RpcError.
final class RpcErrorSessionNotFound extends RpcError {
  const RpcErrorSessionNotFound({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSessionNotFound.fromJson(Map<String, dynamic> json) {
    return RpcErrorSessionNotFound(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'session-not-found',
      'message': message,
      'details': details,
  };
}

/// "model-unavailable" variant of RpcError.
final class RpcErrorModelUnavailable extends RpcError {
  const RpcErrorModelUnavailable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorModelUnavailable.fromJson(Map<String, dynamic> json) {
    return RpcErrorModelUnavailable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'model-unavailable',
      'message': message,
      'details': details,
  };
}

/// "session-conflict" variant of RpcError.
final class RpcErrorSessionConflict extends RpcError {
  const RpcErrorSessionConflict({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSessionConflict.fromJson(Map<String, dynamic> json) {
    return RpcErrorSessionConflict(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'session-conflict',
      'message': message,
      'details': details,
  };
}

/// "invalid-time-zone" variant of RpcError.
final class RpcErrorInvalidTimeZone extends RpcError {
  const RpcErrorInvalidTimeZone({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorInvalidTimeZone.fromJson(Map<String, dynamic> json) {
    return RpcErrorInvalidTimeZone(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'invalid-time-zone',
      'message': message,
      'details': details,
  };
}

/// "workspace-attach-failed" variant of RpcError.
final class RpcErrorWorkspaceAttachFailed extends RpcError {
  const RpcErrorWorkspaceAttachFailed({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorWorkspaceAttachFailed.fromJson(Map<String, dynamic> json) {
    return RpcErrorWorkspaceAttachFailed(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'workspace-attach-failed',
      'message': message,
      'details': details,
  };
}

/// "workspace-not-found" variant of RpcError.
final class RpcErrorWorkspaceNotFound extends RpcError {
  const RpcErrorWorkspaceNotFound({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorWorkspaceNotFound.fromJson(Map<String, dynamic> json) {
    return RpcErrorWorkspaceNotFound(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'workspace-not-found',
      'message': message,
      'details': details,
  };
}

/// "workspace-invalid-path" variant of RpcError.
final class RpcErrorWorkspaceInvalidPath extends RpcError {
  const RpcErrorWorkspaceInvalidPath({required this.message, required this.details});
  final RpcId message;
  final HostCreateDirectoryValue details;
  factory RpcErrorWorkspaceInvalidPath.fromJson(Map<String, dynamic> json) {
    return RpcErrorWorkspaceInvalidPath(
      message: (json['message'] as String),
      details: HostCreateDirectoryValue.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'workspace-invalid-path',
      'message': message,
      'details': details.toJson(),
  };
}

/// "workspace-name-conflict" variant of RpcError.
final class RpcErrorWorkspaceNameConflict extends RpcError {
  const RpcErrorWorkspaceNameConflict({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorWorkspaceNameConflict.fromJson(Map<String, dynamic> json) {
    return RpcErrorWorkspaceNameConflict(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'workspace-name-conflict',
      'message': message,
      'details': details,
  };
}

/// "workspace-move-invalid" variant of RpcError.
final class RpcErrorWorkspaceMoveInvalid extends RpcError {
  const RpcErrorWorkspaceMoveInvalid({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorWorkspaceMoveInvalid.fromJson(Map<String, dynamic> json) {
    return RpcErrorWorkspaceMoveInvalid(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'workspace-move-invalid',
      'message': message,
      'details': details,
  };
}

/// "directory-unreadable" variant of RpcError.
final class RpcErrorDirectoryUnreadable extends RpcError {
  const RpcErrorDirectoryUnreadable({required this.message, required this.details});
  final RpcId message;
  final HostCreateDirectoryValue details;
  factory RpcErrorDirectoryUnreadable.fromJson(Map<String, dynamic> json) {
    return RpcErrorDirectoryUnreadable(
      message: (json['message'] as String),
      details: HostCreateDirectoryValue.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'directory-unreadable',
      'message': message,
      'details': details.toJson(),
  };
}

/// "directory-exists" variant of RpcError.
final class RpcErrorDirectoryExists extends RpcError {
  const RpcErrorDirectoryExists({required this.message, required this.details});
  final RpcId message;
  final HostCreateDirectoryValue details;
  factory RpcErrorDirectoryExists.fromJson(Map<String, dynamic> json) {
    return RpcErrorDirectoryExists(
      message: (json['message'] as String),
      details: HostCreateDirectoryValue.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'directory-exists',
      'message': message,
      'details': details.toJson(),
  };
}

/// "directory-create-failed" variant of RpcError.
final class RpcErrorDirectoryCreateFailed extends RpcError {
  const RpcErrorDirectoryCreateFailed({required this.message, required this.details});
  final RpcId message;
  final HostCreateDirectoryValue details;
  factory RpcErrorDirectoryCreateFailed.fromJson(Map<String, dynamic> json) {
    return RpcErrorDirectoryCreateFailed(
      message: (json['message'] as String),
      details: HostCreateDirectoryValue.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'directory-create-failed',
      'message': message,
      'details': details.toJson(),
  };
}

/// "directory-picker-unavailable" variant of RpcError.
final class RpcErrorDirectoryPickerUnavailable extends RpcError {
  const RpcErrorDirectoryPickerUnavailable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorDirectoryPickerUnavailable.fromJson(Map<String, dynamic> json) {
    return RpcErrorDirectoryPickerUnavailable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'directory-picker-unavailable',
      'message': message,
      'details': details,
  };
}

/// "agent-preset-read-only" variant of RpcError.
final class RpcErrorAgentPresetReadOnly extends RpcError {
  const RpcErrorAgentPresetReadOnly({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAgentPresetReadOnly.fromJson(Map<String, dynamic> json) {
    return RpcErrorAgentPresetReadOnly(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'agent-preset-read-only',
      'message': message,
      'details': details,
  };
}

/// "agent-preset-locked" variant of RpcError.
final class RpcErrorAgentPresetLocked extends RpcError {
  const RpcErrorAgentPresetLocked({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAgentPresetLocked.fromJson(Map<String, dynamic> json) {
    return RpcErrorAgentPresetLocked(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'agent-preset-locked',
      'message': message,
      'details': details,
  };
}

/// "agent-preset-conflict" variant of RpcError.
final class RpcErrorAgentPresetConflict extends RpcError {
  const RpcErrorAgentPresetConflict({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAgentPresetConflict.fromJson(Map<String, dynamic> json) {
    return RpcErrorAgentPresetConflict(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'agent-preset-conflict',
      'message': message,
      'details': details,
  };
}

/// "agent-preset-not-found" variant of RpcError.
final class RpcErrorAgentPresetNotFound extends RpcError {
  const RpcErrorAgentPresetNotFound({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAgentPresetNotFound.fromJson(Map<String, dynamic> json) {
    return RpcErrorAgentPresetNotFound(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'agent-preset-not-found',
      'message': message,
      'details': details,
  };
}

/// "agent-preset-invalid" variant of RpcError.
final class RpcErrorAgentPresetInvalid extends RpcError {
  const RpcErrorAgentPresetInvalid({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAgentPresetInvalid.fromJson(Map<String, dynamic> json) {
    return RpcErrorAgentPresetInvalid(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'agent-preset-invalid',
      'message': message,
      'details': details,
  };
}

/// "agent-busy" variant of RpcError.
final class RpcErrorAgentBusy extends RpcError {
  const RpcErrorAgentBusy({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAgentBusy.fromJson(Map<String, dynamic> json) {
    return RpcErrorAgentBusy(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'agent-busy',
      'message': message,
      'details': details,
  };
}

/// "attachment-error" variant of RpcError.
final class RpcErrorAttachmentError extends RpcError {
  const RpcErrorAttachmentError({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorAttachmentError.fromJson(Map<String, dynamic> json) {
    return RpcErrorAttachmentError(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'attachment-error',
      'message': message,
      'details': details,
  };
}

/// "queue-item-not-found" variant of RpcError.
final class RpcErrorQueueItemNotFound extends RpcError {
  const RpcErrorQueueItemNotFound({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorQueueItemNotFound.fromJson(Map<String, dynamic> json) {
    return RpcErrorQueueItemNotFound(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'queue-item-not-found',
      'message': message,
      'details': details,
  };
}

/// "steer-unavailable" variant of RpcError.
final class RpcErrorSteerUnavailable extends RpcError {
  const RpcErrorSteerUnavailable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSteerUnavailable.fromJson(Map<String, dynamic> json) {
    return RpcErrorSteerUnavailable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'steer-unavailable',
      'message': message,
      'details': details,
  };
}

/// "command-error" variant of RpcError.
final class RpcErrorCommandError extends RpcError {
  const RpcErrorCommandError({required this.message, required this.details});
  final RpcId message;
  final AgentPresetListRequest details;
  factory RpcErrorCommandError.fromJson(Map<String, dynamic> json) {
    return RpcErrorCommandError(
      message: (json['message'] as String),
      details: AgentPresetListRequest.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'command-error',
      'message': message,
      'details': details.toJson(),
  };
}

/// "unknown-command" variant of RpcError.
final class RpcErrorUnknownCommand extends RpcError {
  const RpcErrorUnknownCommand({required this.message, required this.details});
  final RpcId message;
  final AgentPresetListRequest details;
  factory RpcErrorUnknownCommand.fromJson(Map<String, dynamic> json) {
    return RpcErrorUnknownCommand(
      message: (json['message'] as String),
      details: AgentPresetListRequest.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'unknown-command',
      'message': message,
      'details': details.toJson(),
  };
}

/// "settings-rejected" variant of RpcError.
final class RpcErrorSettingsRejected extends RpcError {
  const RpcErrorSettingsRejected({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSettingsRejected.fromJson(Map<String, dynamic> json) {
    return RpcErrorSettingsRejected(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'settings-rejected',
      'message': message,
      'details': details,
  };
}

/// "settings-not-exposed" variant of RpcError.
final class RpcErrorSettingsNotExposed extends RpcError {
  const RpcErrorSettingsNotExposed({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSettingsNotExposed.fromJson(Map<String, dynamic> json) {
    return RpcErrorSettingsNotExposed(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'settings-not-exposed',
      'message': message,
      'details': details,
  };
}

/// "settings-conflict" variant of RpcError.
final class RpcErrorSettingsConflict extends RpcError {
  const RpcErrorSettingsConflict({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSettingsConflict.fromJson(Map<String, dynamic> json) {
    return RpcErrorSettingsConflict(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'settings-conflict',
      'message': message,
      'details': details,
  };
}

/// "credential-rejected" variant of RpcError.
final class RpcErrorCredentialRejected extends RpcError {
  const RpcErrorCredentialRejected({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorCredentialRejected.fromJson(Map<String, dynamic> json) {
    return RpcErrorCredentialRejected(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'credential-rejected',
      'message': message,
      'details': details,
  };
}

/// "model-discovery-failed" variant of RpcError.
final class RpcErrorModelDiscoveryFailed extends RpcError {
  const RpcErrorModelDiscoveryFailed({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorModelDiscoveryFailed.fromJson(Map<String, dynamic> json) {
    return RpcErrorModelDiscoveryFailed(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'model-discovery-failed',
      'message': message,
      'details': details,
  };
}

/// "title-invalid" variant of RpcError.
final class RpcErrorTitleInvalid extends RpcError {
  const RpcErrorTitleInvalid({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorTitleInvalid.fromJson(Map<String, dynamic> json) {
    return RpcErrorTitleInvalid(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'title-invalid',
      'message': message,
      'details': details,
  };
}

/// "fork-unavailable" variant of RpcError.
final class RpcErrorForkUnavailable extends RpcError {
  const RpcErrorForkUnavailable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorForkUnavailable.fromJson(Map<String, dynamic> json) {
    return RpcErrorForkUnavailable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'fork-unavailable',
      'message': message,
      'details': details,
  };
}

/// "subagent-parent-unavailable" variant of RpcError.
final class RpcErrorSubagentParentUnavailable extends RpcError {
  const RpcErrorSubagentParentUnavailable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSubagentParentUnavailable.fromJson(Map<String, dynamic> json) {
    return RpcErrorSubagentParentUnavailable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'subagent-parent-unavailable',
      'message': message,
      'details': details,
  };
}

/// "subagent-not-found" variant of RpcError.
final class RpcErrorSubagentNotFound extends RpcError {
  const RpcErrorSubagentNotFound({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSubagentNotFound.fromJson(Map<String, dynamic> json) {
    return RpcErrorSubagentNotFound(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'subagent-not-found',
      'message': message,
      'details': details,
  };
}

/// "subagent-catalog-diagnostic" variant of RpcError.
final class RpcErrorSubagentCatalogDiagnostic extends RpcError {
  const RpcErrorSubagentCatalogDiagnostic({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSubagentCatalogDiagnostic.fromJson(Map<String, dynamic> json) {
    return RpcErrorSubagentCatalogDiagnostic(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'subagent-catalog-diagnostic',
      'message': message,
      'details': details,
  };
}

/// "subagent-not-resumable" variant of RpcError.
final class RpcErrorSubagentNotResumable extends RpcError {
  const RpcErrorSubagentNotResumable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSubagentNotResumable.fromJson(Map<String, dynamic> json) {
    return RpcErrorSubagentNotResumable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'subagent-not-resumable',
      'message': message,
      'details': details,
  };
}

/// "subagent-unauthorized" variant of RpcError.
final class RpcErrorSubagentUnauthorized extends RpcError {
  const RpcErrorSubagentUnauthorized({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSubagentUnauthorized.fromJson(Map<String, dynamic> json) {
    return RpcErrorSubagentUnauthorized(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'subagent-unauthorized',
      'message': message,
      'details': details,
  };
}

/// "subagent-delivery-unavailable" variant of RpcError.
final class RpcErrorSubagentDeliveryUnavailable extends RpcError {
  const RpcErrorSubagentDeliveryUnavailable({required this.message, required this.details});
  final RpcId message;
  final Map<String, dynamic> details;
  factory RpcErrorSubagentDeliveryUnavailable.fromJson(Map<String, dynamic> json) {
    return RpcErrorSubagentDeliveryUnavailable(
      message: (json['message'] as String),
      details: (json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'subagent-delivery-unavailable',
      'message': message,
      'details': details,
  };
}

/// "internal" variant of RpcError.
final class RpcErrorInternal extends RpcError {
  const RpcErrorInternal({required this.message, required this.details});
  final RpcId message;
  final AgentPresetListRequest details;
  factory RpcErrorInternal.fromJson(Map<String, dynamic> json) {
    return RpcErrorInternal(
      message: (json['message'] as String),
      details: AgentPresetListRequest.fromJson(json['details'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'code': 'internal',
      'message': message,
      'details': details.toJson(),
  };
}

/// Branded string " + cls + ".
typedef RpcId = String;

/// Sealed union RpcMessage, discriminated by "type".
sealed class RpcMessage {
  const RpcMessage();
  Map<String, dynamic> toJson();
  factory RpcMessage.fromJson(Map<String, dynamic> json) {
    final tag = json['type'] as String;
    switch (tag) {
      case 'client-request':
        return RpcMessageClientRequest.fromJson(json);
      case 'server-response':
        return RpcMessageServerResponse.fromJson(json);
      case 'server-request':
        return RpcMessageServerRequest.fromJson(json);
      case 'client-response':
        return RpcMessageClientResponse.fromJson(json);
      default:
        throw FormatException('RpcMessage: unknown type ' + tag);
    }
  }
}

/// "client-request" variant of RpcMessage.
final class RpcMessageClientRequest extends RpcMessage {
  const RpcMessageClientRequest({required this.rpcId, required this.method, required this.payload});
  final RpcId rpcId;
  final RpcId method;
  final SessionLogQuery payload;
  factory RpcMessageClientRequest.fromJson(Map<String, dynamic> json) {
    return RpcMessageClientRequest(
      rpcId: (json['rpcId'] as String),
      method: (json['method'] as String),
      payload: json['payload'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'client-request',
      'rpcId': rpcId,
      'method': method,
      'payload': payload,
  };
}

/// "server-response" variant of RpcMessage.
final class RpcMessageServerResponse extends RpcMessage {
  const RpcMessageServerResponse({required this.rpcId, required this.result});
  final RpcId rpcId;
  final Object result;
  factory RpcMessageServerResponse.fromJson(Map<String, dynamic> json) {
    return RpcMessageServerResponse(
      rpcId: (json['rpcId'] as String),
      result: json['result'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'server-response',
      'rpcId': rpcId,
      'result': result,
  };
}

/// "server-request" variant of RpcMessage.
final class RpcMessageServerRequest extends RpcMessage {
  const RpcMessageServerRequest({required this.rpcId, required this.method, required this.payload});
  final RpcId rpcId;
  final RpcId method;
  final SessionLogQuery payload;
  factory RpcMessageServerRequest.fromJson(Map<String, dynamic> json) {
    return RpcMessageServerRequest(
      rpcId: (json['rpcId'] as String),
      method: (json['method'] as String),
      payload: json['payload'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'server-request',
      'rpcId': rpcId,
      'method': method,
      'payload': payload,
  };
}

/// "client-response" variant of RpcMessage.
final class RpcMessageClientResponse extends RpcMessage {
  const RpcMessageClientResponse({required this.rpcId, required this.result});
  final RpcId rpcId;
  final Object result;
  factory RpcMessageClientResponse.fromJson(Map<String, dynamic> json) {
    return RpcMessageClientResponse(
      rpcId: (json['rpcId'] as String),
      result: json['result'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'client-response',
      'rpcId': rpcId,
      'result': result,
  };
}

/// Untagged union RpcReceipt (kept open as dynamic).
typedef RpcReceipt = dynamic;

/// Wire model ServerRequest.
final class ServerRequest {
  const ServerRequest({required this.type, required this.rpcId, required this.method, required this.payload});
  final String type;
  final RpcId rpcId;
  final RpcId method;
  final SessionLogQuery payload;
  factory ServerRequest.fromJson(Map<String, dynamic> json) {
    return ServerRequest(
      type: (json['type'] as String),
      rpcId: (json['rpcId'] as String),
      method: (json['method'] as String),
      payload: json['payload'],
    );
  }
  Map<String, dynamic> toJson() => {
      'type': type,
      'rpcId': rpcId,
      'method': method,
      'payload': payload,
  };
}

/// Wire model ServerResponse.
final class ServerResponse {
  const ServerResponse({required this.type, required this.rpcId, required this.result});
  final String type;
  final RpcId rpcId;
  final Object result;
  factory ServerResponse.fromJson(Map<String, dynamic> json) {
    return ServerResponse(
      type: (json['type'] as String),
      rpcId: (json['rpcId'] as String),
      result: json['result'],
    );
  }
  Map<String, dynamic> toJson() => {
      'type': type,
      'rpcId': rpcId,
      'result': result,
  };
}

