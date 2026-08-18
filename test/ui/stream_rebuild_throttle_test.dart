// StreamRebuildThrottle 单元测试(fake_async 驱动时间窗):
// 覆盖 leading/trailing、快档覆盖慢档、reset/dispose 语义 —— 与
// ChatViewModel 既有节流行为逐条对齐(该节拍器现为主列表与子代理
// transcript 共用,行为回归即两者一起回归)。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/ui/stream_rebuild_throttle.dart';

void main() {
  test('空闲后首个慢档立即落地(leading)', () {
    FakeAsync().run((async) {
      final flushes = <Object?>[];
      final t = StreamRebuildThrottle(onFlush: flushes.add);
      t.schedule('a', slow: true);
      async.flushMicrotasks();
      expect(flushes, ['a']);
      t.dispose();
    });
  });

  test('窗口内的后续慢档推迟到尾沿,且一窗至多一次(trailing 合并)', () {
    FakeAsync().run((async) {
      var flushes = 0;
      final t = StreamRebuildThrottle(onFlush: (_) => flushes++);
      t.schedule(null, slow: true);
      async.flushMicrotasks();
      expect(flushes, 1); // leading

      // 窗口内持续涌入(delta = 独立事件循环轮次,逐个 schedule)。
      t.schedule(null, slow: true);
      async.flushMicrotasks();
      t.schedule(null, slow: true);
      async.flushMicrotasks();
      expect(flushes, 1, reason: '窗口内不落地');

      async.elapse(const Duration(milliseconds: 250));
      expect(flushes, 2, reason: '尾沿统一落地,且只一次');
      t.dispose();
    });
  });

  test('同批合并:慢档后到快档 → 立即落地', () {
    FakeAsync().run((async) {
      final flushes = <Object?>[];
      final t = StreamRebuildThrottle(onFlush: flushes.add);
      t.schedule('slow-token', slow: true);
      t.schedule(null, slow: false);
      async.flushMicrotasks();
      expect(flushes, ['slow-token']);
      t.dispose();
    });
  });

  test('尾沿挂起时新到快档 → 立即落地(不被慢档降级)', () {
    FakeAsync().run((async) {
      var flushes = 0;
      final t = StreamRebuildThrottle(onFlush: (_) => flushes++);
      t.schedule(null, slow: true);
      async.flushMicrotasks();
      expect(flushes, 1);

      t.schedule(null, slow: true); // 排出尾沿
      async.flushMicrotasks();
      expect(flushes, 1);

      t.schedule(null, slow: false); // 结构变化:一帧不等待
      async.flushMicrotasks();
      expect(flushes, 2);
      t.dispose();
    });
  });

  test('reset 丢弃尾沿;dispose 后不再落地', () {
    FakeAsync().run((async) {
      var flushes = 0;
      final t = StreamRebuildThrottle(onFlush: (_) => flushes++);
      t.schedule(null, slow: true);
      async.flushMicrotasks();
      expect(flushes, 1);

      t.schedule(null, slow: true);
      async.flushMicrotasks();
      t.reset();
      async.elapse(const Duration(milliseconds: 250));
      expect(flushes, 1, reason: '尾沿被 reset 取消');

      t.dispose();
      t.schedule(null, slow: false);
      async.flushMicrotasks();
      expect(flushes, 1, reason: 'dispose 后拒绝落地');
    });
  });
}
