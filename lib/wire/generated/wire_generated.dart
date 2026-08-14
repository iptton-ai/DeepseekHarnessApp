// GENERATED CODE - DO NOT MODIFY BY HAND
// Wire contract library (dsh 0.1.0-rc.6) via export-schemas.mjs + generate_dart.dart.

part 'agent_presets.dart';
part 'approvals.dart';
part 'credentials.dart';
part 'downloads.dart';
part 'events.dart';
part 'goals.dart';
part 'host.dart';
part 'jobs.dart';
part 'llm.dart';
part 'questions.dart';
part 'rpc.dart';
part 'sessions.dart';
part 'settings.dart';
part 'skills.dart';
part 'subagents.dart';
part 'workspace.dart';

/// All client-request method names, frozen from RpcMethodMap (dsh 0.1.0-rc.6).
abstract final class RpcMethods {
  RpcMethods._();
  static const String sessionList = 'session.list';
  static const String sessionSearch = 'session.search';
  static const String sessionCreate = 'session.create';
  static const String sessionHistory = 'session.history';
  static const String sessionModels = 'session.models';
  static const String sessionSelectModel = 'session.selectModel';
  static const String sessionRename = 'session.rename';
  static const String sessionFork = 'session.fork';
  static const String sessionPrompt = 'session.prompt';
  static const String sessionAttachment = 'session.attachment';
  static const String sessionUpdateQueue = 'session.updateQueue';
  static const String sessionCancel = 'session.cancel';
  static const String subagentList = 'subagent.list';
  static const String subagentHistory = 'subagent.history';
  static const String subagentPrompt = 'subagent.prompt';
  static const String subagentInterrupt = 'subagent.interrupt';
  static const String hostDescribe = 'host.describe';
  static const String hostPickDirectory = 'host.pickDirectory';
  static const String hostListDirectory = 'host.listDirectory';
  static const String hostCreateDirectory = 'host.createDirectory';
  static const String hostOpenPath = 'host.openPath';
  static const String workspaceList = 'workspace.list';
  static const String workspaceCreate = 'workspace.create';
  static const String workspaceRename = 'workspace.rename';
  static const String workspaceDelete = 'workspace.delete';
  static const String workspaceInsertBefore = 'workspace.insertBefore';
  static const String workspaceInsertSessionBefore = 'workspace.insertSessionBefore';
  static const String workspaceArchiveSession = 'workspace.archiveSession';
  static const String skillList = 'skill.list';
  static const String agentPresetList = 'agentPreset.list';
  static const String agentPresetSelect = 'agentPreset.select';
  static const String agentPresetRead = 'agentPreset.read';
  static const String agentPresetCopy = 'agentPreset.copy';
  static const String agentPresetOpenDocument = 'agentPreset.openDocument';
  static const String agentPresetRemove = 'agentPreset.remove';
  static const String goalCreate = 'goal.create';
  static const String goalEdit = 'goal.edit';
  static const String goalPause = 'goal.pause';
  static const String goalResume = 'goal.resume';
  static const String goalComplete = 'goal.complete';
  static const String goalClear = 'goal.clear';
  static const String settingsDescribe = 'settings.describe';
  static const String settingsOpenDocument = 'settings.openDocument';
  static const String settingsUpdate = 'settings.update';
  static const String settingsReplace = 'settings.replace';
  static const String settingsMutate = 'settings.mutate';
  static const String credentialsDescribe = 'credentials.describe';
  static const String credentialsSet = 'credentials.set';
  static const String credentialsUnset = 'credentials.unset';
  static const String llmProviders = 'llm.providers';
  static const String llmModels = 'llm.models';
  static const String llmDiscoverModels = 'llm.discoverModels';
}

/// Every method name in registry order.
const kAllRpcMethods = <String>[
  RpcMethods.sessionList,
  RpcMethods.sessionSearch,
  RpcMethods.sessionCreate,
  RpcMethods.sessionHistory,
  RpcMethods.sessionModels,
  RpcMethods.sessionSelectModel,
  RpcMethods.sessionRename,
  RpcMethods.sessionFork,
  RpcMethods.sessionPrompt,
  RpcMethods.sessionAttachment,
  RpcMethods.sessionUpdateQueue,
  RpcMethods.sessionCancel,
  RpcMethods.subagentList,
  RpcMethods.subagentHistory,
  RpcMethods.subagentPrompt,
  RpcMethods.subagentInterrupt,
  RpcMethods.hostDescribe,
  RpcMethods.hostPickDirectory,
  RpcMethods.hostListDirectory,
  RpcMethods.hostCreateDirectory,
  RpcMethods.hostOpenPath,
  RpcMethods.workspaceList,
  RpcMethods.workspaceCreate,
  RpcMethods.workspaceRename,
  RpcMethods.workspaceDelete,
  RpcMethods.workspaceInsertBefore,
  RpcMethods.workspaceInsertSessionBefore,
  RpcMethods.workspaceArchiveSession,
  RpcMethods.skillList,
  RpcMethods.agentPresetList,
  RpcMethods.agentPresetSelect,
  RpcMethods.agentPresetRead,
  RpcMethods.agentPresetCopy,
  RpcMethods.agentPresetOpenDocument,
  RpcMethods.agentPresetRemove,
  RpcMethods.goalCreate,
  RpcMethods.goalEdit,
  RpcMethods.goalPause,
  RpcMethods.goalResume,
  RpcMethods.goalComplete,
  RpcMethods.goalClear,
  RpcMethods.settingsDescribe,
  RpcMethods.settingsOpenDocument,
  RpcMethods.settingsUpdate,
  RpcMethods.settingsReplace,
  RpcMethods.settingsMutate,
  RpcMethods.credentialsDescribe,
  RpcMethods.credentialsSet,
  RpcMethods.credentialsUnset,
  RpcMethods.llmProviders,
  RpcMethods.llmModels,
  RpcMethods.llmDiscoverModels,
];
