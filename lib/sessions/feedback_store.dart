// FeedbackStore — W3-B 消息反馈(messageFeedback 远程端点复刻)。
//
// 契约(DSH-PROTOCOL §9 + docs/audit/settings-system.md §4):
// - messageFeedback/list {request:{sessionId}} → 双层信封:
//   外层 server-response.result.ok 之后,内层再一层 {ok, value/error}(typert 包装),
//   解析剥两层;内层 value = {items:[{messageId, rating, note?, version,
//   createdAt, updatedAt}]}
// - messageFeedback/put {request:{sessionId, messageId, rating, note?, ifVersion}}:
//   CAS;ifVersion=null 表示要求当前不存在(创建);CAS token 来自上次 list/put
// - messageFeedback/delete {request:{sessionId, messageId, ifVersion}}:幂等,
//   内层 value = {absent:true}(条目已缺席时 ifVersion 被忽略)
// - 错误码(封闭):version-conflict(自动重读后抛 typed 异常携带权威条目)、
//   note-too-large(maxNoteBytes=8192,同 [kFeedbackNoteMaxBytes])、session-not-found
// - rating 枚举冻结事实:'positive' | 'negative'
// - 无实时推送:重连 resync 语义 = 代际翻转清缓存 + 注入 [onInvalidated] 回调,
//   消费端(UI)自行重拉(web 同款 connection/reset → resync)
// - 窄接口 FeedbackStoreView + 变更广播:单次 list 填充整段对话(缓存 per-session),
//   UI 自持 per-message 状态,订阅 changed 后重读 itemsFor
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 远程端点方法名(斜杠命名,不在生成 RpcMethods 里)。
abstract final class FeedbackMethods {
  FeedbackMethods._();
  static const String list = 'messageFeedback/list';
  static const String put = 'messageFeedback/put';
  static const String delete = 'messageFeedback/delete';
}

/// 备注长度上限(服务端策略 maxNoteBytes=8192;UI 本地预拒同值)。
const int kFeedbackNoteMaxBytes = 8192;

/// 评分枚举(冻结事实:仅 positive|negative)。
enum FeedbackRating {
  positive('positive'),
  negative('negative');

  const FeedbackRating(this.wire);

  /// wire 字面量('positive'/'negative'),put 原样发送。
  final String wire;

  /// 解析 wire 字面量;未知枚举抛 [FormatException](封闭集合,防静默)。
  static FeedbackRating parse(String value) {
    for (final r in FeedbackRating.values) {
      if (r.wire == value) return r;
    }
    throw FormatException('未知评分枚举: ' + value);
  }
}

/// 一条反馈条目(list items 元素;put 成功也返回同形)。
class FeedbackItem {
  const FeedbackItem({
    required this.messageId,
    required this.rating,
    this.note,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  factory FeedbackItem.fromJson(Map<String, dynamic> json) {
    final rawRating = json['rating'];
    if (rawRating is! String) {
      throw const FormatException('反馈条目缺少 rating');
    }
    return FeedbackItem(
      messageId: json['messageId'] is String ? json['messageId'] as String : '',
      rating: FeedbackRating.parse(rawRating),
      note: json['note'] is String ? json['note'] as String : null,
      // version 是不透明 CAS token(数字或字符串),原样保留回传 ifVersion。
      version: json['version'],
      createdAt: json['createdAt']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
    );
  }

  final String messageId;
  final FeedbackRating rating;

  /// 可选备注(空/缺席 = 无备注)。
  final String? note;

  /// 不透明 CAS token;每次 create/update 轮换,原样回传。
  final Object? version;
  final String createdAt;
  final String updatedAt;
}

/// 域异常基类:code = 服务端/本地错误码(UI 文案按 code 区分)。
class FeedbackStoreException implements Exception {
  const FeedbackStoreException(this.code, this.message);
  final String code;
  final String? message;
  @override
  String toString() => 'FeedbackStoreException(' +
      code +
      (message == null ? '' : ', ' + message!) +
      ')';
}

/// CAS 冲突:put 被 version-conflict 拒绝后已自动 list 重读,
/// [authoritative] 为重读后的权威条目(并发删除后可能为 null → 视为未评)。
class FeedbackVersionConflictException extends FeedbackStoreException {
  const FeedbackVersionConflictException(this.authoritative)
      : super('version-conflict', '评分已过期,请重试');
  final FeedbackItem? authoritative;
}

/// 备注超长(服务端 note-too-large;UI 本地预拒同值文案)。
class FeedbackNoteTooLargeException extends FeedbackStoreException {
  const FeedbackNoteTooLargeException()
      : super('note-too-large', '备注过长(上限 $kFeedbackNoteMaxBytes 字符)');
}

/// UI 依赖的窄视图(widget 测试注入假实现,不碰 socket/HTTP)。
abstract class FeedbackStoreView {
  /// 某会话的条目快照(同步读;未加载/代际失效后为空列表)。
  List<FeedbackItem> itemsFor(String sessionId);

  /// 变更广播(list/put/delete/代际失效都会推;UI 订阅后重读 itemsFor)。
  Stream<void> get changed;

  /// 拉取某会话全部条目(单次 list 填充整段对话);成功 → 缓存 + 广播。
  /// 失败抛 [FeedbackStoreException](含 timeout/transport 折叠)。
  Future<List<FeedbackItem>> list(String sessionId, {bool force = false});

  /// CAS put;成功返回更新后的条目(新 version,缓存 + 广播)。
  /// version-conflict → 自动 list 重读后抛 [FeedbackVersionConflictException]
  /// (携带权威条目,UI 直接对账)。
  Future<FeedbackItem> put(
    String sessionId,
    String messageId,
    FeedbackRating rating, {
    String? note,
    Object? ifVersion,
  });

  /// 幂等 delete;返回 true = 条目已缺席(absent:true,无操作),
  /// false = 本次删除了既有条目。成功都会清除本地缓存并广播。
  Future<bool> delete(String sessionId, String messageId, {Object? ifVersion});
}

class FeedbackStore implements FeedbackStoreView {
  FeedbackStore({
    required this.api,
    required this.connection,
    this.onInvalidated,
  }) {
    _changed = StreamController<void>.broadcast();
    _snapshotsSub = connection.snapshots.listen(_onSnapshot);
    final cur = connection.current;
    if (cur != null && cur.phase == ConnectionPhase.ready) {
      _lastReadyGeneration = cur.generation;
    }
  }

  final ApiClient api;
  final ConnectionController connection;

  /// 代际翻转(重连)时注入的失效回调:消费端(UI)据此重拉 resync。
  final void Function()? onInvalidated;

  late final StreamController<void> _changed;
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  int _lastReadyGeneration = 0;
  bool _disposed = false;
  final Map<String, List<FeedbackItem>> _cache = <String, List<FeedbackItem>>{};

  /// 测试钩子:list/put/delete 实际 HTTP 调用次数(缓存命中不计数)。
  int listCalls = 0;
  int putCalls = 0;
  int deleteCalls = 0;

  @override
  List<FeedbackItem> itemsFor(String sessionId) =>
      List<FeedbackItem>.unmodifiable(
          _cache[sessionId] ?? const <FeedbackItem>[]);

  @override
  Stream<void> get changed => _changed.stream;

  @override
  Future<List<FeedbackItem>> list(String sessionId, {bool force = false}) async {
    if (!force && _cache.containsKey(sessionId)) return itemsFor(sessionId);
    listCalls += 1;
    try {
      final items = await api.call<List<FeedbackItem>>(
        FeedbackMethods.list,
        <String, dynamic>{
          'args': <String, dynamic>{
            'request': <String, dynamic>{'sessionId': sessionId},
          },
        },
        parse: _parseList,
      );
      _cache[sessionId] = items;
      _emit();
      return items;
    } on _InnerError catch (e) {
      throw FeedbackStoreException(e.code, e.message);
    } on RpcBusinessError catch (e) {
      throw FeedbackStoreException(_rpcErrorCode(e.error), null);
    } on ApiTimeout {
      throw const FeedbackStoreException('timeout', '反馈读取超时');
    } on CarrierError catch (e) {
      throw FeedbackStoreException('transport', e.toString());
    }
  }

  @override
  Future<FeedbackItem> put(
    String sessionId,
    String messageId,
    FeedbackRating rating, {
    String? note,
    Object? ifVersion,
  }) async {
    putCalls += 1;
    try {
      final item = await api.call<FeedbackItem>(
        FeedbackMethods.put,
        <String, dynamic>{
          'args': <String, dynamic>{
            'request': <String, dynamic>{
              'sessionId': sessionId,
              'messageId': messageId,
              'rating': rating.wire,
              if (note != null) 'note': note,
              if (ifVersion != null) 'ifVersion': ifVersion,
            },
          },
        },
        parse: _parsePut,
      );
      _upsert(sessionId, item);
      _emit();
      return item;
    } on _InnerError catch (e) {
      if (e.code == 'version-conflict') {
        // 冲突恢复语义:自动 list 重读(权威条目 + 广播),再抛 typed 异常
        // 携带权威条目,UI 直接对账。
        await _resync(sessionId);
        throw FeedbackVersionConflictException(_find(sessionId, messageId));
      }
      if (e.code == 'note-too-large') {
        throw const FeedbackNoteTooLargeException();
      }
      throw FeedbackStoreException(e.code, e.message);
    } on RpcBusinessError catch (e) {
      throw FeedbackStoreException(_rpcErrorCode(e.error), null);
    } on ApiTimeout {
      throw const FeedbackStoreException('timeout', '评分请求超时');
    } on CarrierError catch (e) {
      throw FeedbackStoreException('transport', e.toString());
    }
  }

  @override
  Future<bool> delete(String sessionId, String messageId,
      {Object? ifVersion}) async {
    deleteCalls += 1;
    try {
      final absent = await api.call<bool>(
        FeedbackMethods.delete,
        <String, dynamic>{
          'args': <String, dynamic>{
            'request': <String, dynamic>{
              'sessionId': sessionId,
              'messageId': messageId,
              if (ifVersion != null) 'ifVersion': ifVersion,
            },
          },
        },
        parse: _parseDelete,
      );
      _remove(sessionId, messageId);
      _emit();
      return absent;
    } on _InnerError catch (e) {
      throw FeedbackStoreException(e.code, e.message);
    } on RpcBusinessError catch (e) {
      throw FeedbackStoreException(_rpcErrorCode(e.error), null);
    } on ApiTimeout {
      throw const FeedbackStoreException('timeout', '评分撤回超时');
    } on CarrierError catch (e) {
      throw FeedbackStoreException('transport', e.toString());
    }
  }

  /// 内层信封解析(剥两层后收到 typert 的 {ok, value/error})。
  static void _checkInner(Map<String, dynamic> inner) {
    if (inner['ok'] == false) {
      final err = inner['error'];
      throw _InnerError(
        err is Map<String, dynamic>
            ? (err['code'] as String? ?? 'unknown')
            : 'unknown',
        err is Map<String, dynamic> ? err['message'] as String? : null,
      );
    }
  }

  /// list 解析:内层 value = {items:[...]}(空目录形态 {items:[]})。
  static List<FeedbackItem> _parseList(Map<String, dynamic> inner) {
    _checkInner(inner);
    final value = inner['value'];
    if (value is! Map<String, dynamic>) {
      throw const FormatException('messageFeedback/list: value 不是对象');
    }
    final items = value['items'];
    if (items is! List) {
      throw const FormatException('messageFeedback/list: items 不是数组');
    }
    return <FeedbackItem>[
      for (final e in items)
        if (e is Map<String, dynamic>) FeedbackItem.fromJson(e)
    ];
  }

  /// put 解析:内层 value = 更新后的条目(新 version 作下次 CAS token)。
  static FeedbackItem _parsePut(Map<String, dynamic> inner) {
    _checkInner(inner);
    final value = inner['value'];
    if (value is Map<String, dynamic> && value['messageId'] is String) {
      return FeedbackItem.fromJson(value);
    }
    throw const FormatException('messageFeedback/put: 响应缺少条目');
  }

  /// delete 解析:内层 value = {absent:bool};缺 absent 视为删除成功(false)。
  static bool _parseDelete(Map<String, dynamic> inner) {
    _checkInner(inner);
    final value = inner['value'];
    if (value is Map<String, dynamic> && value['absent'] is bool) {
      return value['absent'] as bool;
    }
    return false;
  }

  /// RpcError 变体没有统一 code 字段,防御读 toJson()['code']。
  static String _rpcErrorCode(RpcError e) {
    final code = e.toJson()['code'];
    return code is String ? code : 'rpc-error';
  }

  Future<void> _resync(String sessionId) async {
    try {
      await list(sessionId, force: true);
    } catch (_) {
      // 重读失败:缓存保持原状;权威条目以当前缓存为准。
    }
  }

  void _upsert(String sessionId, FeedbackItem item) {
    final items =
        List<FeedbackItem>.of(_cache[sessionId] ?? const <FeedbackItem>[]);
    final i = items.indexWhere((e) => e.messageId == item.messageId);
    if (i >= 0) {
      items[i] = item;
    } else {
      items.add(item);
    }
    _cache[sessionId] = items;
  }

  void _remove(String sessionId, String messageId) {
    final items = _cache[sessionId];
    if (items == null) return;
    _cache[sessionId] = <FeedbackItem>[
      for (final e in items)
        if (e.messageId != messageId) e
    ];
  }

  FeedbackItem? _find(String sessionId, String messageId) {
    for (final e in _cache[sessionId] ?? const <FeedbackItem>[]) {
      if (e.messageId == messageId) return e;
    }
    return null;
  }

  void _emit() {
    if (!_changed.isClosed) _changed.add(null);
  }

  void _onSnapshot(ConnectionSnapshot snap) {
    if (_disposed) return;
    if (snap.phase == ConnectionPhase.ready &&
        snap.generation > _lastReadyGeneration) {
      _lastReadyGeneration = snap.generation;
      // 重连=新代际:反馈无实时帧,缓存作废,消费端自行重拉(web 同款 resync)。
      _cache.clear();
      _emit();
      onInvalidated?.call();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _changed.close();
  }
}

/// typert 内层信封的业务错误(code + message 裸 JSON)。
class _InnerError implements Exception {
  const _InnerError(this.code, this.message);
  final String code;
  final String? message;
}
