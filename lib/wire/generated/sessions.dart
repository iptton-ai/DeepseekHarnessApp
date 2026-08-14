part of 'wire_generated.dart';

// sessions domain models.

/// Branded string " + cls + ".
typedef AttachmentId = String;

/// Wire model ContentBlock.
final class ContentBlock {
  const ContentBlock({required this.type});
  final RpcId type;
  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    return ContentBlock(
      type: (json['type'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'type': type,
  };
}

/// Wire model HistoryEntry.
final class HistoryEntry {
  const HistoryEntry({required this.event, this.view});
  final SessionEvent event;
  final ToolEventView? view;
  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      event: SessionEvent.fromJson(json['event'] as Map<String, dynamic>),
      view: json.containsKey('view') ? ToolEventView.fromJson(json['view'] as Map<String, dynamic>) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'event': event.toJson(),
      if (view != null) 'view': view!.toJson(),
  };
}

/// Wire model ImageAttachmentRef.
final class ImageAttachmentRef {
  const ImageAttachmentRef({required this.attachmentId, required this.mediaType, required this.bytes, required this.width, required this.height, this.name});
  final ApprovalRequestId attachmentId;
  final ImageMediaType mediaType;
  final int bytes;
  final int width;
  final int height;
  final RpcId? name;
  factory ImageAttachmentRef.fromJson(Map<String, dynamic> json) {
    return ImageAttachmentRef(
      attachmentId: (json['attachmentId'] as String),
      mediaType: json['mediaType'],
      bytes: (json['bytes'] as num).toInt(),
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      name: json.containsKey('name') ? (json['name'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'attachmentId': attachmentId,
      'mediaType': mediaType,
      'bytes': bytes,
      'width': width,
      'height': height,
      if (name != null) 'name': name!,
  };
}

/// Wire model ImageLimitsProjection.
final class ImageLimitsProjection {
  const ImageLimitsProjection({required this.maxImageBytes, required this.maxImagesPerMessage, required this.maxMessageImageBytes, required this.maxImagePixels, required this.mediaTypes});
  final int maxImageBytes;
  final int maxImagesPerMessage;
  final int maxMessageImageBytes;
  final int maxImagePixels;
  final List<RpcId> mediaTypes;
  factory ImageLimitsProjection.fromJson(Map<String, dynamic> json) {
    return ImageLimitsProjection(
      maxImageBytes: (json['maxImageBytes'] as num).toInt(),
      maxImagesPerMessage: (json['maxImagesPerMessage'] as num).toInt(),
      maxMessageImageBytes: (json['maxMessageImageBytes'] as num).toInt(),
      maxImagePixels: (json['maxImagePixels'] as num).toInt(),
      mediaTypes: [for (final e in (json['mediaTypes'] as List)) (e as String)],
    );
  }
  Map<String, dynamic> toJson() => {
      'maxImageBytes': maxImageBytes,
      'maxImagesPerMessage': maxImagesPerMessage,
      'maxMessageImageBytes': maxMessageImageBytes,
      'maxImagePixels': maxImagePixels,
      'mediaTypes': [for (final e in mediaTypes) e],
  };
}

/// Untagged union ImageMediaType (kept open as dynamic).
typedef ImageMediaType = dynamic;

/// Branded string " + cls + ".
typedef MessageId = String;

/// Wire model ModelCatalogFailure.
final class ModelCatalogFailure {
  const ModelCatalogFailure({required this.id, required this.name, required this.message});
  final ApprovalRequestId id;
  final ApprovalRequestId name;
  final RpcId message;
  factory ModelCatalogFailure.fromJson(Map<String, dynamic> json) {
    return ModelCatalogFailure(
      id: (json['id'] as String),
      name: (json['name'] as String),
      message: (json['message'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'name': name,
      'message': message,
  };
}

/// Wire model ModelCatalogModel.
final class ModelCatalogModel {
  const ModelCatalogModel({required this.id, required this.name, this.description, this.reasoning});
  final ApprovalRequestId id;
  final ApprovalRequestId name;
  final RpcId? description;
  final ModelReasoning? reasoning;
  factory ModelCatalogModel.fromJson(Map<String, dynamic> json) {
    return ModelCatalogModel(
      id: (json['id'] as String),
      name: (json['name'] as String),
      description: json.containsKey('description') ? (json['description'] as String) : null,
      reasoning: json.containsKey('reasoning') ? ModelReasoning.fromJson(json['reasoning'] as Map<String, dynamic>) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'name': name,
      if (description != null) 'description': description!,
      if (reasoning != null) 'reasoning': reasoning!.toJson(),
  };
}

/// Wire model ModelProviderGroup.
final class ModelProviderGroup {
  const ModelProviderGroup({required this.id, required this.name, required this.models});
  final ApprovalRequestId id;
  final ApprovalRequestId name;
  final List<ModelCatalogModel> models;
  factory ModelProviderGroup.fromJson(Map<String, dynamic> json) {
    return ModelProviderGroup(
      id: (json['id'] as String),
      name: (json['name'] as String),
      models: [for (final e in (json['models'] as List)) ModelCatalogModel.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'name': name,
      'models': [for (final e in models) e.toJson()],
  };
}

/// Wire model ModelReasoningEffort.
final class ModelReasoningEffort {
  const ModelReasoningEffort({required this.id, required this.name, this.description});
  final ApprovalRequestId id;
  final ApprovalRequestId name;
  final RpcId? description;
  factory ModelReasoningEffort.fromJson(Map<String, dynamic> json) {
    return ModelReasoningEffort(
      id: (json['id'] as String),
      name: (json['name'] as String),
      description: json.containsKey('description') ? (json['description'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'id': id,
      'name': name,
      if (description != null) 'description': description!,
  };
}

/// Wire model ModelReasoning.
final class ModelReasoning {
  const ModelReasoning({required this.efforts, this.defaultEffort});
  final List<ModelReasoningEffort> efforts;
  final ApprovalRequestId? defaultEffort;
  factory ModelReasoning.fromJson(Map<String, dynamic> json) {
    return ModelReasoning(
      efforts: [for (final e in (json['efforts'] as List)) ModelReasoningEffort.fromJson(e as Map<String, dynamic>)],
      defaultEffort: json.containsKey('defaultEffort') ? (json['defaultEffort'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'efforts': [for (final e in efforts) e.toJson()],
      if (defaultEffort != null) 'defaultEffort': defaultEffort!,
  };
}

/// Wire model ModelSelection.
final class ModelSelection {
  const ModelSelection({required this.provider, required this.model, this.reasoningEffort});
  final ApprovalRequestId provider;
  final ApprovalRequestId model;
  final ApprovalRequestId? reasoningEffort;
  factory ModelSelection.fromJson(Map<String, dynamic> json) {
    return ModelSelection(
      provider: (json['provider'] as String),
      model: (json['model'] as String),
      reasoningEffort: json.containsKey('reasoningEffort') ? (json['reasoningEffort'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'provider': provider,
      'model': model,
      if (reasoningEffort != null) 'reasoningEffort': reasoningEffort!,
  };
}

/// Sealed union PromptContentPart, discriminated by "type".
sealed class PromptContentPart {
  const PromptContentPart();
  Map<String, dynamic> toJson();
  factory PromptContentPart.fromJson(Map<String, dynamic> json) {
    final tag = json['type'] as String;
    switch (tag) {
      case 'text':
        return PromptContentPartText.fromJson(json);
      case 'image':
        return PromptContentPartImage.fromJson(json);
      default:
        throw FormatException('PromptContentPart: unknown type ' + tag);
    }
  }
}

/// "text" variant of PromptContentPart.
final class PromptContentPartText extends PromptContentPart {
  const PromptContentPartText({required this.text});
  final RpcId text;
  factory PromptContentPartText.fromJson(Map<String, dynamic> json) {
    return PromptContentPartText(
      text: (json['text'] as String),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
      'text': text,
  };
}

/// "image" variant of PromptContentPart.
final class PromptContentPartImage extends PromptContentPart {
  const PromptContentPartImage({required this.mediaType, required this.data, this.name});
  final ImageMediaType mediaType;
  final RpcId data;
  final RpcId? name;
  factory PromptContentPartImage.fromJson(Map<String, dynamic> json) {
    return PromptContentPartImage(
      mediaType: json['mediaType'],
      data: (json['data'] as String),
      name: json.containsKey('name') ? (json['name'] as String) : null,
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
      'mediaType': mediaType,
      'data': data,
      if (name != null) 'name': name!,
  };
}

/// Wire model SessionAttachmentRequest.
final class SessionAttachmentRequest {
  const SessionAttachmentRequest({required this.sessionId, required this.attachmentId});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId attachmentId;
  factory SessionAttachmentRequest.fromJson(Map<String, dynamic> json) {
    return SessionAttachmentRequest(
      sessionId: (json['sessionId'] as String),
      attachmentId: (json['attachmentId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'attachmentId': attachmentId,
  };
}

/// Wire model SessionAttachmentValue.
final class SessionAttachmentValue {
  const SessionAttachmentValue({required this.attachment, required this.data});
  final ImageAttachmentRef attachment;
  final RpcId data;
  factory SessionAttachmentValue.fromJson(Map<String, dynamic> json) {
    return SessionAttachmentValue(
      attachment: ImageAttachmentRef.fromJson(json['attachment'] as Map<String, dynamic>),
      data: (json['data'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'attachment': attachment.toJson(),
      'data': data,
  };
}

/// Wire model SessionCancelRequest.
final class SessionCancelRequest {
  const SessionCancelRequest({required this.sessionId});
  final ApprovalRequestId sessionId;
  factory SessionCancelRequest.fromJson(Map<String, dynamic> json) {
    return SessionCancelRequest(
      sessionId: (json['sessionId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
  };
}

/// Wire model SessionCancelValue.
final class SessionCancelValue {
  const SessionCancelValue({required this.accepted});
  final bool accepted;
  factory SessionCancelValue.fromJson(Map<String, dynamic> json) {
    return SessionCancelValue(
      accepted: (json['accepted'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'accepted': accepted,
  };
}

/// Wire model SessionCreateRequest.
final class SessionCreateRequest {
  const SessionCreateRequest({this.workspaceId, this.cwd, this.sessionId, this.agentPreset});
  final ApprovalRequestId? workspaceId;
  final RpcId? cwd;
  final ApprovalRequestId? sessionId;
  final RpcId? agentPreset;
  factory SessionCreateRequest.fromJson(Map<String, dynamic> json) {
    return SessionCreateRequest(
      workspaceId: json.containsKey('workspaceId') ? (json['workspaceId'] as String) : null,
      cwd: json.containsKey('cwd') ? (json['cwd'] as String) : null,
      sessionId: json.containsKey('sessionId') ? (json['sessionId'] as String) : null,
      agentPreset: json.containsKey('agentPreset') ? (json['agentPreset'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      if (workspaceId != null) 'workspaceId': workspaceId!,
      if (cwd != null) 'cwd': cwd!,
      if (sessionId != null) 'sessionId': sessionId!,
      if (agentPreset != null) 'agentPreset': agentPreset!,
  };
}

/// Wire model SessionCreateValue.
final class SessionCreateValue {
  const SessionCreateValue({required this.sessionId, this.agentPreset});
  final ApprovalRequestId sessionId;
  final RpcId? agentPreset;
  factory SessionCreateValue.fromJson(Map<String, dynamic> json) {
    return SessionCreateValue(
      sessionId: (json['sessionId'] as String),
      agentPreset: json.containsKey('agentPreset') ? (json['agentPreset'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      if (agentPreset != null) 'agentPreset': agentPreset!,
  };
}

/// Wire model SessionEvent.
final class SessionEvent {
  const SessionEvent({required this.type, required this.seq, required this.time, required this.data, this.sourceEventSeqs, this.surfaceOp, this.ignorable});
  final RpcId type;
  final int seq;
  final double time;
  final SessionLogQuery data;
  final List<double>? sourceEventSeqs;
  final SessionLogQuery? surfaceOp;
  final bool? ignorable;
  factory SessionEvent.fromJson(Map<String, dynamic> json) {
    return SessionEvent(
      type: (json['type'] as String),
      seq: (json['seq'] as num).toInt(),
      time: (json['time'] as num).toDouble(),
      data: json['data'],
      sourceEventSeqs: json.containsKey('sourceEventSeqs') ? [for (final e in (json['sourceEventSeqs'] as List)) (e as num).toDouble()] : null,
      surfaceOp: json.containsKey('surfaceOp') ? json['surfaceOp'] : null,
      ignorable: json.containsKey('ignorable') ? (json['ignorable'] as bool) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'type': type,
      'seq': seq,
      'time': time,
      'data': data,
      if (sourceEventSeqs != null) 'sourceEventSeqs': [for (final e in sourceEventSeqs!) e],
      if (surfaceOp != null) 'surfaceOp': surfaceOp!,
      if (ignorable != null) 'ignorable': ignorable!,
  };
}

/// Wire model SessionForkRequest.
final class SessionForkRequest {
  const SessionForkRequest({required this.sessionId, this.atSeq});
  final ApprovalRequestId sessionId;
  final int? atSeq;
  factory SessionForkRequest.fromJson(Map<String, dynamic> json) {
    return SessionForkRequest(
      sessionId: (json['sessionId'] as String),
      atSeq: json.containsKey('atSeq') ? (json['atSeq'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      if (atSeq != null) 'atSeq': atSeq!,
  };
}

/// Wire model SessionForkValue.
final class SessionForkValue {
  const SessionForkValue({required this.sessionId});
  final ApprovalRequestId sessionId;
  factory SessionForkValue.fromJson(Map<String, dynamic> json) {
    return SessionForkValue(
      sessionId: (json['sessionId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
  };
}

/// Wire model SessionHistoryRequest.
final class SessionHistoryRequest {
  const SessionHistoryRequest({required this.sessionId, this.beforeSeq, this.maxMessages});
  final ApprovalRequestId sessionId;
  final int? beforeSeq;
  final int? maxMessages;
  factory SessionHistoryRequest.fromJson(Map<String, dynamic> json) {
    return SessionHistoryRequest(
      sessionId: (json['sessionId'] as String),
      beforeSeq: json.containsKey('beforeSeq') ? (json['beforeSeq'] as num).toInt() : null,
      maxMessages: json.containsKey('maxMessages') ? (json['maxMessages'] as num).toInt() : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      if (beforeSeq != null) 'beforeSeq': beforeSeq!,
      if (maxMessages != null) 'maxMessages': maxMessages!,
  };
}

/// Wire model SessionHistoryValue.
final class SessionHistoryValue {
  const SessionHistoryValue({required this.events, required this.hasMore, this.projections});
  final List<HistoryEntry> events;
  final bool hasMore;
  final SessionProjectionsBlock? projections;
  factory SessionHistoryValue.fromJson(Map<String, dynamic> json) {
    return SessionHistoryValue(
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

/// Branded string " + cls + ".
typedef SessionId = String;

/// Wire model SessionListMetadataProjection.
final class SessionListMetadataProjection {
  const SessionListMetadataProjection({required this.blank, required this.lastPromptAt});
  final bool blank;
  final double? lastPromptAt;
  factory SessionListMetadataProjection.fromJson(Map<String, dynamic> json) {
    return SessionListMetadataProjection(
      blank: (json['blank'] as bool),
      lastPromptAt: (json['lastPromptAt'] == null ? null : (json['lastPromptAt'] as num).toDouble()),
    );
  }
  Map<String, dynamic> toJson() => {
      'blank': blank,
      'lastPromptAt': lastPromptAt,
  };
}

/// Wire model SessionListRequest.
final class SessionListRequest {
  const SessionListRequest({this.cursor});
  final RpcId? cursor;
  factory SessionListRequest.fromJson(Map<String, dynamic> json) {
    return SessionListRequest(
      cursor: json.containsKey('cursor') ? (json['cursor'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      if (cursor != null) 'cursor': cursor!,
  };
}

/// Wire model SessionListValue.
final class SessionListValue {
  const SessionListValue({required this.items});
  final List<SessionSummary> items;
  factory SessionListValue.fromJson(Map<String, dynamic> json) {
    return SessionListValue(
      items: [for (final e in (json['items'] as List)) SessionSummary.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'items': [for (final e in items) e.toJson()],
  };
}

/// Wire model SessionModelsRequest.
final class SessionModelsRequest {
  const SessionModelsRequest({required this.sessionId});
  final ApprovalRequestId sessionId;
  factory SessionModelsRequest.fromJson(Map<String, dynamic> json) {
    return SessionModelsRequest(
      sessionId: (json['sessionId'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
  };
}

/// Wire model SessionModelsValue.
final class SessionModelsValue {
  const SessionModelsValue({required this.current, required this.routable, required this.groups, required this.failures});
  final ModelSelection current;
  final bool routable;
  final List<ModelProviderGroup> groups;
  final List<ModelCatalogFailure> failures;
  factory SessionModelsValue.fromJson(Map<String, dynamic> json) {
    return SessionModelsValue(
      current: ModelSelection.fromJson(json['current'] as Map<String, dynamic>),
      routable: (json['routable'] as bool),
      groups: [for (final e in (json['groups'] as List)) ModelProviderGroup.fromJson(e as Map<String, dynamic>)],
      failures: [for (final e in (json['failures'] as List)) ModelCatalogFailure.fromJson(e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'current': current.toJson(),
      'routable': routable,
      'groups': [for (final e in groups) e.toJson()],
      'failures': [for (final e in failures) e.toJson()],
  };
}

/// Wire model SessionProjectionsBlock.
final class SessionProjectionsBlock {
  const SessionProjectionsBlock({required this.asOfSeq, required this.values});
  final int asOfSeq;
  final Map<String, dynamic> values;
  factory SessionProjectionsBlock.fromJson(Map<String, dynamic> json) {
    return SessionProjectionsBlock(
      asOfSeq: (json['asOfSeq'] as num).toInt(),
      values: (json['values'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'asOfSeq': asOfSeq,
      'values': values,
  };
}

/// Wire model SessionPromptRequest.
final class SessionPromptRequest {
  const SessionPromptRequest({required this.sessionId, required this.mode, required this.content, this.clientTimeZone});
  final ApprovalRequestId sessionId;
  final Object mode;
  final List<PromptContentPart> content;
  final RpcId? clientTimeZone;
  factory SessionPromptRequest.fromJson(Map<String, dynamic> json) {
    return SessionPromptRequest(
      sessionId: (json['sessionId'] as String),
      mode: json['mode'],
      content: [for (final e in (json['content'] as List)) PromptContentPart.fromJson(e as Map<String, dynamic>)],
      clientTimeZone: json.containsKey('clientTimeZone') ? (json['clientTimeZone'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'mode': mode,
      'content': [for (final e in content) e.toJson()],
      if (clientTimeZone != null) 'clientTimeZone': clientTimeZone!,
  };
}

/// Wire model SessionPromptValue.
final class SessionPromptValue {
  const SessionPromptValue({required this.accepted, this.command});
  final bool accepted;
  final Map<String, dynamic>? command;
  factory SessionPromptValue.fromJson(Map<String, dynamic> json) {
    return SessionPromptValue(
      accepted: (json['accepted'] as bool),
      command: json.containsKey('command') ? (json['command'] as Map<String, dynamic>) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'accepted': accepted,
      if (command != null) 'command': command!,
  };
}

/// Wire model SessionRenameRequest.
final class SessionRenameRequest {
  const SessionRenameRequest({required this.sessionId, required this.title});
  final ApprovalRequestId sessionId;
  final RpcId title;
  factory SessionRenameRequest.fromJson(Map<String, dynamic> json) {
    return SessionRenameRequest(
      sessionId: (json['sessionId'] as String),
      title: (json['title'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'title': title,
  };
}

/// Wire model SessionRenameValue.
final class SessionRenameValue {
  const SessionRenameValue({required this.title, required this.seq});
  final ApprovalRequestId title;
  final int seq;
  factory SessionRenameValue.fromJson(Map<String, dynamic> json) {
    return SessionRenameValue(
      title: (json['title'] as String),
      seq: (json['seq'] as num).toInt(),
    );
  }
  Map<String, dynamic> toJson() => {
      'title': title,
      'seq': seq,
  };
}

/// Wire model SessionSearchItem.
final class SessionSearchItem {
  const SessionSearchItem({required this.sessionId, required this.snippet});
  final ApprovalRequestId sessionId;
  final RpcId snippet;
  factory SessionSearchItem.fromJson(Map<String, dynamic> json) {
    return SessionSearchItem(
      sessionId: (json['sessionId'] as String),
      snippet: (json['snippet'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'snippet': snippet,
  };
}

/// Wire model SessionSearchRequest.
final class SessionSearchRequest {
  const SessionSearchRequest({required this.query});
  final String query;
  factory SessionSearchRequest.fromJson(Map<String, dynamic> json) {
    return SessionSearchRequest(
      query: (json['query'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
      'query': query,
  };
}

/// Wire model SessionSearchValue.
final class SessionSearchValue {
  const SessionSearchValue({required this.items, required this.hasMore});
  final List<SessionSearchItem> items;
  final bool hasMore;
  factory SessionSearchValue.fromJson(Map<String, dynamic> json) {
    return SessionSearchValue(
      items: [for (final e in (json['items'] as List)) SessionSearchItem.fromJson(e as Map<String, dynamic>)],
      hasMore: (json['hasMore'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'items': [for (final e in items) e.toJson()],
      'hasMore': hasMore,
  };
}

/// Wire model SessionSelectModelRequest.
final class SessionSelectModelRequest {
  const SessionSelectModelRequest({required this.sessionId, required this.provider, required this.model, this.reasoningEffort});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId provider;
  final ApprovalRequestId model;
  final ApprovalRequestId? reasoningEffort;
  factory SessionSelectModelRequest.fromJson(Map<String, dynamic> json) {
    return SessionSelectModelRequest(
      sessionId: (json['sessionId'] as String),
      provider: (json['provider'] as String),
      model: (json['model'] as String),
      reasoningEffort: json.containsKey('reasoningEffort') ? (json['reasoningEffort'] as String) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      if (reasoningEffort != null) 'reasoningEffort': reasoningEffort!,
  };
}

/// Wire model SessionSelectModelValue.
final class SessionSelectModelValue {
  const SessionSelectModelValue({required this.selected});
  final ModelSelection selected;
  factory SessionSelectModelValue.fromJson(Map<String, dynamic> json) {
    return SessionSelectModelValue(
      selected: ModelSelection.fromJson(json['selected'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'selected': selected.toJson(),
  };
}

/// Wire model SessionSummary.
final class SessionSummary {
  const SessionSummary({required this.sessionId, required this.updatedAt, required this.running, required this.blank, this.parentSessionId, this.origin, this.cwd, this.agentPreset, this.projections});
  final ApprovalRequestId sessionId;
  final double updatedAt;
  final bool running;
  final bool blank;
  final ApprovalRequestId? parentSessionId;
  final String? origin;
  final RpcId? cwd;
  final RpcId? agentPreset;
  final SessionProjectionsBlock? projections;
  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    return SessionSummary(
      sessionId: (json['sessionId'] as String),
      updatedAt: (json['updatedAt'] as num).toDouble(),
      running: (json['running'] as bool),
      blank: (json['blank'] as bool),
      parentSessionId: json.containsKey('parentSessionId') ? (json['parentSessionId'] as String) : null,
      origin: json.containsKey('origin') ? (json['origin'] as String) : null,
      cwd: json.containsKey('cwd') ? (json['cwd'] as String) : null,
      agentPreset: json.containsKey('agentPreset') ? (json['agentPreset'] as String) : null,
      projections: json.containsKey('projections') ? SessionProjectionsBlock.fromJson(json['projections'] as Map<String, dynamic>) : null,
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'updatedAt': updatedAt,
      'running': running,
      'blank': blank,
      if (parentSessionId != null) 'parentSessionId': parentSessionId!,
      if (origin != null) 'origin': origin!,
      if (cwd != null) 'cwd': cwd!,
      if (agentPreset != null) 'agentPreset': agentPreset!,
      if (projections != null) 'projections': projections!.toJson(),
  };
}

/// Wire model SessionUpdateQueueRequest.
final class SessionUpdateQueueRequest {
  const SessionUpdateQueueRequest({required this.sessionId, required this.itemId, required this.action});
  final ApprovalRequestId sessionId;
  final ApprovalRequestId itemId;
  final Object action;
  factory SessionUpdateQueueRequest.fromJson(Map<String, dynamic> json) {
    return SessionUpdateQueueRequest(
      sessionId: (json['sessionId'] as String),
      itemId: (json['itemId'] as String),
      action: json['action'],
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'itemId': itemId,
      'action': action,
  };
}

/// Wire model SessionUpdateQueueValue.
final class SessionUpdateQueueValue {
  const SessionUpdateQueueValue({required this.accepted});
  final bool accepted;
  factory SessionUpdateQueueValue.fromJson(Map<String, dynamic> json) {
    return SessionUpdateQueueValue(
      accepted: (json['accepted'] as bool),
    );
  }
  Map<String, dynamic> toJson() => {
      'accepted': accepted,
  };
}

/// Sealed union ToolEventView, discriminated by "for".
sealed class ToolEventView {
  const ToolEventView();
  Map<String, dynamic> toJson();
  factory ToolEventView.fromJson(Map<String, dynamic> json) {
    final tag = json['for'] as String;
    switch (tag) {
      case 'call':
        return ToolEventViewCall.fromJson(json);
      case 'result':
        return ToolEventViewResult.fromJson(json);
      default:
        throw FormatException('ToolEventView: unknown for ' + tag);
    }
  }
}

/// "call" variant of ToolEventView.
final class ToolEventViewCall extends ToolEventView {
  const ToolEventViewCall({required this.view});
  final Map<String, dynamic> view;
  factory ToolEventViewCall.fromJson(Map<String, dynamic> json) {
    return ToolEventViewCall(
      view: (json['view'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'for': 'call',
      'view': view,
  };
}

/// "result" variant of ToolEventView.
final class ToolEventViewResult extends ToolEventView {
  const ToolEventViewResult({required this.view});
  final Map<String, dynamic> view;
  factory ToolEventViewResult.fromJson(Map<String, dynamic> json) {
    return ToolEventViewResult(
      view: (json['view'] as Map<String, dynamic>),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'for': 'result',
      'view': view,
  };
}

/// Branded string " + cls + ".
typedef WorkspaceId = String;

