part of 'wire_generated.dart';

// host domain models.

/// Wire model DirectoryEntry.
final class DirectoryEntry {
  const DirectoryEntry({required this.name, required this.path, required this.hidden});
  final RpcId name;
  final RpcId path;
  final bool hidden;
  factory DirectoryEntry.fromJson(Map<String, dynamic> json) {
    return DirectoryEntry(
      name: (json['name'] as String),
      path: (json['path'] as String),
      hidden: (json['hidden'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'name': name,
      'path': path,
      'hidden': hidden,
  };
}

/// Wire model HostCreateDirectoryRequest.
final class HostCreateDirectoryRequest {
  const HostCreateDirectoryRequest({required this.path, required this.name});
  final RpcId path;
  final RpcId name;
  factory HostCreateDirectoryRequest.fromJson(Map<String, dynamic> json) {
    return HostCreateDirectoryRequest(
      path: (json['path'] as String),
      name: (json['name'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': path,
      'name': name,
  };
}

/// Wire model HostCreateDirectoryValue.
final class HostCreateDirectoryValue {
  const HostCreateDirectoryValue({required this.path});
  final RpcId path;
  factory HostCreateDirectoryValue.fromJson(Map<String, dynamic> json) {
    return HostCreateDirectoryValue(
      path: (json['path'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': path,
  };
}

/// Wire model HostDescribeRequest.
final class HostDescribeRequest {
  const HostDescribeRequest();
  factory HostDescribeRequest.fromJson(Map<String, dynamic> json) {
    return HostDescribeRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model HostDescribeValue.
final class HostDescribeValue {
  const HostDescribeValue({required this.version, required this.cwd, this.provider, this.model, required this.attachedSessions, required this.canOpenPath});
  final RpcId version;
  final RpcId cwd;
  final RpcId? provider;
  final RpcId? model;
  final int attachedSessions;
  final bool canOpenPath;
  factory HostDescribeValue.fromJson(Map<String, dynamic> json) {
    return HostDescribeValue(
      version: (json['version'] as String),
      cwd: (json['cwd'] as String),
      provider: json.containsKey('provider') ? (json['provider'] as String) : null,
      model: json.containsKey('model') ? (json['model'] as String) : null,
      attachedSessions: (json['attachedSessions'] as num).toInt(),
      canOpenPath: (json['canOpenPath'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'version': version,
      'cwd': cwd,
      if (provider != null) 'provider': provider!,
      if (model != null) 'model': model!,
      'attachedSessions': attachedSessions,
      'canOpenPath': canOpenPath,
  };
}

/// Wire model HostListDirectoryRequest.
final class HostListDirectoryRequest {
  const HostListDirectoryRequest({this.path});
  final RpcId? path;
  factory HostListDirectoryRequest.fromJson(Map<String, dynamic> json) {
    return HostListDirectoryRequest(
      path: json.containsKey('path') ? (json['path'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      if (path != null) 'path': path!,
  };
}

/// Wire model HostListDirectoryValue.
final class HostListDirectoryValue {
  const HostListDirectoryValue({required this.path, required this.home, required this.crumbs, required this.entries, required this.truncated});
  final RpcId path;
  final RpcId home;
  final List<DirectoryEntry> crumbs;
  final List<DirectoryEntry> entries;
  final bool truncated;
  factory HostListDirectoryValue.fromJson(Map<String, dynamic> json) {
    return HostListDirectoryValue(
      path: (json['path'] as String),
      home: (json['home'] as String),
      crumbs: [for (final e in (json['crumbs'] as List)) DirectoryEntry.fromJson(e as Map<String, dynamic>)],
      entries: [for (final e in (json['entries'] as List)) DirectoryEntry.fromJson(e as Map<String, dynamic>)],
      truncated: (json['truncated'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': path,
      'home': home,
      'crumbs': [for (final e in crumbs) e.toJson()],
      'entries': [for (final e in entries) e.toJson()],
      'truncated': truncated,
  };
}

/// Wire model HostOpenPathRequest.
final class HostOpenPathRequest {
  const HostOpenPathRequest({required this.path});
  final ApprovalRequestId path;
  factory HostOpenPathRequest.fromJson(Map<String, dynamic> json) {
    return HostOpenPathRequest(
      path: (json['path'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': path,
  };
}

/// Wire model HostOpenPathValue.
final class HostOpenPathValue {
  const HostOpenPathValue({required this.opened});
  final bool opened;
  factory HostOpenPathValue.fromJson(Map<String, dynamic> json) {
    return HostOpenPathValue(
      opened: (json['opened'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'opened': opened,
  };
}

/// Wire model HostPickDirectoryRequest.
final class HostPickDirectoryRequest {
  const HostPickDirectoryRequest();
  factory HostPickDirectoryRequest.fromJson(Map<String, dynamic> json) {
    return HostPickDirectoryRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model HostPickDirectoryValue.
final class HostPickDirectoryValue {
  const HostPickDirectoryValue({required this.path});
  final RpcId? path;
  factory HostPickDirectoryValue.fromJson(Map<String, dynamic> json) {
    return HostPickDirectoryValue(
      path: (json['path'] == null ? null : (json['path'] as String)),
    );
  }
  Map<String, dynamic> toJson() => {
      'path': path,
  };
}

