part of 'wire_generated.dart';

// approvals domain models.

/// Branded string " + cls + ".
typedef ApprovalRequestId = String;

/// Wire model ApprovalResponsePayload.
final class ApprovalResponsePayload {
  const ApprovalResponsePayload({required this.sessionId, required this.approvalId, required this.outcome});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId approvalId;
  final Object outcome;
  factory ApprovalResponsePayload.fromJson(Map<String, dynamic> json) {
    return ApprovalResponsePayload(
      sessionId: (json['sessionId'] as String),
      approvalId: (json['approvalId'] as String),
      outcome: json['outcome'],
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'approvalId': approvalId,
      'outcome': outcome,
  };
}

