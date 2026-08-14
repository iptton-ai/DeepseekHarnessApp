part of 'wire_generated.dart';

// llm domain models.

/// Wire model ConfigurableProviderView.
final class ConfigurableProviderView {
  const ConfigurableProviderView({required this.provider, required this.displayName, required this.settingsNs, required this.settingsPath, required this.active, this.declared});
  final ApprovalRequestId provider;
  final ApprovalRequestId displayName;
  final RpcId settingsNs;
  final List<RpcId> settingsPath;
  final bool active;
  final bool? declared;
  factory ConfigurableProviderView.fromJson(Map<String, dynamic> json) {
    return ConfigurableProviderView(
      provider: (json['provider'] as String),
      displayName: (json['displayName'] as String),
      settingsNs: (json['settingsNs'] as String),
      settingsPath: [for (final e in (json['settingsPath'] as List)) (e as String)],
      active: (json['active'] as bool),
      declared: json.containsKey('declared') ? (json['declared'] as bool) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'provider': provider,
      'displayName': displayName,
      'settingsNs': settingsNs,
      'settingsPath': [for (final e in settingsPath) e],
      'active': active,
      if (declared != null) 'declared': declared!,
  };
}

/// Wire model DiscoveredModelView.
final class DiscoveredModelView {
  const DiscoveredModelView({required this.id, this.name, this.contextWindow, this.maxTokens});
  final ApprovalRequestId id;
  final ApprovalRequestId? name;
  final int? contextWindow;
  final int? maxTokens;
  factory DiscoveredModelView.fromJson(Map<String, dynamic> json) {
    return DiscoveredModelView(
      id: (json['id'] as String),
      name: json.containsKey('name') ? (json['name'] as String) : null,
      contextWindow: json.containsKey('contextWindow') ? (json['contextWindow'] as num).toInt() : null,
      maxTokens: json.containsKey('maxTokens') ? (json['maxTokens'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      if (name != null) 'name': name!,
      if (contextWindow != null) 'contextWindow': contextWindow!,
      if (maxTokens != null) 'maxTokens': maxTokens!,
  };
}

/// Wire model LlmDiscoverModelsRequest.
final class LlmDiscoverModelsRequest {
  const LlmDiscoverModelsRequest({required this.settingsNs, this.provider, this.baseURL, this.api, this.apiKey});
  final ApprovalRequestId settingsNs;
  final ApprovalRequestId? provider;
  final ApprovalRequestId? baseURL;
  final ApprovalRequestId? api;
  final ApprovalRequestId? apiKey;
  factory LlmDiscoverModelsRequest.fromJson(Map<String, dynamic> json) {
    return LlmDiscoverModelsRequest(
      settingsNs: (json['settingsNs'] as String),
      provider: json.containsKey('provider') ? (json['provider'] as String) : null,
      baseURL: json.containsKey('baseURL') ? (json['baseURL'] as String) : null,
      api: json.containsKey('api') ? (json['api'] as String) : null,
      apiKey: json.containsKey('apiKey') ? (json['apiKey'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'settingsNs': settingsNs,
      if (provider != null) 'provider': provider!,
      if (baseURL != null) 'baseURL': baseURL!,
      if (api != null) 'api': api!,
      if (apiKey != null) 'apiKey': apiKey!,
  };
}

/// Wire model LlmDiscoverModelsValue.
final class LlmDiscoverModelsValue {
  const LlmDiscoverModelsValue({required this.models});
  final List<DiscoveredModelView> models;
  factory LlmDiscoverModelsValue.fromJson(Map<String, dynamic> json) {
    return LlmDiscoverModelsValue(
      models: [for (final e in (json['models'] as List)) DiscoveredModelView.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'models': [for (final e in models) e.toJson()],
  };
}

/// Wire model LlmModelsRequest.
final class LlmModelsRequest {
  const LlmModelsRequest();
  factory LlmModelsRequest.fromJson(Map<String, dynamic> json) {
    return LlmModelsRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model LlmModelsValue.
final class LlmModelsValue {
  const LlmModelsValue({required this.groups, required this.failures});
  final List<ModelProviderGroup> groups;
  final List<ModelCatalogFailure> failures;
  factory LlmModelsValue.fromJson(Map<String, dynamic> json) {
    return LlmModelsValue(
      groups: [for (final e in (json['groups'] as List)) ModelProviderGroup.fromJson(e as Map<String, dynamic>)],
      failures: [for (final e in (json['failures'] as List)) ModelCatalogFailure.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'groups': [for (final e in groups) e.toJson()],
      'failures': [for (final e in failures) e.toJson()],
  };
}

/// Wire model LlmProvidersRequest.
final class LlmProvidersRequest {
  const LlmProvidersRequest();
  factory LlmProvidersRequest.fromJson(Map<String, dynamic> json) {
    return LlmProvidersRequest(
    );
  }
  Map<String, dynamic> toJson() => {
  };
}

/// Wire model LlmProvidersValue.
final class LlmProvidersValue {
  const LlmProvidersValue({required this.providers});
  final List<ConfigurableProviderView> providers;
  factory LlmProvidersValue.fromJson(Map<String, dynamic> json) {
    return LlmProvidersValue(
      providers: [for (final e in (json['providers'] as List)) ConfigurableProviderView.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'providers': [for (final e in providers) e.toJson()],
  };
}

