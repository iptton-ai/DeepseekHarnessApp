// 配对页(M6.1 主鉴权入口 + M6.2 扫码邀请):亮码等待 → offers 列表 →
// 人工比对主机码点选。扫码模式下主机码已被二维码锚定,匹配项自动高亮,
// 不匹配项需长按(防误触);被攻击者塞入假 offer 时肉眼可辨。
//
// 360dp 友好:大字亮码、卡片式 offer(≥56dp 触控区)、错误内联。
// 纪律:poll 用 Timer.periodic(2s),dispose 必须取消;409 由客户端自动换码。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/device_identity.dart';
import 'package:singleman/connection/pairing.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/ui/device_name_dialog.dart';
import 'package:singleman/ui/qr_scan_page.dart';

typedef PairingDone = Future<void> Function(RemoteLoginSuccess success);

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.pairing,
    required this.onDone,
    this.initialUrl = kDefaultGatewayBase,
    this.popOnDone = true,
    this.otherHosts = const [],
    this.onSwitchHost,
    this.deviceName,
    this.onSetDeviceName,
  });

  final RemotePairing pairing;

  final PairingDone onDone;
  final String initialUrl;

  /// 作为路由页时 true(pop 返回);作为门卫壳(MateriialApp.home)时 false。
  final bool popOnDone;

  /// 已配对的其他主机(令牌失效被门卫挡住时,可一键切换而不必重配)。
  final List<StoredCredentials> otherHosts;
  final Future<void> Function(String hostId)? onSwitchHost;

  /// 本机设备名(上报给网关的 `device`;首屏可改名)。
  /// null = 未注入(旧测试形态),回退 'dshapp-<platform>' 字面量。
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

enum _Stage { url, waiting, offers, confirming, done }

class _PairingPageState extends State<PairingPage> {
  late final TextEditingController _url;
  _Stage _stage = _Stage.url;
  bool _busy = false;
  String? _error;
  PairingSession? _session;
  List<PairOfferView> _offers = const [];
  Timer? _pollTimer;
  int _pollCount = 0;
  /// 扫码邀请锚定的主机码(offers 里匹配项高亮;非匹配项需长按)。
  String? _anchoredHostCode;
  String _inviteLabel = '';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _url.dispose();
    super.dispose();
  }

  /// 判定是否有可用的扫码包支持。
  /// Android/iOS 使用 pub.dev 版本；OHOS 使用 CPF-Flutter fork (见 pubspec.yaml override)。
  /// 桌面端无相机硬件，走剪贴板兜底。
  static bool _hasQrScannerSupport() =>
      Platform.isAndroid || Platform.isIOS ||
      Platform.operatingSystem == 'ohos';

  /// 二维码按钮:Android/iOS 呼起相机扫 dsh web 的二维码;
  /// OHOS/桌面形态退回剪贴板粘贴(落地页「复制」产物或裸码)。
  Future<void> _scanOrPaste() async {
    if (_hasQrScannerSupport()) {
      final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          fullscreenDialog: true,
          builder: (_) => const QrScanPage(),
        ),
      );
      if (raw == null || raw.isEmpty) return;
      await _applyInviteText(raw, origin: '扫码');
    } else {
      final data = await Clipboard.getData('text/plain');
      await _applyInviteText(data?.text ?? '', origin: '剪贴板');
    }
  }

  /// 应用邀请文本(扫码结果或剪贴板):合法邀请直接以邀请码发起。
  Future<void> _applyInviteText(String text, {String origin = '剪贴板'}) async {
    final invite = parsePairInvite(text, fallbackBase: _fallbackBase());
    if (invite == null) {
      setState(() => _error = '$origin内容不是有效的配对邀请'
          '(应扫 dsh web「移动接入」的二维码;或系统相机扫码后在落地页点「复制」再粘贴)');
      return;
    }
    _url.text = invite.baseUri.toString();
    await _start(code: invite.code, anchor: invite.hostCode, label: invite.label);
  }

  Uri? _fallbackBase() {
    final parsed = Uri.tryParse(_url.text.trim());
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) return parsed;
    return null;
  }

  /// 上报给网关的设备名:注入的 store 优先(未装载/空回退旧字面量)。
  String _deviceLabel() =>
      deviceLabelOr(widget.deviceName, 'dshapp-${Theme.of(context).platform.name}');

  Future<void> _start({String? code, String? anchor, String? label}) async {
    final parsed = Uri.tryParse(_url.text.trim());
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      setState(() => _error = '地址格式不对,应形如 https://dsh.example.com');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _anchoredHostCode = anchor;
    });
    try {
      final session = await widget.pairing.pairStart(
        parsed,
        device: _deviceLabel(),
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _stage = _Stage.waiting;
        _busy = false;
        _offers = const [];
        _pollCount = 0;
        if (label != null && label.isNotEmpty) _inviteLabel = label;
      });
      _startPolling();
    } on PairingFailure catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '发起配对失败: $e';
        });
      }
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    final session = _session;
    if (session == null || _stage == _Stage.confirming || _stage == _Stage.done) {
      return;
    }
    try {
      final result = await widget.pairing.pairPoll(session);
      if (!mounted) return;
      setState(() => _pollCount += 1);
      switch (result.status) {
        case PairPollStatus.waiting:
          if (_stage == _Stage.offers) {
            setState(() => _stage = _Stage.waiting);
          }
        case PairPollStatus.offers:
          if (_stage != _Stage.offers) {
            setState(() {
              _stage = _Stage.offers;
              _offers = result.offers;
            });
          } else if (result.offers.length != _offers.length) {
            setState(() => _offers = result.offers);
          }
        case PairPollStatus.confirmed:
          // 令牌只经 confirm 发放;这里的 confirmed 是状态残留,提示重试。
          _pollTimer?.cancel();
          setState(() => _error = '该配对码已被使用,请重新发起');
        case PairPollStatus.expired:
          _pollTimer?.cancel();
          setState(() {
            _stage = _Stage.url;
            _error = '配对码已过期,请重新发起';
          });
      }
    } on PairingFailure catch (e) {
      // 单次轮询失败不打断流程(网络抖动);只在持续失败时报错。
      // 失败也要计数 —— 只计成功的话网关不可达时永远到不了阈值,
      // 手机就静默停在「等待电脑应约」。
      if (!mounted) return;
      _pollCount += 1;
      if (_pollCount > 3 && _error == null) {
        setState(() => _error = '轮询失败: ${e.message}');
      }
    } on Object catch (e) {
      // 非协议错误(SocketException 等)同样只计数提示,不让轮询死掉。
      if (!mounted) return;
      _pollCount += 1;
      if (_pollCount > 3 && _error == null) {
        setState(() => _error = '轮询失败: $e');
      }
    }
  }

  Future<void> _confirm(PairOfferView offer) async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _stage = _Stage.confirming;
      _error = null;
    });
    try {
      final success = await widget.pairing.pairConfirm(session, offer);
      _pollTimer?.cancel();
      await widget.onDone(success);
      if (mounted) {
        setState(() => _stage = _Stage.done);
        if (widget.popOnDone) Navigator.of(context).pop(true);
      }
    } on PairingFailure catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.offers;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('配对连接')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: switch (_stage) {
                _Stage.url => _buildUrlStep(scheme),
                _Stage.waiting => _buildWaitingStep(scheme),
                _Stage.offers => _buildOffersStep(scheme),
                _Stage.confirming => _buildConfirming(scheme),
                _Stage.done => const Center(child: CircularProgressIndicator()),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUrlStep(ColorScheme scheme) {
    final hasScanner = _hasQrScannerSupport();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.phonelink_ring_outlined, size: 44, color: scheme.primary),
        const SizedBox(height: 10),
        Text(
          '与运行 DSH 的电脑配对,两种方式任选其一',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        // 方式一(推荐):扫码/粘贴邀请。二维码/邀请自带网关地址,发起时
        // 会覆盖手填地址(防「手机等 A 网关、Mac 去 B 网关应约」的错位),
        // 故与手动输入分区展示,避免「扫了码却以为在用手填地址」的误解。
        OutlinedButton.icon(
          onPressed: _busy ? null : _scanOrPaste,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          icon: Icon(hasScanner ? Icons.qr_code_scanner : Icons.content_paste),
          label: Text(hasScanner ? '扫码配对(推荐)' : '粘贴邀请配对(推荐)'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            hasScanner
                ? '扫 Mac「移动接入」窗口的二维码 —— 网关地址由二维码自带,不会用到下方手填的地址'
                : '粘贴 Mac「移动接入」窗口复制的邀请链接 —— 网关地址由邀请自带,不会用到下方手填的地址',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 20),
        Text('或 手动配对', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '网关地址(手动配对用)',
            hintText: 'https://dsh.example.com',
            helperText: '填网关地址 → 生成配对码 → 输入 Mac「移动接入」窗口;粘贴裸 10 位码也按此地址发起',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 18),
        // 本机名称:配对成功后会出现在宿主「已配对设备」表里;首次配对前
        // 就能改(store 未注入的旧形态不渲染)。
        if (widget.deviceName != null && widget.onSetDeviceName != null)
          ValueListenableBuilder<String?>(
            valueListenable: widget.deviceName!,
            builder: (context, name, _) => Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => showDeviceNameDialog(
                          context,
                          current: displayDeviceName(name, '本机'),
                          onSet: widget.onSetDeviceName!,
                        ),
                icon: const Icon(Icons.smartphone, size: 16),
                label: Text(
                  '本机名称 · ${displayDeviceName(name, '…')}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ),
        FilledButton(
          onPressed: _busy ? null : _start,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('生成配对码'),
        ),
        if (widget.otherHosts.isNotEmpty && widget.onSwitchHost != null) ...[
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('切换到已配对的主机', style: Theme.of(context).textTheme.bodySmall),
          ),
          for (final h in widget.otherHosts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lan_outlined, size: 20),
              title: Text(
                h.hostLabel.isEmpty ? h.baseUri.authority : h.hostLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                h.hostLabel.isEmpty ? '点击切换到此主机' : h.baseUri.authority,
                style: const TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.swap_horiz, size: 18),
              onTap: () => widget.onSwitchHost!(h.id),
            ),
        ],
      ],
    );
  }

  Widget _buildWaitingStep(ColorScheme scheme) {
    final session = _session!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _inviteLabel.isEmpty
              ? '把这个码输入 Mac 的 dsh web「移动接入」页(或终端 pair.sh):'
              : '来自 $_inviteLabel 的扫码邀请已就绪(网关 ${session.baseUri.authority});Mac 侧会自动应约:',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Text(
                session.displayCode,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 6),
              Text('10 分钟内有效', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text('等待电脑应约…', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error, fontSize: 13)),
          ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: () {
            _pollTimer?.cancel();
            setState(() {
              _stage = _Stage.url;
              _session = null;
              _error = null;
              _anchoredHostCode = null;
              _inviteLabel = '';
            });
          },
          child: const Text('取消', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildOffersStep(ColorScheme scheme) {
    final session = _session!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本机码 ${session.displayCode}', textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Text(
          _anchoredHostCode == null
              ? '选择与 Mac 终端显示一致的主机码'
              : '你要连接的 Mac 应显示主机码 ${_fmtHost(_anchoredHostCode!)}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (_inviteLabel.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            '来自 $_inviteLabel —— 绿色卡片即为扫码的那台 Mac',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 10),
        _buildVerifyGuidance(scheme),
        const SizedBox(height: 12),
        for (final offer in _offers) _buildOfferCard(scheme, offer),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!,
                style: TextStyle(color: scheme.error, fontSize: 13)),
          ),
      ],
    );
  }

  /// 双向亮码核对指引(ADR-0007 防抢注):明确告知「一致才确认」,
  /// 以及出现陌生主机码意味着什么 —— 网关被攻破时攻击者可塞入假 offer。
  Widget _buildVerifyGuidance(ColorScheme scheme) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.check_circle, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '显示的码与你要连接的 Mac 屏幕一致 → 点击卡片右侧的 ✓ 图标确认',
                  style: style,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '出现了不匹配的码 → 可能是恶意连接:你的网关(gateway)服务器可能已被攻破,请勿点选',
                  style: style?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtHost(String code) =>
      code.length == 6 ? '${code.substring(0, 3)}-${code.substring(3)}' : code;

  /// 锚定模式:匹配 offer 绿框高亮、点按即选;不匹配项降灰、须长按。
  /// 非锚定模式(手输流程):全部常规点选,肉眼比对。
  Widget _buildOfferCard(ColorScheme scheme, PairOfferView offer) {
    final anchored = _anchoredHostCode != null;
    final matched = anchored && offer.hostCode == _anchoredHostCode;
    final disabled = anchored && !matched;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: matched ? scheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: disabled ? null : () => _confirm(offer),
        onLongPress: disabled ? () => _confirm(offer) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
                children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          offer.displayHostCode,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                            color: disabled ? scheme.outline : null,
                          ),
                        ),
                        if (matched) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '扫码匹配',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${offer.hostLabel.isEmpty ? "Mac" : offer.hostLabel}'
                      ' · 隧道 ${offer.upstreamPort}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: disabled ? scheme.outline : null),
                    ),
                  ],
                ),
              ),
              Icon(
                matched ? Icons.verified : Icons.check_circle_outline,
                color: disabled ? scheme.outlineVariant : scheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfirming(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text('正在确认配对…', style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}