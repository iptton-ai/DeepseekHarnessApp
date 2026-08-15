// ThemeStore — W3-C 主题系统(纯 Dart 域层)。
//
// 契约(DSH-PROTOCOL §9 + docs/audit/sidebar-layout.md §8):
// - 主题持久化 = settings 命名空间 "ui-theme" 的 preference 键
//   (light/dark/system,默认 system);theme/* 远程端点不可达(实测 not found),
//   客户端主题同步唯一通道是 settings.mutate(经薄通道)
// - 读:settings.describe 的 ui-theme namespace value.preference → ThemePreference;
//   写:settings.mutate('ui-theme', [set preference], expectedRevision CAS)
// - settings-conflict → 底层(SettingsStore.mutate)已自动重读权威值,
//   这里折叠为 typed ThemeSettingsConflictError,并再同步一次快照后上抛
// - 失效:host/remote-event settings/document-updated → 重读(经通道 invalidations)
// - 本机回退:任何读失败/缺值/非法值 → 默认 system,绝不阻塞 UI
// - 写失败(含冲突):乐观值回滚为权威值(web 同款「写被拒则重载持久化值」)
//
// 构造注入薄通道 ThemeSettingsChannel —— 本文件不 import SettingsStore;
// 集成方用 SettingsStore.scope('ui-theme') 适配:
//   snapshot → scope.snapshot;load → scope.load();
//   setPreference → scope.setField(['preference'], v)(CAS 由 SettingsStore 内置,
//     冲突是 SettingsConflictError,适配方折叠为 ThemeSettingsConflictError);
//   invalidations → connection.hostFrames 过滤 settings/document-updated 转发。
// 域枚举 ThemePreference 与 Flutter ThemeMode 的 1:1 映射在 UI 边界
// (lib/ui/theme_mode_row.dart 的 themeModeOf)。
import 'dart:async';

import 'package:singleman/wire/generated/wire_generated.dart';

/// 主题偏好三态(与 ui-theme.preference 的 const 枚举一一对应)。
enum ThemePreference {
  system,
  light,
  dark;

  /// 落 settings 的 preference 值('light'/'dark'/'system')。
  String get wireValue => switch (this) {
    ThemePreference.system => 'system',
    ThemePreference.light => 'light',
    ThemePreference.dark => 'dark',
  };

  /// 从 settings preference 字符串解析;未知值返回 null(调用方回退 system)。
  static ThemePreference? tryParse(String? value) => switch (value) {
    'system' => ThemePreference.system,
    'light' => ThemePreference.light,
    'dark' => ThemePreference.dark,
    _ => null,
  };
}

/// CAS 冲突:mutate 被 settings-conflict 拒绝后底层已自动重读,UI 提示重试。
class ThemeSettingsConflictError implements Exception {
  const ThemeSettingsConflictError(
    this.namespace, {
    this.expectedRevision,
    this.latestRevision,
  });

  final String namespace;
  final double? expectedRevision;
  final double? latestRevision;

  @override
  String toString() =>
      'ThemeSettingsConflictError($namespace: expected $expectedRevision, latest $latestRevision)';
}

/// ThemeStore 依赖的薄 settings 通道(纯 Dart;集成方用 SettingsStore.scope 适配)。
///
/// 语义对齐 web 的 ctx.settingsScope('ui-theme'):快照 + 单字段 CAS 写入 +
/// 显式重读。invalidations 只承载**外部**失效信号(host/remote-event
/// settings/document-updated 等),避免与自身写后重读形成环路。
abstract class ThemeSettingsChannel {
  /// ui-theme 命名空间当前快照(未加载/读失败 → null)。
  SettingsMutateValue? get snapshot;

  /// 显式重读 describe(构造后/失效事件后调用;失败向上抛,由调用方回退)。
  Future<void> load();

  /// CAS 写 preference(expectedRevision 取当前快照,由适配方拼装)。
  ///
  /// settings-conflict → 适配方已重读权威值并抛 [ThemeSettingsConflictError];
  /// 传输失败 → 抛原异常。成功时快照已更新为新 revision。
  Future<void> setPreference(String wireValue);

  /// 外部失效信号流(settings/document-updated 等)。
  Stream<void> get invalidations;
}

/// UI 依赖的窄接口(便于 widget 测试注入假实现)。
abstract class ThemeStoreView {
  /// 主题偏好流(初始读/写成功/失效重读后都发一帧)。
  Stream<ThemePreference> get preferences;

  /// 当前偏好(初始默认 system,读失败回退 system,不阻塞 UI)。
  ThemePreference get current;

  /// 切换主题:乐观即时生效 → CAS 写;冲突/传输失败 → 重读权威值后
  /// 抛 [ThemeSettingsConflictError] 或原异常(UI 决定提示)。
  Future<void> setMode(ThemePreference mode);
}

class ThemeStore implements ThemeStoreView {
  ThemeStore({required ThemeSettingsChannel channel}) : _channel = channel {
    _controller = StreamController<ThemePreference>.broadcast();
    _invalidationsSub = channel.invalidations.listen((_) => _onInvalidated());
    _readInitial();
  }

  final ThemeSettingsChannel _channel;
  late final StreamController<ThemePreference> _controller;
  StreamSubscription<void>? _invalidationsSub;
  bool _disposed = false;
  ThemePreference _current = ThemePreference.system;

  @override
  Stream<ThemePreference> get preferences => _controller.stream;

  @override
  ThemePreference get current => _current;

  /// 初始读:通道已有快照(如 SettingsStore 已加载)→ 直接应用,不发额外读;
  /// 否则显式重读。任何失败 → 默认 system(本机回退,不阻塞 UI)。
  Future<void> _readInitial() async {
    final snap = _channel.snapshot;
    if (snap != null) {
      _apply(snap);
      return;
    }
    try {
      await _channel.load();
      if (_disposed) return;
      _apply(_channel.snapshot);
    } catch (_) {
      _set(ThemePreference.system);
    }
  }

  @override
  Future<void> setMode(ThemePreference mode) async {
    if (_disposed) throw StateError('ThemeStore disposed');
    if (mode == _current) return;
    // 乐观生效:UI 立即切换;写失败回滚为权威值(web 同款恢复语义)。
    _set(mode);
    try {
      await _channel.setPreference(mode.wireValue);
    } on ThemeSettingsConflictError {
      // 底层已重读;这里同步一次权威值(不吞掉 typed 错误,UI 提示重试)。
      _apply(_channel.snapshot);
      rethrow;
    } catch (_) {
      // 传输类失败:重读恢复权威值。
      await _reloadQuietly();
      rethrow;
    }
  }

  /// 失效(settings/document-updated)→ 重读;失败保持现值。
  Future<void> _onInvalidated() async {
    await _reloadQuietly();
  }

  Future<void> _reloadQuietly() async {
    try {
      await _channel.load();
      if (_disposed) return;
      _apply(_channel.snapshot);
    } catch (_) {
      // 重读失败 → 保持现值(不打扰 UI)。
    }
  }

  /// 从 namespace 快照解析 preference;缺值/非法值 → system(本机回退)。
  void _apply(SettingsMutateValue? snap) {
    final value = snap?.value;
    if (value is Map<String, dynamic>) {
      final pref = value['preference'];
      if (pref is String) {
        final parsed = ThemePreference.tryParse(pref);
        if (parsed != null) {
          _set(parsed);
          return;
        }
      }
    }
    _set(ThemePreference.system);
  }

  void _set(ThemePreference value) {
    if (value == _current) return;
    _current = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _invalidationsSub?.cancel();
    await _controller.close();
  }
}
