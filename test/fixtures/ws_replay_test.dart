// M0 fixture replay: captured WS frames (fixtures/ws/*.jsonl) must parse
// through the generated ServerRequest envelope + MuxFrame union, and every
// frame must round-trip its type discriminator.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

void main() {
  final muxFile = File('fixtures/ws/mux-frames.jsonl');
  final hostFile = File('fixtures/ws/host-frames.jsonl');

  test('captured mux frames parse as ServerRequest + MuxFrame', () {
    if (!muxFile.existsSync()) {
      markTestSkipped('no captured fixtures yet; run dart run tool/codegen/capture_ws.dart');
      return;
    }
    final lines = muxFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    expect(lines, isNotEmpty, reason: 'fixture should contain frames');
    final typeCounts = <String, int>{};
    for (final line in lines) {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      final envelope = RpcMessage.fromJson(rec['frame'] as Map<String, dynamic>);
      expect(envelope, isA<RpcMessageServerRequest>());
      final req = envelope as RpcMessageServerRequest;
      final frame = MuxFrame.fromJson(req.payload as Map<String, dynamic>);
      final key = frame.runtimeType.toString();
      typeCounts[key] = (typeCounts[key] ?? 0) + 1;
      // round-trip discriminator
      final json = frame.toJson();
      expect(json['type'], isA<String>());
    }
    // The live host always sends session/subscribed for attached sessions.
    expect(typeCounts['MuxFrameSessionSubscribed'], greaterThan(0));
  });

  test('captured host frames parse when present', () {
    if (!hostFile.existsSync()) {
      markTestSkipped('no host frames captured');
      return;
    }
    final lines = hostFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    for (final line in lines) {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      final envelope = RpcMessage.fromJson(rec['frame'] as Map<String, dynamic>);
      expect(envelope, isA<RpcMessageServerRequest>());
      final req = envelope as RpcMessageServerRequest;
      final frame = HostFrame.fromJson(req.payload as Map<String, dynamic>);
      expect(frame.toJson()['type'], isA<String>());
    }
  });
}
