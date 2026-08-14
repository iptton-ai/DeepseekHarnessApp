part of 'wire_generated.dart';

// skills domain models.

/// Wire model SkillEntry.
final class SkillEntry {
  const SkillEntry({required this.name, required this.description, this.whenToUse, required this.modelInvocable});
  final ApprovalRequestId name;
  final RpcId description;
  final RpcId? whenToUse;
  final bool modelInvocable;
  factory SkillEntry.fromJson(Map<String, dynamic> json) {
    return SkillEntry(
      name: (json['name'] as String),
      description: (json['description'] as String),
      whenToUse: json.containsKey('whenToUse') ? (json['whenToUse'] as String) : null,
      modelInvocable: (json['modelInvocable'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'name': name,
      'description': description,
      if (whenToUse != null) 'whenToUse': whenToUse!,
      'modelInvocable': modelInvocable,
  };
}

/// Wire model SkillListRequest.
final class SkillListRequest {
  const SkillListRequest({required this.sessionId});
  final ApprovalRequestId sessionId;
  factory SkillListRequest.fromJson(Map<String, dynamic> json) {
    return SkillListRequest(
      sessionId: (json['sessionId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
  };
}

/// Wire model SkillListValue.
final class SkillListValue {
  const SkillListValue({required this.skills});
  final List<SkillEntry> skills;
  factory SkillListValue.fromJson(Map<String, dynamic> json) {
    return SkillListValue(
      skills: [for (final e in (json['skills'] as List)) SkillEntry.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'skills': [for (final e in skills) e.toJson()],
  };
}

