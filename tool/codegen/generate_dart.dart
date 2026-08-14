// Codegen stage 2: exported JSON Schemas (tool/codegen/schemas/*.json)
// -> Dart models under lib/wire/generated/ as ONE part library.
//
// Usage: dart run tool/codegen/generate_dart.dart
//
// Contract firewall (ADR-0001). zod v4 toJSONSchema inlines every reuse, so
// this emitter structurally dedupes: an inline node whose normalized JSON
// equals a named schema parses as that named class.
// Authored without dollar-brace interpolation (tooling constraint).
import 'dart:convert';
import 'dart:io';

const dshVersion = '0.1.0-rc.6';

_Gen? globalGen;

void main() {
  final outDir = Directory('lib/wire/generated');
  outDir.createSync(recursive: true);
  final manifest = jsonDecode(File('tool/codegen/schemas/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final actual = manifest['dshVersion'] as String;
  if (actual != dshVersion) {
    stderr.writeln('manifest dshVersion ' + actual + ' != pinned ' + dshVersion + '; run export-schemas.mjs first');
    exit(2);
  }
  final modules = manifest['modules'] as Map<String, dynamic>;
  final docs = <String, Map<String, dynamic>>{};
  for (final domain in modules.keys) {
    docs[domain] = jsonDecode(File('tool/codegen/schemas/' + domain + '.json').readAsStringSync()) as Map<String, dynamic>;
  }
  final gen = _Gen(docs);
  gen.buildStructIndex();
  globalGen = gen;
  final partNames = <String>[];
  for (final domain in (modules.keys.toList()..sort())) {
    final buf = StringBuffer();
    buf.writeln("part of 'wire_generated.dart';");
    buf.writeln();
    buf.writeln('// ' + domain + ' domain models.');
    buf.writeln();
    final names = (modules[domain] as List).cast<String>();
    final schemas = docs[domain]!['schemas'] as Map<String, dynamic>;
    for (final name in names) {
      final node = schemas[name] as Map<String, dynamic>?;
      if (node == null) continue;
      gen.emitNamed(buf, name, node);
    }
    final partFile = snake(domain) + '.dart';
    File(outDir.path + '/' + partFile).writeAsStringSync(buf.toString());
    partNames.add(partFile);
    stdout.writeln('wrote ' + partFile);
  }
  final lb = StringBuffer();
  lb.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  lb.writeln('// Wire contract library (dsh ' + dshVersion + ') via export-schemas.mjs + generate_dart.dart.');
  lb.writeln();
  for (final p in partNames) {
    lb.writeln("part '" + p + "';");
  }
  lb.writeln();
  final methods = (manifest['methods'] as List).cast<String>();
  lb.writeln('/// All client-request method names, frozen from RpcMethodMap (dsh ' + dshVersion + ').');
  lb.writeln('abstract final class RpcMethods {');
  lb.writeln('  RpcMethods._();');
  for (final m in methods) {
    lb.writeln("  static const String " + methodConst(m) + " = '" + m + "';");
  }
  lb.writeln('}');
  lb.writeln();
  lb.writeln('/// Every method name in registry order.');
  lb.writeln('const kAllRpcMethods = <String>[');
  for (final m in methods) {
    lb.writeln('  RpcMethods.' + methodConst(m) + ',');
  }
  lb.writeln('];');
  File(outDir.path + '/wire_generated.dart').writeAsStringSync(lb.toString());
  stdout.writeln('wrote wire_generated.dart');
  stdout.writeln('done: ' + methods.length.toString() + ' methods, ' + partNames.length.toString() + ' parts');
}

String pascal(String s) => s.split(RegExp(r'[-_.]')).where((p) => p.isNotEmpty).map((p) => p[0].toUpperCase() + p.substring(1)).join();

String lower(String s) { final p = pascal(s); return p.isEmpty ? p : p[0].toLowerCase() + p.substring(1); }

String snake(String s) => camelToSnake(pascal(s));

String camelToSnake(String s) { var out = ''; for (var i = 0; i < s.length; i++) { final c = s[i]; if (c.toUpperCase() == c && c.toLowerCase() != c && i > 0) { out += '_'; } out += c.toLowerCase(); } return out; }

String methodConst(String m) { final p = m.split('.'); return lower(p[0]) + pascal(p[1]); }

const reservedWords = {'default','for','in','is','this','super','class','new','return','switch','while','do','try','catch','finally','throw','assert','break','continue','const','final','var','void','null','true','false','extends','implements','with','enum','mixin','required','late','import','export','library','part','typedef','operator','set','get','abstract','base','sealed','interface','factory','on','async','await','yield','sync','external','static','covariant','dynamic','num','int','double','bool','String','List','Map','Object'};

String dartName(String jsonName) {
  final n = lower(jsonName);
  return reservedWords.contains(n) ? n + '_' : n;
}

class _Field {
  final String jsonName, dart;
  final Map<String, dynamic> schema;
  final bool required;
  _Field(this.jsonName, this.schema, this.required) : dart = dartName(jsonName);
}

class _Gen {
  final Map<String, Map<String, dynamic>> docs;
  final structIndex = <String, String>{};
  final structKinds = <String, String>{};
  final emitted = <String>{};
  _Gen(this.docs);

  void buildStructIndex() {
    for (final domain in docs.keys) {
      final schemas = docs[domain]!['schemas'] as Map<String, dynamic>;
      final names = (schemas.keys.toList()..sort());
      for (final name in names) {
        final node = schemas[name] as Map<String, dynamic>;
        structIndex.putIfAbsent(normalize(node), () => classNameOf(name));
        final cls = structIndex[normalize(node)]!;
        structKinds.putIfAbsent(cls, () => kindOf(node));
      }
    }
  }

  String kindOf(Map<String, dynamic> node) {
    if (normalize(node) == '') return 'other';
    if (node.containsKey('oneOf') || node.containsKey('anyOf')) {
      return hasDiscriminator(node) ? 'union' : 'untagged';
    }
    final t = node['type'];
    if (t == 'object') return 'object';
    if (t == 'string' && node['enum'] != null) return 'enum';
    if (t == 'string') return 'string';
    if (t == 'integer') return 'integer';
    if (t == 'number') return 'number';
    return 'other';
  }

  String normalize(dynamic o) {
    if (o is Map) {
      final keys = o.keys.cast<String>().toList()..sort();
      final sorted = <String, dynamic>{};
      for (final k in keys) {
        if (k == r'$schema') continue;
        sorted[k] = o[k];
      }
      final child = <String>{};
      for (final k in keys) {
        if (k == r'$schema') continue;
        child.add(normalize(sorted[k]).toString());
      }
      final inner = keys.where((k) => k != '\$schema').map((k) => k + '=' + normalize(sorted[k])).join('&');
      return inner;
    }
    if (o is List) {
      return o.map((e) => normalize(e)).join(',');
    }
    return o.toString();
  }

  String classNameOf(String schemaName) {
    final base = schemaName.replaceAll(RegExp(r'Schema$'), '');
    return pascal(base.replaceAll('-', '_'));
  }

  String? namedFor(Map<String, dynamic> node) => structIndex[normalize(node)];

  void emitNamed(StringBuffer buf, String schemaName, Map<String, dynamic> node) {
    emitClass(buf, classNameOf(schemaName), node);
  }

  void emitClass(StringBuffer buf, String cls, Map<String, dynamic> node) {
    if (emitted.contains(cls)) return;
    emitted.add(cls);
    if (normalize(node) == '') {
      buf.writeln('/// Open passthrough (z.unknown) ' + cls + '.');
      buf.writeln('typedef ' + cls + ' = dynamic;');
      buf.writeln();
      return;
    }
    final type = node['type'];
    if (node.containsKey('oneOf') || node.containsKey('anyOf')) {
      emitUnion(buf, cls, node);
    } else if (type == 'object') {
      emitObject(buf, cls, node);
    } else if (type == 'string' && node['enum'] != null) {
      emitEnum(buf, cls, node);
    } else if (type == 'string') {
      buf.writeln('/// Branded string " + cls + ".');
      buf.writeln('typedef ' + cls + ' = String;');
      buf.writeln();
    } else if (type == 'integer') {
      buf.writeln('/// Branded int " + cls + ".');
      buf.writeln('typedef ' + cls + ' = int;');
      buf.writeln();
    } else if (type == 'number') {
      buf.writeln('/// Branded double " + cls + ".');
      buf.writeln('typedef ' + cls + ' = double;');
      buf.writeln();
    } else {
      buf.writeln('// ' + cls + ': skipped (type=' + (type ?? '?').toString() + ')');
      buf.writeln();
    }
  }

  void emitObject(StringBuffer buf, String cls, Map<String, dynamic> node) {
    final props = (node['properties'] as Map<String, dynamic>?) ?? {};
    final required = ((node['required'] as List?) ?? const []).cast<String>().toSet();
    final additionalRaw = node['additionalProperties'];
    final additional = additionalRaw is Map<String, dynamic> ? additionalRaw : null;
    if (additional != null && props.isEmpty) {
      buf.writeln('/// Record passthrough (loose object) ' + cls + '.');
      buf.writeln('final class ' + cls + ' {');
      buf.writeln('  const ' + cls + '(this.values);');
      buf.writeln('  final Map<String, dynamic> values;');
      buf.writeln('  factory ' + cls + '.fromJson(Map<String, dynamic> json) => ' + cls + '(Map<String, dynamic>.from(json));');
      buf.writeln('  Map<String, dynamic> toJson() => values;');
      buf.writeln('}');
      buf.writeln();
      return;
    }
    final fields = [for (final e in props.entries) _Field(e.key, e.value as Map<String, dynamic>, required.contains(e.key))];
    buf.writeln('/// Wire model ' + cls + '.');
    buf.writeln('final class ' + cls + ' {');
    if (fields.isEmpty) {
      buf.writeln('  const ' + cls + '();');
    } else {
      final ctor = fields.map((f) => f.required ? 'required this.' + f.dart : 'this.' + f.dart).join(', ');
      buf.writeln('  const ' + cls + '({' + ctor + '});');
    }
    for (final f in fields) {
      final ft = f.required ? dartType(f.schema) : nullableOf(dartType(f.schema));
      buf.writeln('  final ' + ft + ' ' + f.dart + ';');
    }
    buf.writeln('  factory ' + cls + '.fromJson(Map<String, dynamic> json) {');
    buf.writeln('    return ' + cls + '(');
    for (final f in fields) {
      final expr = fromJsonExpr(f.schema, "json['" + f.jsonName + "']");
      if (f.required) {
        buf.writeln('      ' + f.dart + ': ' + expr + ',');
      } else {
        buf.writeln('      ' + f.dart + ": json.containsKey('" + f.jsonName + "') ? " + expr + ' : null,');
      }
    }
    buf.writeln('    );');
    buf.writeln('  }');
    buf.writeln('  Map<String, dynamic> toJson() => {');
    for (final f in fields) {
      if (f.required) {
        buf.writeln("      '" + f.jsonName + "': " + toJsonExpr(f.schema, f.dart) + ',');
      } else {
        buf.writeln('      if (' + f.dart + " != null) '" + f.jsonName + "': " + toJsonExpr(f.schema, f.dart + '!') + ',');
      }
    }
    buf.writeln('  };');
    buf.writeln('}');
    buf.writeln();
  }

  Map<String, dynamic> mergeBranches(Map<String, dynamic> a, Map<String, dynamic> b) {
    final pa = (a['properties'] as Map<String, dynamic>?) ?? {};
    final pb = (b['properties'] as Map<String, dynamic>?) ?? {};
    final ra = ((a['required'] as List?) ?? const []).cast<String>().toSet();
    final rb = ((b['required'] as List?) ?? const []).cast<String>().toSet();
    final merged = <String, dynamic>{};
    for (final k in pa.keys.toSet().union(pb.keys.toSet())) {
      if (pa[k] == null) { merged[k] = pb[k]; continue; }
      if (pb[k] == null) { merged[k] = pa[k]; continue; }
      final sa = jsonEncode(pa[k]);
      final sb = jsonEncode(pb[k]);
      if (sa == sb) { merged[k] = pa[k]; continue; }
      // differing subschemas (e.g. secondary const) -> widen to open passthrough
      merged[k] = <String, dynamic>{};
    }
    final req = ra.intersection(rb).toList()..sort();
    return {'type': 'object', 'properties': merged, 'required': req, 'additionalProperties': false};
  }

  bool hasDiscriminator(Map<String, dynamic> node) {
    final branches = ((node['oneOf'] as List?) ?? (node['anyOf'] as List?) ?? const []).cast<Map<String, dynamic>>();
    for (final b in branches) {
      final props = (b['properties'] as Map<String, dynamic>?);
      if (props == null) continue;
      for (final e in props.entries) {
        final s = e.value as Map<String, dynamic>;
        if (s['const'] is String) return true;
      }
    }
    return false;
  }

  void emitUnion(StringBuffer buf, String cls, Map<String, dynamic> node) {
    final branches = ((node['oneOf'] as List?) ?? (node['anyOf'] as List?) ?? const []).cast<Map<String, dynamic>>();
    String? disc;
    var found = false;
    for (final b in branches) {
      if (found) break;
      final props = (b['properties'] as Map<String, dynamic>?);
      if (props == null) continue;
      for (final e in props.entries) {
        final s = e.value as Map<String, dynamic>;
        if (s['const'] is String) { disc = e.key; found = true; break; }
      }
    }
    if (!found) {
      buf.writeln('/// Untagged union ' + cls + ' (kept open as dynamic).');
      buf.writeln('typedef ' + cls + ' = dynamic;');
      buf.writeln();
      return;
    }
    final discriminator = disc as String;
    buf.writeln('/// Sealed union ' + cls + ', discriminated by "' + discriminator + '".');
    buf.writeln('sealed class ' + cls + ' {');
    buf.writeln('  const ' + cls + '();');
    buf.writeln('  Map<String, dynamic> toJson();');
    buf.writeln('  factory ' + cls + '.fromJson(Map<String, dynamic> json) {');
    buf.writeln("    final tag = json['" + discriminator + "'] as String;");
    buf.writeln('    switch (tag) {');
    final variants = <String, Map<String, dynamic>>{};
    for (final b in branches) {
      final props = (b['properties'] as Map<String, dynamic>?) ?? {};
      String? tag;
      for (final e in props.entries) {
        final s = e.value as Map<String, dynamic>;
        if (s['const'] is String) { tag = s['const'] as String; break; }
      }
      if (tag == null) continue;
      final existing = variants[tag];
      variants[tag] = existing == null ? b : mergeBranches(existing, b);
    }
    for (final tag in variants.keys) {
      buf.writeln("      case '" + tag + "':");
      buf.writeln('        return ' + variantName(cls, tag) + '.fromJson(json);');
    }
    buf.writeln('      default:');
    buf.writeln("        throw FormatException('" + cls + ': unknown ' + discriminator + " ' + tag);");
    buf.writeln('    }');
    buf.writeln('  }');
    buf.writeln('}');
    buf.writeln();
    for (final tag in variants.keys) {
      emitVariant(buf, cls, variants[tag]!, discriminator, tag);
    }
  }


  String variantName(String cls, String tag) {
    final t = tag.split('/').where((p) => p.isNotEmpty).map((p) => p.split('-').where((q) => q.isNotEmpty).map((q) => q[0].toUpperCase() + q.substring(1)).join()).join();
    return cls + t;
  }

  void emitVariant(StringBuffer buf, String sealedCls, Map<String, dynamic> branch, String disc, String tag) {
    final props = (branch['properties'] as Map<String, dynamic>?) ?? {};
    final required = ((branch['required'] as List?) ?? const []).cast<String>().toSet();
    final fields = [for (final e in props.entries) if (e.key != disc) _Field(e.key, e.value as Map<String, dynamic>, required.contains(e.key))];
    final vname = variantName(sealedCls, tag);
    buf.writeln('/// "' + tag + '" variant of ' + sealedCls + '.');
    buf.writeln('final class ' + vname + ' extends ' + sealedCls + ' {');
    if (fields.isEmpty) {
      buf.writeln('  const ' + vname + '();');
    } else {
      final ctor = fields.map((f) => f.required ? 'required this.' + f.dart : 'this.' + f.dart).join(', ');
      buf.writeln('  const ' + vname + '({' + ctor + '});');
    }
    for (final f in fields) {
      final ft = f.required ? dartType(f.schema) : nullableOf(dartType(f.schema));
      buf.writeln('  final ' + ft + ' ' + f.dart + ';');
    }
    buf.writeln('  factory ' + vname + '.fromJson(Map<String, dynamic> json) {');
    buf.writeln('    return ' + vname + '(');
    for (final f in fields) {
      final expr = fromJsonExpr(f.schema, "json['" + f.jsonName + "']");
      if (f.required) {
        buf.writeln('      ' + f.dart + ': ' + expr + ',');
      } else {
        buf.writeln('      ' + f.dart + ": json.containsKey('" + f.jsonName + "') ? " + expr + ' : null,');
      }
    }
    buf.writeln('    );');
    buf.writeln('  }');
    buf.writeln('  @override');
    buf.writeln('  Map<String, dynamic> toJson() => {');
    buf.writeln("    '" + disc + "': '" + tag + "',");
    for (final f in fields) {
      if (f.required) {
        buf.writeln("      '" + f.jsonName + "': " + toJsonExpr(f.schema, f.dart) + ',');
      } else {
        buf.writeln('      if (' + f.dart + " != null) '" + f.jsonName + "': " + toJsonExpr(f.schema, f.dart + '!') + ',');
      }
    }
    buf.writeln('  };');
    buf.writeln('}');
    buf.writeln();
  }

  void emitEnum(StringBuffer buf, String cls, Map<String, dynamic> node) {
    final values = (node['enum'] as List).cast<String>();
    buf.writeln('/// Enum ' + cls + '.');
    buf.writeln('enum ' + cls + ' {');
    final used = <String>{};
    for (final v in values) {
      var n = enumValue(v);
      while (used.contains(n)) { n = n + '_'; }
      used.add(n);
      buf.writeln('  ' + n + "('" + v + "'),");
    }
    buf.writeln('  ;');
    buf.writeln('  final String wire;');
    buf.writeln('  const ' + cls + '(this.wire);');
    buf.writeln("  static " + cls + " fromValue(String v) => values.firstWhere((e) => e.wire == v, orElse: () => throw FormatException('" + cls + " unknown: ' + v));");
    buf.writeln('  String toJson() => wire;');
    buf.writeln('}');
    buf.writeln();
  }

  String enumValue(String v) {
    final cleaned = v.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ').trim();
    if (cleaned.isEmpty) return 'v' + v.codeUnits.fold(0, (a, b) => (a + b) % 9973).toString();
    if (RegExp(r'^[0-9]').hasMatch(cleaned)) return 'v' + cleaned.split(' ').map((p) => p[0].toUpperCase() + p.substring(1)).join();
    return cleaned.split(' ').map((p) => p[0].toUpperCase() + p.substring(1)).join();
  }
}

String nullableOf(String t) => t.endsWith('?') ? t : t + '?';

String? nullableAnyOf(Map<String, dynamic> node) {
  final anyOf = node['anyOf'];
  if (anyOf is List && anyOf.length == 2) {
    final a = anyOf[0] as Map<String, dynamic>;
    final b = anyOf[1] as Map<String, dynamic>;
    if (b['type'] == 'null') return dartType(a);
    if (a['type'] == 'null') return dartType(b);
  }
  return null;
}

String dartType(Map<String, dynamic> node) {
  final named = namedClassFor(node);
  if (named != null) return named;
  final nullAny = nullableAnyOf(node);
  if (nullAny != null) return nullableOf(nullAny);
  final type = node['type'];
  switch (type) {
    case 'string': return 'String';
    case 'integer': return 'int';
    case 'number': return 'double';
    case 'boolean': return 'bool';
    case 'array':
      final items = (node['items'] as Map<String, dynamic>?) ?? {};
      return items.isEmpty ? 'List<dynamic>' : 'List<' + dartType(items) + '>';
    case 'object':
      return 'Map<String, dynamic>';
  }
  if (node['const'] is String) return 'String';
  if (node.containsKey('oneOf') || node.containsKey('anyOf')) return 'Object';
  return 'dynamic';
}

String? namedClassFor(Map<String, dynamic> node) => globalGen?.namedFor(node);

String? namedKindFor(Map<String, dynamic> node) {
  final cls = globalGen?.namedFor(node);
  if (cls == null) return null;
  return globalGen!.structKinds[cls];
}

String unwrapNamed(String cls, String expr) => cls + '.__parse(' + expr + ')';

Map<String, dynamic> stripNullAnyOf(Map<String, dynamic> node) {
  final anyOf = node['anyOf'] as List;
  final a = anyOf[0] as Map<String, dynamic>;
  final b = anyOf[1] as Map<String, dynamic>;
  return b['type'] == 'null' ? a : b;
}

String fromJsonExpr(Map<String, dynamic> node, String expr) {
  final kind = namedKindFor(node);
  if (kind != null) {
    if (kind == 'string') return '(' + expr + ' as String)';
    if (kind == 'integer') return '(' + expr + ' as num).toInt()';
    if (kind == 'number') return '(' + expr + ' as num).toDouble()';
    if (kind == 'enum') {
      final cls = namedClassFor(node)!;
      return cls + '.fromValue(' + expr + ' as String)';
    }
    if (kind == 'other' || kind == 'untagged') return expr;
    final cls = namedClassFor(node)!;
    return cls + '.fromJson(' + expr + ' as Map<String, dynamic>)';
  }
  final nullAny = nullableAnyOf(node);
  if (nullAny != null) {
    final innerExpr = fromJsonExpr(stripNullAnyOf(node), expr);
    return '(' + expr + ' == null ? null : ' + innerExpr + ')';
  }
  final type = node['type'];
  switch (type) {
    case 'string': return '(' + expr + ' as String)';
    case 'integer': return '(' + expr + ' as num).toInt()';
    case 'number': return '(' + expr + ' as num).toDouble()';
    case 'boolean': return '(' + expr + ' as bool)';
    case 'array':
      final items = (node['items'] as Map<String, dynamic>?) ?? {};
      if (items.isEmpty) return '(' + expr + ' as List).toList()';
      return '[for (final e in (' + expr + ' as List)) ' + fromJsonExpr(items, 'e') + ']';
    case 'object':
      return '(' + expr + ' as Map<String, dynamic>)';
  }
  if (node['enum'] is List) {
    return dartType(node) + '.fromValue(' + expr + ' as String)';
  }
  return expr;
}

String toJsonExpr(Map<String, dynamic> node, String expr) {
  final kind = namedKindFor(node);
  if (kind != null) {
    if (kind == 'enum') return expr + '.wire';
    if (kind == 'string' || kind == 'integer' || kind == 'number') return expr;
    if (kind == 'other' || kind == 'untagged') return expr;
    return expr + '.toJson()';
  }
  final nullAny = nullableAnyOf(node);
  if (nullAny != null) return toJsonExpr(stripNullAnyOf(node), expr);
  final type = node['type'];
  if (type == 'array') {
    final items = (node['items'] as Map<String, dynamic>?) ?? {};
    if (items.isEmpty) return expr;
    return '[for (final e in ' + expr + ') ' + toJsonExpr(items, 'e') + ']';
  }
  if (node['enum'] is List) return expr + '.wire';
  return expr;
}
