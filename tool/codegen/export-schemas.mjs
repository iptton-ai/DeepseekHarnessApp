#!/usr/bin/env node
/**
 * export-schemas.mjs — DSH zod schema -> JSON Schema exporter (M0 codegen stage 1).
 *
 * Source of truth: the installed dsh-host-apiproxy runtime zod schemas
 * (`lib/types/api/*.schema.js`). This script imports them, converts each
 * exported zod schema to JSON Schema (draft 2020-12, output posture), and
 * writes one JSON file per domain module into tool/codegen/schemas/.
 *
 * Also writes manifest.json: dsh + zod versions, the frozen RpcMethodMap
 * method list (from rpc-map.d.ts knowledge), and per-module export names.
 * CI pins dsh version by comparing manifest against the installed CLI.
 *
 * Run: node tool/codegen/export-schemas.mjs [--dsh-root <path>]
 */
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';

const arg = process.argv.indexOf('--dsh-root');
const DSH_ROOT = arg > 0 ? process.argv[arg + 1]
  : '/Users/you/.local/lib/node_modules/@deepseek-ai/dsh';
const NM = path.join(DSH_ROOT, 'node_modules');
const API_DIR = path.join(NM, '@deepseek-ai/dsh-host-apiproxy/lib/types/api');

const require = createRequire(import.meta.url);
const zodPkg = require(path.join(NM, 'zod/package.json'));
const dshPkg = require(path.join(DSH_ROOT, 'package.json'));
const { z } = await import(path.join(NM, 'zod/index.js'));

// Frozen method registry (from rpc-map.d.ts, dsh 0.1.0-rc.6). Each entry must
// have both <method>RequestSchema and <method>ValueSchema exports somewhere.
const METHODS = [
  'session.list','session.search','session.create','session.history','session.models',
  'session.selectModel','session.rename','session.fork','session.prompt','session.attachment',
  'session.updateQueue','session.cancel',
  'subagent.list','subagent.history','subagent.prompt','subagent.interrupt',
  'host.describe','host.pickDirectory','host.listDirectory','host.createDirectory','host.openPath',
  'workspace.list','workspace.create','workspace.rename','workspace.delete','workspace.insertBefore',
  'workspace.insertSessionBefore','workspace.archiveSession',
  'skill.list',
  'agentPreset.list','agentPreset.select','agentPreset.read','agentPreset.copy','agentPreset.openDocument','agentPreset.remove',
  'goal.create','goal.edit','goal.pause','goal.resume','goal.complete','goal.clear',
  'settings.describe','settings.openDocument','settings.update','settings.replace','settings.mutate',
  'credentials.describe','credentials.set','credentials.unset',
  'llm.providers','llm.models','llm.discoverModels',
];
const camel = (m) => m.split('.').map((s, i) => i === 0 ? s : s[0].toUpperCase() + s.slice(1)).join('');

const modules = readdirSync(API_DIR).filter(f => f.endsWith('.schema.js'));
const outDir = new URL('.', import.meta.url).pathname.replace(/^\/$/, '') || process.cwd();
const schemasDir = path.join(process.cwd(), 'tool/codegen/schemas');
mkdirSync(schemasDir, { recursive: true });

const manifest = {
  generatedAt: new Date().toISOString(),
  dshVersion: dshPkg.version,
  zodVersion: zodPkg.version,
  methodCount: METHODS.length,
  methods: METHODS,
  modules: {},
};

const isZod = (v) => v instanceof z.ZodType || (v && typeof v === 'object' && typeof v.safeParse === 'function' && typeof v.parse === 'function');

let total = 0, failures = [];
for (const mod of modules) {
  const domain = mod.replace('.schema.js', '');
  const exports = await import(path.join(API_DIR, mod));
  const doc = { module: mod, dshVersion: dshPkg.version, schemas: {} };
  for (const [name, value] of Object.entries(exports)) {
    if (!isZod(value)) continue;
    try {
      doc.schemas[name] = z.toJSONSchema(value, {
        io: 'output',
        unrepresentable: 'any',
        cycles: 'ref',
        reused: 'inline',
      });
      total++;
    } catch (e) {
      failures.push(`${domain}/${name}: ${e.message}`);
      doc.schemas[name] = { __exportError: e.message };
    }
  }
  manifest.modules[domain] = Object.keys(doc.schemas);
  writeFileSync(path.join(schemasDir, domain + '.json'), JSON.stringify(doc, null, 2) + '\n');
}

// Method coverage check: every frozen method needs Request+Value schemas.
const allNames = new Set(Object.values(manifest.modules).flat());
const missing = [];
for (const m of METHODS) {
  for (const suffix of ['RequestSchema', 'ValueSchema']) {
    const n = camel(m) + suffix;
    if (!allNames.has(n)) missing.push(n);
  }
}
manifest.methodSchemaCoverage = { ok: missing.length === 0, missing };

writeFileSync(path.join(schemasDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`exported ${total} schemas from ${modules.length} modules -> ${schemasDir}`);
if (failures.length) { console.error('conversion failures:'); failures.forEach(f => console.error('  ' + f)); }
console.log(`method coverage: ${manifest.methodSchemaCoverage.ok ? 'OK (' + METHODS.length + ' methods)' : 'MISSING ' + missing.join(', ')}`);
process.exit(failures.length || missing.length ? 1 : 0);
