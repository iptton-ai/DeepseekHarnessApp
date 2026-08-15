// 配对页(M6.1 主鉴权入口):亮码等待 → offers 列表 → 人工比对主机码点选。
//
// 360dp 友好:大字亮码、卡片式 offer(≥56dp 触控区)、错误内联、密码兜底入口。
// 纪律:poll 用 Timer.periodic(2s),dispose 必须取消;409 由客户端自动换码。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/connection/pairing.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/ui/remote_login.dart';

typedef PairingDone = Future<void> Function(RemoteLoginSuccess success);

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.pairing,
    required this.auth,
    required this.onDone,
    this.initialUrl = 'https://dsh.example.com',
    this.popOnDone = true,
  });

  final RemotePairing pairing;

  /// 密码兜底登录器(网关配置了密码时可用)。
  final RemoteAuthenticator auth;
  final PairingDone onDone;
  final String initialUrl;

  /// 作为路由页时 true(pop 返回);作为门卫壳(MateriialApp.home)时 false。
  final bool popOnDone;

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

  Future<void> _start() async {
    final parsed = Uri.tryParse(_url.text.trim());
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      setState(() => _error = '地址格式不对,应形如 https://dsh.example.com');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.pairing.pairStart(
        parsed,
        device: 'singleman-${Theme.of(context).platform.name}',
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _stage = _Stage.waiting;
        _busy = false;
        _offers = const [];
        _pollCount = 0;
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
      if (_pollCount > 3 && mounted && _error == null) {
        setState(() => _error = '轮询失败: ${e.message}');
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

  void _openPasswordFallback() {
    Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => RemoteLoginPage(
          auth: widget.auth,
          initialUrl: _url.text.trim(),
          onDone: widget.onDone,
        ),
      ),
    );
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.phonelink_ring_outlined, size: 44, color: scheme.primary),
        const SizedBox(height: 10),
        Text(
          '与运行 DSH 的电脑配对\nMac 上执行 pair.sh <配对码>(见 server/remote/)',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _url,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '网关地址',
            hintText: 'https://dsh.example.com',
          ),
        ),
        const SizedBox(height: 18),
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
        const SizedBox(height: 8),
        TextButton(
          onPressed: _openPasswordFallback,
          child: const Text('使用密码登录(兜底)', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildWaitingStep(ColorScheme scheme) {
    final session = _session!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('把这个码输入 Mac 的 pair.sh:', textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
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
          '选择与 Mac 终端显示一致的主机码',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        for (final offer in _offers)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _confirm(offer),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            offer.displayHostCode,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${offer.hostLabel.isEmpty ? "Mac" : offer.hostLabel}'
                            ' · 隧道 ${offer.upstreamPort}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.check_circle_outline, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!,
                style: TextStyle(color: scheme.error, fontSize: 13)),
          ),
        Text(
          '⚠️ 没有显示匹配主机码的选项就不要点选 —— 主机码在 Mac 终端上',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
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
