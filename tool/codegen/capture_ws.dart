// Capture N seconds of the two DSH downlinks into fixtures/ws/*.jsonl (replay corpus).
// Usage: dart run tool/codegen/capture_ws.dart [seconds] [baseUrl]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  final seconds = args.isNotEmpty ? int.parse(args[0]) : 10;
  final base = args.length > 1 ? args[1] : 'http://127.0.0.1:3080';
  final wsBase = base.replaceFirst(RegExp(r'^http'), 'ws');
  Directory('fixtures/ws').createSync(recursive: true);
  final muxF = File('fixtures/ws/mux-frames.jsonl');
  final hostF = File('fixtures/ws/host-frames.jsonl');
  if (muxF.existsSync()) muxF.deleteSync();
  if (hostF.existsSync()) hostF.deleteSync();

  final muxLines = <String>[];
  final hostLines = <String>[];

  Future<void> tap(String name, String url, List<String> lines) async {
    try {
      final ws = await WebSocket.connect(url);
      final done = Completer<void>();
      ws.listen(
        (data) {
          final decoded = jsonDecode(data as String);
          lines.add(jsonEncode({
            'capturedAt': DateTime.now().toIso8601String(),
            'frame': decoded,
          }));
        },
        onError: (Object e) {
          print('$name error: $e');
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          print('$name closed');
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );
      print('$name connected');
    } catch (e) {
      print('$name connect failed: $e');
    }
  }

  await tap('mux', '$wsBase/api/events.mux', muxLines);
  await tap('host', '$wsBase/api/events.host', hostLines);
  await Future.delayed(Duration(seconds: seconds));
  muxF.writeAsStringSync(muxLines.join('\n') + (muxLines.isEmpty ? '' : '\n'));
  hostF.writeAsStringSync(hostLines.join('\n') + (hostLines.isEmpty ? '' : '\n'));
  print('captured mux=${muxLines.length} host=${hostLines.length} frames in ${seconds}s');
}
