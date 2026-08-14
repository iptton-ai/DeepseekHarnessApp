part of 'wire_generated.dart';

// goals domain models.

/// Wire model GoalClearRequest.
final class GoalClearRequest {
  const GoalClearRequest({required this.sessionId, required this.ref});
  final RpcId sessionId;
  final GoalRef ref;
  factory GoalClearRequest.fromJson(Map<String, dynamic> json) {
    return GoalClearRequest(
      sessionId: (json['sessionId'] as String),
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'ref': ref.toJson(),
  };
}

/// Wire model GoalClearValue.
final class GoalClearValue {
  const GoalClearValue({required this.cleared});
  final bool cleared;
  factory GoalClearValue.fromJson(Map<String, dynamic> json) {
    return GoalClearValue(
      cleared: (json['cleared'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'cleared': cleared,
  };
}

/// Wire model GoalCompleteRequest.
final class GoalCompleteRequest {
  const GoalCompleteRequest({required this.sessionId, required this.ref});
  final RpcId sessionId;
  final GoalRef ref;
  factory GoalCompleteRequest.fromJson(Map<String, dynamic> json) {
    return GoalCompleteRequest(
      sessionId: (json['sessionId'] as String),
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'ref': ref.toJson(),
  };
}

/// Wire model GoalCompleteValue.
final class GoalCompleteValue {
  const GoalCompleteValue({required this.ref});
  final GoalRef ref;
  factory GoalCompleteValue.fromJson(Map<String, dynamic> json) {
    return GoalCompleteValue(
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref.toJson(),
  };
}

/// Wire model GoalCreateRequest.
final class GoalCreateRequest {
  const GoalCreateRequest({required this.sessionId, required this.objective, this.maxGoalRounds});
  final RpcId sessionId;
  final ApprovalRequestId objective;
  final int? maxGoalRounds;
  factory GoalCreateRequest.fromJson(Map<String, dynamic> json) {
    return GoalCreateRequest(
      sessionId: (json['sessionId'] as String),
      objective: (json['objective'] as String),
      maxGoalRounds: json.containsKey('maxGoalRounds') ? (json['maxGoalRounds'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'objective': objective,
      if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds!,
  };
}

/// Wire model GoalCreateValue.
final class GoalCreateValue {
  const GoalCreateValue({required this.ref});
  final GoalRef ref;
  factory GoalCreateValue.fromJson(Map<String, dynamic> json) {
    return GoalCreateValue(
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref.toJson(),
  };
}

/// Wire model GoalEditRequest.
final class GoalEditRequest {
  const GoalEditRequest({required this.sessionId, required this.ref, this.objective, this.maxGoalRounds});
  final RpcId sessionId;
  final GoalRef ref;
  final ApprovalRequestId? objective;
  final int? maxGoalRounds;
  factory GoalEditRequest.fromJson(Map<String, dynamic> json) {
    return GoalEditRequest(
      sessionId: (json['sessionId'] as String),
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
      objective: json.containsKey('objective') ? (json['objective'] as String) : null,
      maxGoalRounds: json.containsKey('maxGoalRounds') ? (json['maxGoalRounds'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'ref': ref.toJson(),
      if (objective != null) 'objective': objective!,
      if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds!,
  };
}

/// Wire model GoalEditValue.
final class GoalEditValue {
  const GoalEditValue({required this.ref});
  final GoalRef ref;
  factory GoalEditValue.fromJson(Map<String, dynamic> json) {
    return GoalEditValue(
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref.toJson(),
  };
}

/// Wire model GoalPauseRequest.
final class GoalPauseRequest {
  const GoalPauseRequest({required this.sessionId, required this.ref});
  final RpcId sessionId;
  final GoalRef ref;
  factory GoalPauseRequest.fromJson(Map<String, dynamic> json) {
    return GoalPauseRequest(
      sessionId: (json['sessionId'] as String),
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'ref': ref.toJson(),
  };
}

/// Wire model GoalPauseValue.
final class GoalPauseValue {
  const GoalPauseValue({required this.ref});
  final GoalRef ref;
  factory GoalPauseValue.fromJson(Map<String, dynamic> json) {
    return GoalPauseValue(
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref.toJson(),
  };
}

/// Wire model GoalRef.
final class GoalRef {
  const GoalRef({required this.id, required this.revision});
  final RpcId id;
  final int revision;
  factory GoalRef.fromJson(Map<String, dynamic> json) {
    return GoalRef(
      id: (json['id'] as String),
      revision: (json['revision'] as num).toInt(),
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'revision': revision,
  };
}

/// Wire model GoalResumeRequest.
final class GoalResumeRequest {
  const GoalResumeRequest({required this.sessionId, required this.ref});
  final RpcId sessionId;
  final GoalRef ref;
  factory GoalResumeRequest.fromJson(Map<String, dynamic> json) {
    return GoalResumeRequest(
      sessionId: (json['sessionId'] as String),
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'ref': ref.toJson(),
  };
}

/// Wire model GoalResumeValue.
final class GoalResumeValue {
  const GoalResumeValue({required this.ref});
  final GoalRef ref;
  factory GoalResumeValue.fromJson(Map<String, dynamic> json) {
    return GoalResumeValue(
      ref: GoalRef.fromJson(json['ref'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref.toJson(),
  };
}

