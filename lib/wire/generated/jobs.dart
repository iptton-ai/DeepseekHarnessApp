part of 'wire_generated.dart';

// jobs domain models.

/// Branded string " + cls + ".
typedef TaskId = String;

/// Wire model TaskView.
final class TaskView {
  const TaskView({required this.id, required this.kind, required this.label, required this.status, this.detail, required this.startedAt, this.finishedAt});
  final ApprovalRequestId id;
  final ApprovalRequestId kind;
  final ApprovalRequestId label;
  final Object status;
  final RpcId? detail;
  final int startedAt;
  final int? finishedAt;
  factory TaskView.fromJson(Map<String, dynamic> json) {
    return TaskView(
      id: (json['id'] as String),
      kind: (json['kind'] as String),
      label: (json['label'] as String),
      status: json['status'],
      detail: json.containsKey('detail') ? (json['detail'] as String) : null,
      startedAt: (json['startedAt'] as num).toInt(),
      finishedAt: json.containsKey('finishedAt') ? (json['finishedAt'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'kind': kind,
      'label': label,
      'status': status,
      if (detail != null) 'detail': detail!,
      'startedAt': startedAt,
      if (finishedAt != null) 'finishedAt': finishedAt!,
  };
}

