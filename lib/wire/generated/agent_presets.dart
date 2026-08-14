part of 'wire_generated.dart';

// agent-presets domain models.

/// Wire model AgentPresetCopyRequest.
final class AgentPresetCopyRequest {
  const AgentPresetCopyRequest({required this.from, required this.agentPreset, this.name});
  final ApprovalRequestId from;
  final ApprovalRequestId agentPreset;
  final RpcId? name;
  factory AgentPresetCopyRequest.fromJson(Map<String, dynamic> json) {
    return AgentPresetCopyRequest(
      from: (json['from'] as String),
      agentPreset: (json['agentPreset'] as String),
      name: json.containsKey('name') ? (json['name'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'from': from,
      'agentPreset': agentPreset,
      if (name != null) 'name': name!,
  };
}

/// Wire model AgentPresetCopyValue.
final class AgentPresetCopyValue {
  const AgentPresetCopyValue({required this.agentPreset});
  final RpcId agentPreset;
  factory AgentPresetCopyValue.fromJson(Map<String, dynamic> json) {
    return AgentPresetCopyValue(
      agentPreset: (json['agentPreset'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'agentPreset': agentPreset,
  };
}

/// Wire model AgentPresetEntry.
final class AgentPresetEntry {
  const AgentPresetEntry({required this.id, required this.trust, required this.isDefault, this.name, this.description, this.broken});
  final ApprovalRequestId id;
  final Object trust;
  final bool isDefault;
  final RpcId? name;
  final RpcId? description;
  final ApprovalRequestId? broken;
  factory AgentPresetEntry.fromJson(Map<String, dynamic> json) {
    return AgentPresetEntry(
      id: (json['id'] as String),
      trust: json['trust'],
      isDefault: (json['isDefault'] as bool),
      name: json.containsKey('name') ? (json['name'] as String) : null,
      description: json.containsKey('description') ? (json['description'] as String) : null,
      broken: json.containsKey('broken') ? (json['broken'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'trust': trust,
      'isDefault': isDefault,
      if (name != null) 'name': name!,
      if (description != null) 'description': description!,
      if (broken != null) 'broken': broken!,
  };
}

/// Wire model AgentPresetListRequest.
final class AgentPresetListRequest {
  const AgentPresetListRequest();
  factory AgentPresetListRequest.fromJson(Map<String, dynamic> json) {
    return AgentPresetListRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model AgentPresetListValue.
final class AgentPresetListValue {
  const AgentPresetListValue({required this.presets, required this.authorable, required this.hasDocument});
  final List<AgentPresetEntry> presets;
  final bool authorable;
  final bool hasDocument;
  factory AgentPresetListValue.fromJson(Map<String, dynamic> json) {
    return AgentPresetListValue(
      presets: [for (final e in (json['presets'] as List)) AgentPresetEntry.fromJson(e as Map<String, dynamic>)],
      authorable: (json['authorable'] as bool),
      hasDocument: (json['hasDocument'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'presets': [for (final e in presets) e.toJson()],
      'authorable': authorable,
      'hasDocument': hasDocument,
  };
}

/// Wire model AgentPresetOpenDocumentRequest.
final class AgentPresetOpenDocumentRequest {
  const AgentPresetOpenDocumentRequest({required this.agentPreset});
  final ApprovalRequestId agentPreset;
  factory AgentPresetOpenDocumentRequest.fromJson(Map<String, dynamic> json) {
    return AgentPresetOpenDocumentRequest(
      agentPreset: (json['agentPreset'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'agentPreset': agentPreset,
  };
}

/// Untagged union AgentPresetOpenDocumentValue (kept open as dynamic).
typedef AgentPresetOpenDocumentValue = dynamic;

/// Wire model AgentPresetReadRequest.
final class AgentPresetReadRequest {
  const AgentPresetReadRequest({required this.agentPreset});
  final ApprovalRequestId agentPreset;
  factory AgentPresetReadRequest.fromJson(Map<String, dynamic> json) {
    return AgentPresetReadRequest(
      agentPreset: (json['agentPreset'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'agentPreset': agentPreset,
  };
}

/// Wire model AgentPresetReadValue.
final class AgentPresetReadValue {
  const AgentPresetReadValue({required this.agentPreset, required this.trust, required this.content, this.name, this.description});
  final RpcId agentPreset;
  final Object trust;
  final RpcId content;
  final RpcId? name;
  final RpcId? description;
  factory AgentPresetReadValue.fromJson(Map<String, dynamic> json) {
    return AgentPresetReadValue(
      agentPreset: (json['agentPreset'] as String),
      trust: json['trust'],
      content: (json['content'] as String),
      name: json.containsKey('name') ? (json['name'] as String) : null,
      description: json.containsKey('description') ? (json['description'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'agentPreset': agentPreset,
      'trust': trust,
      'content': content,
      if (name != null) 'name': name!,
      if (description != null) 'description': description!,
  };
}

/// Wire model AgentPresetRemoveRequest.
final class AgentPresetRemoveRequest {
  const AgentPresetRemoveRequest({required this.agentPreset});
  final ApprovalRequestId agentPreset;
  factory AgentPresetRemoveRequest.fromJson(Map<String, dynamic> json) {
    return AgentPresetRemoveRequest(
      agentPreset: (json['agentPreset'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'agentPreset': agentPreset,
  };
}

/// Wire model AgentPresetRemoveValue.
final class AgentPresetRemoveValue {
  const AgentPresetRemoveValue();
  factory AgentPresetRemoveValue.fromJson(Map<String, dynamic> json) {
    return AgentPresetRemoveValue(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model AgentPresetSelectRequest.
final class AgentPresetSelectRequest {
  const AgentPresetSelectRequest({required this.sessionId, required this.agentPreset});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId agentPreset;
  factory AgentPresetSelectRequest.fromJson(Map<String, dynamic> json) {
    return AgentPresetSelectRequest(
      sessionId: (json['sessionId'] as String),
      agentPreset: (json['agentPreset'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'agentPreset': agentPreset,
  };
}

/// Wire model AgentPresetSelectValue.
final class AgentPresetSelectValue {
  const AgentPresetSelectValue({required this.agentPreset});
  final RpcId agentPreset;
  factory AgentPresetSelectValue.fromJson(Map<String, dynamic> json) {
    return AgentPresetSelectValue(
      agentPreset: (json['agentPreset'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'agentPreset': agentPreset,
  };
}

