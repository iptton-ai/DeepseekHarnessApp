part of 'wire_generated.dart';

// credentials domain models.

/// Branded string " + cls + ".
typedef CredentialRefName = String;

/// Wire model CredentialView.
final class CredentialView {
  const CredentialView({required this.configured, this.source, required this.writable});
  final bool configured;
  final RpcId? source;
  final bool writable;
  factory CredentialView.fromJson(Map<String, dynamic> json) {
    return CredentialView(
      configured: (json['configured'] as bool),
      source: json.containsKey('source') ? (json['source'] as String) : null,
      writable: (json['writable'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'configured': configured,
      if (source != null) 'source': source!,
      'writable': writable,
  };
}

/// Wire model CredentialsDescribeRequest.
final class CredentialsDescribeRequest {
  const CredentialsDescribeRequest({required this.refs});
  final List<CredentialRefName> refs;
  factory CredentialsDescribeRequest.fromJson(Map<String, dynamic> json) {
    return CredentialsDescribeRequest(
      refs: [for (final e in (json['refs'] as List)) (e as String)],
    );
  }
  Map<String, dynamic> toJson() => {
      'refs': [for (final e in refs) e],
  };
}

/// Wire model CredentialsDescribeValue.
final class CredentialsDescribeValue {
  const CredentialsDescribeValue({required this.credentials});
  final Map<String, dynamic> credentials;
  factory CredentialsDescribeValue.fromJson(Map<String, dynamic> json) {
    return CredentialsDescribeValue(
      credentials: (json['credentials'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'credentials': credentials,
  };
}

/// Wire model CredentialsSetRequest.
final class CredentialsSetRequest {
  const CredentialsSetRequest({required this.ref, required this.value});
  final CredentialRefName ref;
  final ApprovalRequestId value;
  factory CredentialsSetRequest.fromJson(Map<String, dynamic> json) {
    return CredentialsSetRequest(
      ref: (json['ref'] as String),
      value: (json['value'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref,
      'value': value,
  };
}

/// Wire model CredentialsSetValue.
final class CredentialsSetValue {
  const CredentialsSetValue();
  factory CredentialsSetValue.fromJson(Map<String, dynamic> json) {
    return CredentialsSetValue(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model CredentialsUnsetRequest.
final class CredentialsUnsetRequest {
  const CredentialsUnsetRequest({required this.ref});
  final CredentialRefName ref;
  factory CredentialsUnsetRequest.fromJson(Map<String, dynamic> json) {
    return CredentialsUnsetRequest(
      ref: (json['ref'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'ref': ref,
  };
}

/// Wire model CredentialsUnsetValue.
final class CredentialsUnsetValue {
  const CredentialsUnsetValue();
  factory CredentialsUnsetValue.fromJson(Map<String, dynamic> json) {
    return CredentialsUnsetValue(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

