part of 'wire_generated.dart';

// settings domain models.

/// Wire model SettingsDescribeRequest.
final class SettingsDescribeRequest {
  const SettingsDescribeRequest();
  factory SettingsDescribeRequest.fromJson(Map<String, dynamic> json) {
    return SettingsDescribeRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model SettingsDescribeValue.
final class SettingsDescribeValue {
  const SettingsDescribeValue({required this.writable, required this.hasDocument, required this.namespaces});
  final bool writable;
  final bool hasDocument;
  final List<SettingsMutateValue> namespaces;
  factory SettingsDescribeValue.fromJson(Map<String, dynamic> json) {
    return SettingsDescribeValue(
      writable: (json['writable'] as bool),
      hasDocument: (json['hasDocument'] as bool),
      namespaces: [for (final e in (json['namespaces'] as List)) SettingsMutateValue.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'writable': writable,
      'hasDocument': hasDocument,
      'namespaces': [for (final e in namespaces) e.toJson()],
  };
}

/// Wire model SettingsMutateRequest.
final class SettingsMutateRequest {
  const SettingsMutateRequest({required this.ns, required this.ops, this.expectedRevision});
  final ApprovalRequestId ns;
  final List<SettingsPathOp> ops;
  final double? expectedRevision;
  factory SettingsMutateRequest.fromJson(Map<String, dynamic> json) {
    return SettingsMutateRequest(
      ns: (json['ns'] as String),
      ops: [for (final e in (json['ops'] as List)) SettingsPathOp.fromJson(e as Map<String, dynamic>)],
      expectedRevision: json.containsKey('expectedRevision') ? (json['expectedRevision'] as num).toDouble() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'ops': [for (final e in ops) e.toJson()],
      if (expectedRevision != null) 'expectedRevision': expectedRevision!,
  };
}

/// Wire model SettingsMutateValue.
final class SettingsMutateValue {
  const SettingsMutateValue({required this.ns, required this.schema, required this.value, this.base_, this.user, required this.applies, required this.secrets, required this.revision});
  final ApprovalRequestId ns;
  final SessionLogQuery schema;
  final SessionLogQuery value;
  final SessionLogQuery? base_;
  final SessionLogQuery? user;
  final Object applies;
  final List<SettingsSecretView> secrets;
  final double revision;
  factory SettingsMutateValue.fromJson(Map<String, dynamic> json) {
    return SettingsMutateValue(
      ns: (json['ns'] as String),
      schema: json['schema'],
      value: json['value'],
      base_: json.containsKey('base') ? json['base'] : null,
      user: json.containsKey('user') ? json['user'] : null,
      applies: json['applies'],
      secrets: [for (final e in (json['secrets'] as List)) SettingsSecretView.fromJson(e as Map<String, dynamic>)],
      revision: (json['revision'] as num).toDouble(),
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'schema': schema,
      'value': value,
      if (base_ != null) 'base': base_!,
      if (user != null) 'user': user!,
      'applies': applies,
      'secrets': [for (final e in secrets) e.toJson()],
      'revision': revision,
  };
}

/// Wire model SettingsNamespaceView.
final class SettingsNamespaceView {
  const SettingsNamespaceView({required this.ns, required this.schema, required this.value, this.base_, this.user, required this.applies, required this.secrets, required this.revision});
  final ApprovalRequestId ns;
  final SessionLogQuery schema;
  final SessionLogQuery value;
  final SessionLogQuery? base_;
  final SessionLogQuery? user;
  final Object applies;
  final List<SettingsSecretView> secrets;
  final double revision;
  factory SettingsNamespaceView.fromJson(Map<String, dynamic> json) {
    return SettingsNamespaceView(
      ns: (json['ns'] as String),
      schema: json['schema'],
      value: json['value'],
      base_: json.containsKey('base') ? json['base'] : null,
      user: json.containsKey('user') ? json['user'] : null,
      applies: json['applies'],
      secrets: [for (final e in (json['secrets'] as List)) SettingsSecretView.fromJson(e as Map<String, dynamic>)],
      revision: (json['revision'] as num).toDouble(),
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'schema': schema,
      'value': value,
      if (base_ != null) 'base': base_!,
      if (user != null) 'user': user!,
      'applies': applies,
      'secrets': [for (final e in secrets) e.toJson()],
      'revision': revision,
  };
}

/// Wire model SettingsOpenDocumentRequest.
final class SettingsOpenDocumentRequest {
  const SettingsOpenDocumentRequest();
  factory SettingsOpenDocumentRequest.fromJson(Map<String, dynamic> json) {
    return SettingsOpenDocumentRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model SettingsOpenDocumentValue.
final class SettingsOpenDocumentValue {
  const SettingsOpenDocumentValue({required this.opened});
  final bool opened;
  factory SettingsOpenDocumentValue.fromJson(Map<String, dynamic> json) {
    return SettingsOpenDocumentValue(
      opened: (json['opened'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'opened': opened,
  };
}

/// Sealed union SettingsPathOp, discriminated by "op".
sealed class SettingsPathOp {
  const SettingsPathOp();
  Map<String, dynamic> toJson();
  factory SettingsPathOp.fromJson(Map<String, dynamic> json) {
    final tag = json['op'] as String;
    switch (tag) {
      case 'set':
        return SettingsPathOpSet.fromJson(json);
      case 'unset':
        return SettingsPathOpUnset.fromJson(json);
      default:
        throw FormatException('SettingsPathOp: unknown op ' + tag);
    }
  }
}

/// "set" variant of SettingsPathOp.
final class SettingsPathOpSet extends SettingsPathOp {
  const SettingsPathOpSet({required this.path, required this.value});
  final List<RpcId> path;
  final SessionLogQuery value;
  factory SettingsPathOpSet.fromJson(Map<String, dynamic> json) {
    return SettingsPathOpSet(
      path: [for (final e in (json['path'] as List)) (e as String)],
      value: json['value'],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'op': 'set',
      'path': [for (final e in path) e],
      'value': value,
  };
}

/// "unset" variant of SettingsPathOp.
final class SettingsPathOpUnset extends SettingsPathOp {
  const SettingsPathOpUnset({required this.path});
  final List<RpcId> path;
  factory SettingsPathOpUnset.fromJson(Map<String, dynamic> json) {
    return SettingsPathOpUnset(
      path: [for (final e in (json['path'] as List)) (e as String)],
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'op': 'unset',
      'path': [for (final e in path) e],
  };
}

/// Wire model SettingsReplaceRequest.
final class SettingsReplaceRequest {
  const SettingsReplaceRequest({required this.ns, required this.section, this.expectedRevision});
  final ApprovalRequestId ns;
  final Map<String, dynamic> section;
  final double? expectedRevision;
  factory SettingsReplaceRequest.fromJson(Map<String, dynamic> json) {
    return SettingsReplaceRequest(
      ns: (json['ns'] as String),
      section: (json['section'] as Map<String, dynamic>),
      expectedRevision: json.containsKey('expectedRevision') ? (json['expectedRevision'] as num).toDouble() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'section': section,
      if (expectedRevision != null) 'expectedRevision': expectedRevision!,
  };
}

/// Wire model SettingsReplaceValue.
final class SettingsReplaceValue {
  const SettingsReplaceValue({required this.ns, required this.schema, required this.value, this.base_, this.user, required this.applies, required this.secrets, required this.revision});
  final ApprovalRequestId ns;
  final SessionLogQuery schema;
  final SessionLogQuery value;
  final SessionLogQuery? base_;
  final SessionLogQuery? user;
  final Object applies;
  final List<SettingsSecretView> secrets;
  final double revision;
  factory SettingsReplaceValue.fromJson(Map<String, dynamic> json) {
    return SettingsReplaceValue(
      ns: (json['ns'] as String),
      schema: json['schema'],
      value: json['value'],
      base_: json.containsKey('base') ? json['base'] : null,
      user: json.containsKey('user') ? json['user'] : null,
      applies: json['applies'],
      secrets: [for (final e in (json['secrets'] as List)) SettingsSecretView.fromJson(e as Map<String, dynamic>)],
      revision: (json['revision'] as num).toDouble(),
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'schema': schema,
      'value': value,
      if (base_ != null) 'base': base_!,
      if (user != null) 'user': user!,
      'applies': applies,
      'secrets': [for (final e in secrets) e.toJson()],
      'revision': revision,
  };
}

/// Wire model SettingsSecretView.
final class SettingsSecretView {
  const SettingsSecretView({required this.path, required this.set_});
  final List<RpcId> path;
  final bool set_;
  factory SettingsSecretView.fromJson(Map<String, dynamic> json) {
    return SettingsSecretView(
      path: [for (final e in (json['path'] as List)) (e as String)],
      set_: (json['set'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': [for (final e in path) e],
      'set': set_,
  };
}

/// Wire model SettingsUpdateRequest.
final class SettingsUpdateRequest {
  const SettingsUpdateRequest({required this.ns, required this.patch, this.expectedRevision});
  final ApprovalRequestId ns;
  final Map<String, dynamic> patch;
  final double? expectedRevision;
  factory SettingsUpdateRequest.fromJson(Map<String, dynamic> json) {
    return SettingsUpdateRequest(
      ns: (json['ns'] as String),
      patch: (json['patch'] as Map<String, dynamic>),
      expectedRevision: json.containsKey('expectedRevision') ? (json['expectedRevision'] as num).toDouble() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'patch': patch,
      if (expectedRevision != null) 'expectedRevision': expectedRevision!,
  };
}

/// Wire model SettingsUpdateValue.
final class SettingsUpdateValue {
  const SettingsUpdateValue({required this.ns, required this.schema, required this.value, this.base_, this.user, required this.applies, required this.secrets, required this.revision});
  final ApprovalRequestId ns;
  final SessionLogQuery schema;
  final SessionLogQuery value;
  final SessionLogQuery? base_;
  final SessionLogQuery? user;
  final Object applies;
  final List<SettingsSecretView> secrets;
  final double revision;
  factory SettingsUpdateValue.fromJson(Map<String, dynamic> json) {
    return SettingsUpdateValue(
      ns: (json['ns'] as String),
      schema: json['schema'],
      value: json['value'],
      base_: json.containsKey('base') ? json['base'] : null,
      user: json.containsKey('user') ? json['user'] : null,
      applies: json['applies'],
      secrets: [for (final e in (json['secrets'] as List)) SettingsSecretView.fromJson(e as Map<String, dynamic>)],
      revision: (json['revision'] as num).toDouble(),
    );
  }
  Map<String, dynamic> toJson() => {
      'ns': ns,
      'schema': schema,
      'value': value,
      if (base_ != null) 'base': base_!,
      if (user != null) 'user': user!,
      'applies': applies,
      'secrets': [for (final e in secrets) e.toJson()],
      'revision': revision,
  };
}

