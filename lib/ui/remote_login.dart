// 远程登录页(M6 公网形态):网关 URL + 密码 → 设备令牌 → 进入主界面。
// 触发场景:①首次配置远程连接 ②令牌失效/被吊销(authBlocked)。
import 'package:flutter/material.dart';
import 'package:singleman/connection/remote_auth.dart';

/// 登录成功回调:凭证已写入 provider/store,调用方负责继续启动。
typedef RemoteLoginDone = Future<void> Function(RemoteLoginSuccess success);

class RemoteLoginPage extends StatefulWidget {
  const RemoteLoginPage({
    super.key,
    required this.auth,
    required this.onDone,
    this.initialUrl,
    this.title = '连接到 DSH 网关',
    this.popOnDone = true,
  });

  final RemoteAuthenticator auth;
  final RemoteLoginDone onDone;

  /// 初始地址;null 时用 [defaultGatewayBase](环境变量可覆盖)。
  final String? initialUrl;
  final String title;

  /// 路由页默认登录成功后退出;根节点登录门卫由父级切换页面,不弹栈。
  final bool popOnDone;

  @override
  State<RemoteLoginPage> createState() => _RemoteLoginPageState();
}

class _RemoteLoginPageState extends State<RemoteLoginPage> {
  late final TextEditingController _url;
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(
        text: widget.initialUrl ?? defaultGatewayBase().toString());
  }

  @override
  void dispose() {
    _url.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final parsed = Uri.tryParse(_url.text.trim());
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      setState(() => _error = '地址格式不对,应形如 https://dsh.example.com');
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = '请输入网关密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final success = await widget.auth.login(
        parsed,
        _password.text,
        device: 'singleman-${Theme.of(context).platform.name}',
      );
      await widget.onDone(success);
      if (mounted && widget.popOnDone) Navigator.of(context).pop(true);
    } on RemoteLoginFailure catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '登录失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.shield_outlined, size: 44, color: scheme.primary),
                  const SizedBox(height: 10),
                  Text(
                    '移动端经网关安全接入本机 DSH\n(密码登录一次,令牌 30 天可吊销)',
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
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _obscure,
                    onSubmitted: (_) => _busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: '网关密码',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
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
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('登录并连接'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
