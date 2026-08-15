// AttachmentFetcher — W2-C 图片附件下行域:按 (sessionId, attachmentId) 拉取
// 会话授权图片,LRU 内存缓存 + 进行中 single-flight 去重(纯 Dart,不 import flutter)。
//
// 契约(DSH-PROTOCOL §5 + sessions.schema):
// - session.attachment {sessionId, attachmentId} → SessionAttachmentValue
//   {attachment: ImageAttachmentRef, data: base64 字符串}
// - base64 解码在本域完成,字节以 Uint8List 交付 UI(不碰 wire 的 data 字符串)
// - 缓存上限:8MiB 或 24 张,先到先清(LRU:命中刷新访问序)
// - single-flight:同 (sessionId, attachmentId) 并发 fetch 只发一次 RPC,共享同一 Future
// - 失败不缓存(下次 fetch 重新请求);异常原样传播(RpcBusinessError / CarrierError /
//   FormatException),UI 只看到 Future 失败并据此给出重试
import 'dart:convert';
import 'dart:typed_data';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 已拉取附件:wire 引用 + 解码字节。
class FetchedAttachment {
  const FetchedAttachment({required this.ref, required this.bytes});
  final ImageAttachmentRef ref;
  final Uint8List bytes;
}

/// UI 依赖的窄视图(便于 widget 测试注入假实现,不碰 socket)。
abstract class AttachmentFetchView {
  /// 拉取并解码一张附件图片。
  ///
  /// 失败时抛原样异常,不缓存失败结果。
  Future<FetchedAttachment> fetch(String sessionId, String attachmentId);
}

/// 默认缓存字节上限:8MiB。
const int kAttachmentCacheMaxBytes = 8 << 20;

/// 默认缓存张数上限:24。
const int kAttachmentCacheMaxEntries = 24;

class AttachmentFetcher implements AttachmentFetchView {
  AttachmentFetcher({
    required this.api,
    this.maxCacheBytes = kAttachmentCacheMaxBytes,
    this.maxCacheEntries = kAttachmentCacheMaxEntries,
  });

  final ApiClient api;

  /// 字节上限(先到先清:写入时逐出最旧,直到两个上限都满足)。
  final int maxCacheBytes;

  /// 张数上限。
  final int maxCacheEntries;

  /// LRU 缓存:插入序 = 访问序(命中/写入时先 remove 再 add 移到队尾)。
  final Map<(String, String), FetchedAttachment> _cache =
      <(String, String), FetchedAttachment>{};
  int _cacheBytes = 0;

  /// 进行中请求(single-flight)。
  final Map<(String, String), Future<FetchedAttachment>> _inflight =
      <(String, String), Future<FetchedAttachment>>{};

  /// 当前缓存条目数(测试可观测)。
  int get cacheEntries => _cache.length;

  /// 当前缓存字节数(测试可观测)。
  int get cacheBytes => _cacheBytes;

  @override
  Future<FetchedAttachment> fetch(String sessionId, String attachmentId) {
    final key = (sessionId, attachmentId);
    final hit = _cache[key];
    if (hit != null) {
      _touch(key);
      return Future<FetchedAttachment>.value(hit);
    }
    final running = _inflight[key];
    if (running != null) return running;
    final future = _tracked(_doFetch(key), key);
    _inflight[key] = future;
    return future;
  }

  Future<FetchedAttachment> _doFetch((String, String) key) async {
    final (sessionId, attachmentId) = key;
    final value = await api.call(
      RpcMethods.sessionAttachment,
      <String, dynamic>{'sessionId': sessionId, 'attachmentId': attachmentId},
      parse: SessionAttachmentValue.fromJson,
    );
    final bytes = base64Decode(value.data);
    final result = FetchedAttachment(ref: value.attachment, bytes: bytes);
    _put(key, result);
    return result;
  }

  /// 请求结束(成功或失败)后从 in-flight 表移除;失败不缓存,下次 fetch 重新请求。
  Future<FetchedAttachment> _tracked(
      Future<FetchedAttachment> inner, (String, String) key) async {
    try {
      return await inner;
    } finally {
      _inflight.remove(key);
    }
  }

  /// LRU 命中:移到队尾(最新)。
  void _touch((String, String) key) {
    final hit = _cache.remove(key);
    if (hit != null) _cache[key] = hit;
  }

  /// 写入缓存(替换同名 key 时先扣旧字节),再逐出超限条目。
  void _put((String, String) key, FetchedAttachment entry) {
    final existed = _cache.remove(key);
    if (existed != null) _cacheBytes -= existed.bytes.length;
    _cache[key] = entry;
    _cacheBytes += entry.bytes.length;
    _evict();
  }

  /// 先到先清:从队首(最旧)逐出,直到张数与字节两个上限都满足。
  void _evict() {
    while (_cache.isNotEmpty &&
        (_cache.length > maxCacheEntries || _cacheBytes > maxCacheBytes)) {
      final oldestKey = _cache.keys.first;
      final oldest = _cache.remove(oldestKey)!;
      _cacheBytes -= oldest.bytes.length;
    }
  }
}
