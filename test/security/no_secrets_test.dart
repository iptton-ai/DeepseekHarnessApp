// 开源防泄漏围栏:扫描 git 跟踪文件,真实基础设施信息不得回流。
//
// 触发场景:并行开发会话可能把真实网关域名/服务器 IP/个人路径重新写进
// 代码(第十七轮清理时实际发生过)。本测试把「占位符姿态」固化为硬约束,
// 发布前任何回流都会在 flutter test 里红掉。
//
// 只扫 git ls-files(= 实际会被 push 的面):build 产物、local.properties、
// ephemeral 等本机生成物天然排除。真实值唯一合法居所:server/LOCAL.md
// (server/ 已 gitignore)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('跟踪文件不含真实网关域名/IP/个人路径(开源防泄漏围栏)', () async {
  // 拆分构造:①本文件自身不连续含目标串;②拆分粒度必须保证任何「占位符
  // 替换规则」的左侧无法 contiguous 命中任何碎片拼接 —— 第十七轮教训:
  // filter-repo 的域名占位替换曾把首模式的真实域名字面量整个换掉,
  // 围栏静默失明还误报占位符。
  final patterns = <String>[
    'dsh.' + 'yltech' + '.store',
    'yltech' + '.store',
    '101.35.' + '129.159',
    '/Users/' + 'zxnap',
    'dshgw-' + 'password',
  ];
  // 防自伤自检:模式若被批量替换腐化成占位符本身,必须炸,不许静默通过。
  final neutralized = {'dsh.' + 'example' + '.com', 'example' + '.com'};
  final corrupted = patterns.where(neutralized.contains).toList();
  if (corrupted.isNotEmpty) {
    fail('围栏模式被占位符替换腐化(历史重写/批量 sed 误伤?):$corrupted');
  }
  final tracked = await Process.run('git', ['ls-files']);
  if (tracked.exitCode != 0) {
    throw StateError('git ls-files 失败(测试需在 git 仓库内运行)');
  }
  final textExtensions = <String>{
    '.dart', '.md', '.sh', '.yaml', '.yml', '.json', '.mjs', '.plist',
    '.kts', '.gradle', '.properties', '.xml', '.swift', '.entitlements',
    '.lock', '.pbxproj', '.xcscheme', '.xcconfig', '.txt',
    '', // LICENSE 等无扩展名文件
  };

  final offenders = <String>[];
  final files = (tracked.stdout as String).split('\n')
    ..removeWhere((l) => l.isEmpty || l.startsWith('test/security/'));
  for (final rel in files) {
    final ext = rel.contains('.') ? '.${rel.split('.').last}' : '';
    if (!textExtensions.contains(ext)) continue;
    final f = File(rel);
    if (!await f.exists() || await f.length() > 2 * 1024 * 1024) continue;
    final List<String> lines;
    try {
      lines = await f.readAsLines();
    } on FileSystemException {
      continue;
    }
    for (var i = 0; i < lines.length; i++) {
      for (final p in patterns) {
        if (lines[i].contains(p)) offenders.add('$rel:${i + 1} 命中敏感模式');
      }
    }
  }
  if (offenders.isNotEmpty) {
    fail('敏感信息回流(${offenders.length} 处,真实值只允许存在于 '
        'server/LOCAL.md,该目录已 gitignore):\n${offenders.join('\n')}');
  }
  });
}
