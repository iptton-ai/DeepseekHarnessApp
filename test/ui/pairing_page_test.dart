// 配对页 widget 测试(M6.1 + M6.2):亮码展示 → offers 列表 → 点选确认回调;
// 409 场景客户端自动换码;无密码登录入口;扫码邀请粘贴 → 锚定高亮。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/pairing.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/ui/pairing_page.dart';

class _FakePairing implements RemotePairing {
  _FakePairing(this._pollResults);

  /// 依次返回的轮询结果;耗尽后重复最后一个。
  final List<PairPollResult> _pollResults;
  int _pollIndex = 0;
  int startCalls = 0;
  String? lastStartCode;
  String? lastDevice;
  PairOfferView? confirmedOffer;
  PairingSession? lastSession;

  @override
  Future<PairingSession> pairStart(Uri baseUri,
      {String device = 'singleman', String? code}) async {
    startCalls++;
    final n = startCalls;
    lastStartCode = code;
    lastDevice = device;
    // 字符集与真实生成器一致(无 I/L/O/0/1)。
    const c = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final effective = code ?? 'ABCDE${c[n % c.length]}${c[(n * 7) % c.length]}234';
    return PairingSession(
      baseUri: baseUri,
      pairingId: 'pr-$n',
      code: effective,
      secret: 'secret-abcdefghijklmnopqrstuvwxyz99',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<PairPollResult> pairPoll(PairingSession session) async {
    lastSession = session;
    final i = _pollIndex;
    _pollIndex++;
    final list = _pollResults;
    return list[i < list.length ? i : list.length - 1];
  }

  @override
  Future<RemoteLoginSuccess> pairConfirm(PairingSession session, PairOfferView offer) async {
    confirmedOffer = offer;
    return RemoteLoginSuccess(baseUri: session.baseUri, token: 'tok-ok');
  }
}

const _offerA = {
  'claim_id': 'cl-a',
  'host_code': 'ABC234',
  'host_label': 'mac-mini',
  'upstream_port': 13100,
  'expires_at': 1999999999,
};
const _offerB = {
  'claim_id': 'cl-b',
  'host_code': 'XYZ789',
  'host_label': 'mbp',
  'upstream_port': 13101,
  'expires_at': 1999999999,
};

Future<void> pumpPage(
  WidgetTester tester, {
  required RemotePairing pairing,
  required Future<void> Function(RemoteLoginSuccess) onDone,
  List<StoredCredentials> otherHosts = const [],
  Future<void> Function(String hostId)? onSwitchHost,
  ValueListenable<String?>? deviceName,
  Future<bool> Function(String)? onSetDeviceName,
}) {
  return tester.pumpWidget(MaterialApp(
    home: PairingPage(
      pairing: pairing,
      onDone: onDone,
      initialUrl: 'https://dsh.example.com',
      otherHosts: otherHosts,
      onSwitchHost: onSwitchHost,
      deviceName: deviceName,
      onSetDeviceName: onSetDeviceName,
    ),
  ));
}

void main() {
  testWidgets('设备名:store 注入即上报与可改;未注入回退旧字面量',
      (tester) async {
    final pairing = _FakePairing([
      const PairPollResult(status: PairPollStatus.waiting, offers: []),
    ]);
    final name = ValueNotifier<String?>('Android-Pixel8');
    await pumpPage(
      tester,
      pairing: pairing,
      onDone: (_) async {},
      deviceName: name,
      onSetDeviceName: (raw) async {
        name.value = raw;
        return true;
      },
    );

    // 首屏:本机名称行展示当前默认值;改名即时反映(仍在 URL 步)。
    expect(find.text('本机名称 · Android-Pixel8'), findsOneWidget);
    name.value = '我的手机';
    await tester.pump();
    expect(find.text('本机名称 · 我的手机'), findsOneWidget);

    // 发起配对 → 上报改名后的设备名(发起后进入等待屏,名称行不在)。
    await tester.tap(find.text('生成配对码'));
    await tester.pump();
    expect(pairing.lastDevice, '我的手机');

  });

  testWidgets('设备名未注入(旧形态):回退 dshapp-<platform> 字面量',
      (tester) async {
    final bare = _FakePairing([
      const PairPollResult(status: PairPollStatus.waiting, offers: []),
    ]);
    await pumpPage(tester, pairing: bare, onDone: (_) async {});
    expect(find.text('生成配对码'), findsOneWidget);
    await tester.tap(find.text('生成配对码'));
    await tester.pump();
    expect(bare.lastDevice, startsWith('dshapp-'));
    expect(find.byIcon(Icons.smartphone), findsNothing, reason: '未注入不渲染名称行');
  });

  testWidgets('start shows the pairing code, offers list, tap confirms',
      (tester) async {
    final pairing = _FakePairing([
      const PairPollResult(status: PairPollStatus.waiting, offers: []),
      PairPollResult(
        status: PairPollStatus.offers,
        offers: [
          PairOfferView.fromJson(_offerA),
          PairOfferView.fromJson(_offerB),
        ],
      ),
    ]);
    RemoteLoginSuccess? received;

    await pumpPage(tester, pairing: pairing, onDone: (s) async => received = s);
    await tester.tap(find.text('生成配对码'));
    await tester.pump();

    // 亮码展示(带连字符格式)。
    expect(find.textContaining(RegExp(r'[A-Z2-9]{5}-[A-Z2-9]{5}')), findsOneWidget);
    expect(find.text('等待电脑应约…'), findsOneWidget);

    // 推进一个轮询周期 → offers 出现(两条)。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ABC-234'), findsOneWidget);
    expect(find.text('XYZ-789'), findsOneWidget);
    expect(find.textContaining('mac-mini'), findsOneWidget);
    expect(find.textContaining('mbp'), findsOneWidget);

    // 点选 mbp 的 offer → onDone 收到令牌。
    await tester.tap(find.text('XYZ-789'));
    await tester.pumpAndSettle();
    expect(received?.token, 'tok-ok');
    expect(pairing.confirmedOffer?.hostCode, 'XYZ789');
  });

  testWidgets('wrong URL shows inline error without starting', (tester) async {
    final pairing = _FakePairing(const [
      PairPollResult(status: PairPollStatus.waiting, offers: []),
    ]);
    await pumpPage(tester, pairing: pairing, onDone: (_) async {});
    await tester.enterText(
        find.byType(TextField), 'not a url');
    await tester.tap(find.text('生成配对码'));
    await tester.pump();
    expect(find.textContaining('地址格式'), findsOneWidget);
    expect(pairing.startCalls, 0);
  });

  testWidgets('no password login entry (pairing is the only channel)',
      (tester) async {
    await pumpPage(
      tester,
      pairing: _FakePairing(const [
        PairPollResult(status: PairPollStatus.waiting, offers: []),
      ]),
      onDone: (_) async {},
    );
    expect(find.text('使用密码登录(兜底)'), findsNothing);
  });

  testWidgets('paste scan invite starts with invite code and anchors offers',
      (tester) async {
    const inviteUrl =
        'https://dsh.example.com/pair#c=ABCDEFGHJK&h=ABC234&l=mac-mini';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object>{'text': inviteUrl};
        }
        return null;
      },
    );
    final pairing = _FakePairing([
      PairPollResult(
        status: PairPollStatus.offers,
        offers: [
          PairOfferView.fromJson(_offerA), // ABC234 = 锚定匹配
          PairOfferView.fromJson(_offerB), // XYZ789 = 不匹配
        ],
      ),
    ]);
    RemoteLoginSuccess? received;

    await pumpPage(tester, pairing: pairing, onDone: (s) async => received = s);
    await tester.tap(find.text('粘贴邀请配对(推荐)'));
    await tester.pump();

    // 邀请码发起(fake 首个轮询即返回 offers,等待页会被立即推进)。
    expect(pairing.lastStartCode, 'ABCDEFGHJK');

    // offers 到达:匹配项带「扫码匹配」徽标;来源机器展示邀请 label。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('ABCDE-FGHJK'), findsOneWidget);
    expect(find.textContaining('来自 mac-mini'), findsOneWidget);
    expect(find.text('扫码匹配'), findsOneWidget);

    // 点不匹配项无效(InkWell 禁用点按),长按才是逃生口。
    await tester.tap(find.text('XYZ-789'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(pairing.confirmedOffer, isNull);

    // 点匹配项 → 确认。
    await tester.tap(find.text('ABC-234'));
    await tester.pumpAndSettle();
    expect(received?.token, 'tok-ok');
    expect(pairing.confirmedOffer?.hostCode, 'ABC234');
  });

  testWidgets('long-press bypasses anchor for non-matching offer', (tester) async {
    const inviteUrl = 'https://dsh.example.com/pair#c=ABCDEFGHJK&h=ABC234';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object>{'text': inviteUrl};
        }
        return null;
      },
    );
    final pairing = _FakePairing([
      PairPollResult(
        status: PairPollStatus.offers,
        offers: [PairOfferView.fromJson(_offerB)], // 只有不匹配项
      ),
    ]);

    await pumpPage(tester, pairing: pairing, onDone: (_) async {});
    await tester.tap(find.text('粘贴邀请配对(推荐)'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));

    // 长按不匹配项仍可确认(多 Mac 场景:旧邀请换机应约)。
    await tester.longPress(find.text('XYZ-789'));
    await tester.pumpAndSettle();
    expect(pairing.confirmedOffer?.hostCode, 'XYZ789');
  });

  testWidgets('invalid clipboard shows inline error', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object>{'text': '随便复制的无关文本'};
        }
        return null;
      },
    );
    final pairing = _FakePairing(const [
      PairPollResult(status: PairPollStatus.waiting, offers: []),
    ]);
    await pumpPage(tester, pairing: pairing, onDone: (_) async {});
    await tester.tap(find.text('粘贴邀请配对(推荐)'));
    await tester.pump();
    expect(find.textContaining('不是有效的配对邀请'), findsOneWidget);
    expect(pairing.startCalls, 0);
  });

  testWidgets('offer tap targets are mobile-sized (>=56dp card)', (tester) async {
    final pairing = _FakePairing([
      PairPollResult(
        status: PairPollStatus.offers,
        offers: [PairOfferView.fromJson(_offerA)],
      ),
    ]);
    await pumpPage(tester, pairing: pairing, onDone: (_) async {});
    await tester.tap(find.text('生成配对码'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));
    final card = tester.getSize(find.byType(Card).first);
    expect(card.height, greaterThanOrEqualTo(56));
  });

  testWidgets('otherHosts:切换入口按机器名展示,点击回调 hostId(令牌失效重配场景)',
      (tester) async {
    final pairing = _FakePairing(const [
      PairPollResult(status: PairPollStatus.waiting, offers: []),
    ]);
    String? switched;
    await pumpPage(
      tester,
      pairing: pairing,
      onDone: (_) async {},
      otherHosts: [
        StoredCredentials(
          id: 'https://gw2.example.com:443',
          baseUri: Uri.parse('https://gw2.example.com'),
          token: 't2',
          hostLabel: 'MacB',
        ),
        StoredCredentials(
          id: 'https://gw3.example.com:443',
          baseUri: Uri.parse('https://gw3.example.com'),
        ),
      ],
      onSwitchHost: (id) async => switched = id,
    );
    await tester.pump();

    expect(find.text('切换到已配对的主机'), findsOneWidget);
    // 有机器名的行显示机器名,无机器名的回落网关 authority。
    expect(find.text('MacB'), findsOneWidget);
    expect(find.text('gw3.example.com'), findsOneWidget);

    await tester.tap(find.text('MacB'));
    await tester.pump();
    expect(switched, 'https://gw2.example.com:443');
  });

  testWidgets('otherHosts 为空时不渲染切换入口(首启/单主机形态)', (tester) async {
    final pairing = _FakePairing(const [
      PairPollResult(status: PairPollStatus.waiting, offers: []),
    ]);
    await pumpPage(tester, pairing: pairing, onDone: (_) async {});
    await tester.pump();
    expect(find.text('切换到已配对的主机'), findsNothing);
  });
}
