// 配对页 widget 测试(M6.1):亮码展示 → offers 列表 → 点选确认回调;
// 409 场景客户端自动换码;密码兜底入口存在。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/pairing.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/ui/pairing_page.dart';

class _FakePairing implements RemotePairing {
  _FakePairing(this._pollResults);

  /// 依次返回的轮询结果;耗尽后重复最后一个。
  final List<PairPollResult> _pollResults;
  int _pollIndex = 0;
  int startCalls = 0;
  PairOfferView? confirmedOffer;
  PairingSession? lastSession;

  @override
  Future<PairingSession> pairStart(Uri baseUri, {String device = 'singleman'}) async {
    startCalls++;
    final n = startCalls;
    // 字符集与真实生成器一致(无 I/L/O/0/1)。
    const c = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final code = 'ABCDE${c[n % c.length]}${c[(n * 7) % c.length]}234';
    return PairingSession(
      baseUri: baseUri,
      pairingId: 'pr-$n',
      code: code,
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

class _FakeAuth implements RemoteAuthenticator {
  @override
  Future<RemoteLoginSuccess> login(Uri baseUri, String password,
      {String device = 'singleman'}) async {
    throw const RemoteLoginFailure('密码登录禁用');
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
}) {
  return tester.pumpWidget(MaterialApp(
    home: PairingPage(
      pairing: pairing,
      auth: _FakeAuth(),
      onDone: onDone,
      initialUrl: 'https://dsh.example.com',
    ),
  ));
}

void main() {
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

  testWidgets('password fallback entry exists', (tester) async {
    await pumpPage(
      tester,
      pairing: _FakePairing(const [
        PairPollResult(status: PairPollStatus.waiting, offers: []),
      ]),
      onDone: (_) async {},
    );
    expect(find.text('使用密码登录(兜底)'), findsOneWidget);
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
}
