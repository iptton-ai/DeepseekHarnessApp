part of 'wire_generated.dart';

// subagents domain models.

/// Wire model SubagentHistoryRequest.
final class SubagentHistoryRequest {
  const SubagentHistoryRequest({required this.parentSessionId, required this.childSessionId, required this.mode, this.beforeSeq, this.maxMessages});
  final ApprovalRequestId parentSessionId;
  final ApprovalRequestId childSessionId;
  final Object mode;
  final int? beforeSeq;
  final int? maxMessages;
  factory SubagentHistoryRequest.fromJson(Map<String, dynamic> json) {
    return SubagentHistoryRequest(
      parentSessionId: (json['parentSessionId'] as String),
      childSessionId: (json['childSessionId'] as String),
      mode: json['mode'],
      beforeSeq: json.containsKey('beforeSeq') ? (json['beforeSeq'] as num).toInt() : null,
      maxMessages: json.containsKey('maxMessages') ? (json['maxMessages'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': mode,
      if (beforeSeq != null) 'beforeSeq': beforeSeq!,
      if (maxMessages != null) 'maxMessages': maxMessages!,
  };
}

/// Wire model SubagentHistoryValue.
final class SubagentHistoryValue {
  const SubagentHistoryValue({required this.events, required this.hasMore, this.projections});
  final List<HistoryEntry> events;
  final bool hasMore;
  final SessionProjectionsBlock? projections;
  factory SubagentHistoryValue.fromJson(Map<String, dynamic> json) {
    return SubagentHistoryValue(
      events: [for (final e in (json['events'] as List)) HistoryEntry.fromJson(e as Map<String, dynamic>)],
      hasMore: (json['hasMore'] as bool),
      projections: json.containsKey('projections') ? SessionProjectionsBlock.fromJson(json['projections'] as Map<String, dynamic>) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'events': [for (final e in events) e.toJson()],
      'hasMore': hasMore,
      if (projections != null) 'projections': projections!.toJson(),
  };
}

/// Wire model SubagentInterruptRequest.
final class SubagentInterruptRequest {
  const SubagentInterruptRequest({required this.parentSessionId, required this.childSessionId, required this.mode});
  final ApprovalRequestId parentSessionId;
  final ApprovalRequestId childSessionId;
  final String mode;
  factory SubagentInterruptRequest.fromJson(Map<String, dynamic> json) {
    return SubagentInterruptRequest(
      parentSessionId: (json['parentSessionId'] as String),
      childSessionId: (json['childSessionId'] as String),
      mode: (json['mode'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': mode,
  };
}

/// Wire model SubagentInterruptValue.
final class SubagentInterruptValue {
  const SubagentInterruptValue({required this.accepted});
  final bool accepted;
  factory SubagentInterruptValue.fromJson(Map<String, dynamic> json) {
    return SubagentInterruptValue(
      accepted: (json['accepted'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'accepted': accepted,
  };
}

/// Sealed union SubagentListEntry, discriminated by "kind".
sealed class SubagentListEntry {
  const SubagentListEntry();
  Map<String, dynamic> toJson();
  factory SubagentListEntry.fromJson(Map<String, dynamic> json) {
    final tag = json['kind'] as String;
    switch (tag) {
      case 'child':
        return SubagentListEntryChild.fromJson(json);
      case 'diagnostic':
        return SubagentListEntryDiagnostic.fromJson(json);
      default:
        throw FormatException('SubagentListEntry: unknown kind ' + tag);
    }
  }
}

/// "child" variant of SubagentListEntry.
final class SubagentListEntryChild extends SubagentListEntry {
  const SubagentListEntryChild({required this.id, required this.mode, required this.activity, required this.hasChildren, this.label});
  final ApprovalRequestId id;
  final SessionLogQuery mode;
  final Object activity;
  final bool hasChildren;
  final RpcId? label;
  factory SubagentListEntryChild.fromJson(Map<String, dynamic> json) {
    return SubagentListEntryChild(
      id: (json['id'] as String),
      mode: json['mode'],
      activity: json['activity'],
      hasChildren: (json['hasChildren'] as bool),
      label: json.containsKey('label') ? (json['label'] as String) : null,
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'child',
      'id': id,
      'mode': mode,
      'activity': activity,
      'hasChildren': hasChildren,
      if (label != null) 'label': label!,
  };
}

/// "diagnostic" variant of SubagentListEntry.
final class SubagentListEntryDiagnostic extends SubagentListEntry {
  const SubagentListEntryDiagnostic({required this.id, required this.reason});
  final ApprovalRequestId id;
  final Object reason;
  factory SubagentListEntryDiagnostic.fromJson(Map<String, dynamic> json) {
    return SubagentListEntryDiagnostic(
      id: (json['id'] as String),
      reason: json['reason'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'diagnostic',
      'id': id,
      'reason': reason,
  };
}

/// Wire model SubagentListRequest.
final class SubagentListRequest {
  const SubagentListRequest({required this.parentSessionId});
  final ApprovalRequestId parentSessionId;
  factory SubagentListRequest.fromJson(Map<String, dynamic> json) {
    return SubagentListRequest(
      parentSessionId: (json['parentSessionId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'parentSessionId': parentSessionId,
  };
}

/// Wire model SubagentListValue.
final class SubagentListValue {
  const SubagentListValue({required this.entries, required this.parentAvailable});
  final List<SubagentListEntry> entries;
  final bool parentAvailable;
  factory SubagentListValue.fromJson(Map<String, dynamic> json) {
    return SubagentListValue(
      entries: [for (final e in (json['entries'] as List)) SubagentListEntry.fromJson(e as Map<String, dynamic>)],
      parentAvailable: (json['parentAvailable'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'entries': [for (final e in entries) e.toJson()],
      'parentAvailable': parentAvailable,
  };
}

/// Wire model SubagentPromptRequest.
final class SubagentPromptRequest {
  const SubagentPromptRequest({required this.parentSessionId, required this.childSessionId, required this.mode, required this.content, this.clientTimeZone});
  final ApprovalRequestId parentSessionId;
  final ApprovalRequestId childSessionId;
  final String mode;
  final List<ContentBlock> content;
  final RpcId? clientTimeZone;
  factory SubagentPromptRequest.fromJson(Map<String, dynamic> json) {
    return SubagentPromptRequest(
      parentSessionId: (json['parentSessionId'] as String),
      childSessionId: (json['childSessionId'] as String),
      mode: (json['mode'] as String),
      content: [for (final e in (json['content'] as List)) ContentBlock.fromJson(e as Map<String, dynamic>)],
      clientTimeZone: json.containsKey('clientTimeZone') ? (json['clientTimeZone'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': mode,
      'content': [for (final e in content) e.toJson()],
      if (clientTimeZone != null) 'clientTimeZone': clientTimeZone!,
  };
}

/// Wire model SubagentPromptValue.
final class SubagentPromptValue {
  const SubagentPromptValue({required this.messageId});
  final RpcId messageId;
  factory SubagentPromptValue.fromJson(Map<String, dynamic> json) {
    return SubagentPromptValue(
      messageId: (json['messageId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'messageId': messageId,
  };
}

