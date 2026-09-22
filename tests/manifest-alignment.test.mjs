// Version-alignment guard for plugins that ship BOTH harness manifests.
//
// Plugin versions are release identifiers AND Codex cache keys. Codex reads a
// plugin's manifest by fallback — `.codex-plugin/plugin.json` when the plugin
// ships one, otherwise `.claude-plugin/plugin.json` — so for a plugin carrying
// both, the Codex-facing version is the one that governs Codex's cache
// transition. docs/release.md §1: "For a plugin that ships both manifests
// (hotline, pr-workflow), keep the two versions aligned."
//
// The failure this pins: hotline 0.34.2 shipped with `.claude-plugin` at 0.34.2
// and `.codex-plugin` still at 0.34.1, so Claude Code installers saw the new
// release while Codex kept the old cache key and its stale content. Nothing
// caught it — tests/codex-catalog-drift.test.mjs asserts four properties of the
// generated catalog, and neither catalog pins a plugin version at all. It was
// found by hand, one release late (commit 4761e9d).
//
// Plugins are DISCOVERED, never listed: a hardcoded roster silently omits the
// next plugin to gain a second manifest, which is the same shape as the
// hardcoded-suite-list bug that let 14 tests ship unrun. A plugin carrying only
// one manifest is out of scope, not a failure — most plugins are served to
// Codex from their Claude manifest by fallback, and release.md says not to add
// a second manifest merely to mirror metadata.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PLUGINS_DIR = join(REPO_ROOT, 'plugins');

const CLAUDE_MANIFEST = join('.claude-plugin', 'plugin.json');
const CODEX_MANIFEST = join('.codex-plugin', 'plugin.json');

const isDir = (p) => existsSync(p) && statSync(p).isDirectory();

// Walk plugins/ at both depths — a plugin root, or a plugin inside a plugin
// group (plugins/<group>/<child>), matching the two depths tests/run-all.sh
// globs. A directory is a plugin root when it holds either manifest.
function pluginRoots() {
  const roots = [];
  for (const entry of readdirSync(PLUGINS_DIR)) {
    const top = join(PLUGINS_DIR, entry);
    if (!isDir(top)) continue;
    const holdsManifest = (d) =>
      existsSync(join(d, CLAUDE_MANIFEST)) || existsSync(join(d, CODEX_MANIFEST));
    if (holdsManifest(top)) roots.push(top);
    // A plugin group has no manifest of its own; its children are the plugins.
    for (const child of readdirSync(top)) {
      const nested = join(top, child);
      if (isDir(nested) && holdsManifest(nested)) roots.push(nested);
    }
  }
  return roots;
}

function readVersion(file) {
  const raw = readFileSync(file, 'utf8');
  const parsed = JSON.parse(raw);
  return parsed.version;
}

const dualManifest = pluginRoots()
  .filter(
    (root) =>
      existsSync(join(root, CLAUDE_MANIFEST)) && existsSync(join(root, CODEX_MANIFEST)),
  )
  .sort();

// The positive control. A glob or a walk that matches nothing reports "all
// clean" indistinguishably from a real pass, so prove the discovery can see
// the plugins before reading any green as a result (docs/compounding.md:
// "a sweep that reports zero matches is only clean once it is proved able to
// match"). If a refactor legitimately leaves no dual-manifest plugin, this is
// the assertion to delete — deliberately, not by watching it pass empty.
test('discovery finds the plugins that ship both manifests', () => {
  assert.ok(
    dualManifest.length > 0,
    'found no plugin carrying both .claude-plugin/plugin.json and .codex-plugin/plugin.json — ' +
      'the walk is broken, or every dual-manifest plugin was removed. Do not read a ' +
      'green alignment check as meaningful until this passes.',
  );
});

test('both manifests of a dual-manifest plugin carry the same version', () => {
  const drifted = [];
  for (const root of dualManifest) {
    const claudeVersion = readVersion(join(root, CLAUDE_MANIFEST));
    const codexVersion = readVersion(join(root, CODEX_MANIFEST));
    if (claudeVersion !== codexVersion) {
      drifted.push(
        `${relative(REPO_ROOT, root)}: .claude-plugin=${claudeVersion} .codex-plugin=${codexVersion}`,
      );
    }
  }
  assert.deepEqual(
    drifted,
    [],
    'a plugin shipping both manifests has drifted versions. Codex reads ' +
      '.codex-plugin/plugin.json by preference, so the stale side is the one that ' +
      'governs its cache key — bump both together (docs/release.md §1):\n  ' +
      drifted.join('\n  '),
  );
});

// Every manifest present must actually declare a version, or the comparison
// above passes vacuously on two `undefined`s.
test('every manifest of a dual-manifest plugin declares a version', () => {
  const missing = [];
  for (const root of dualManifest) {
    for (const manifest of [CLAUDE_MANIFEST, CODEX_MANIFEST]) {
      const version = readVersion(join(root, manifest));
      if (typeof version !== 'string' || version.length === 0) {
        missing.push(`${relative(REPO_ROOT, root)}/${manifest}`);
      }
    }
  }
  assert.deepEqual(
    missing,
    [],
    `manifest(s) with no usable version string:\n  ${missing.join('\n  ')}`,
  );
});
