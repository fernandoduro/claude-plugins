import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const pluginRoot = path.resolve(import.meta.dirname, '..');
const skillRoot = path.join(pluginRoot, 'skills', 'pr-merge-review');
const skill = fs.readFileSync(path.join(skillRoot, 'SKILL.md'), 'utf8');
const openai = fs.readFileSync(path.join(skillRoot, 'agents', 'openai.yaml'), 'utf8');
const readme = fs.readFileSync(path.join(pluginRoot, 'README.md'), 'utf8');

test('ships the pr-merge-review lens with merge-routing terms', () => {
	assert.match(skill, /^---\nname: pr-merge-review\ndescription: .+\n---\n/);
	// Codex ignores when_to_use, so the routing vocabulary must live in description.
	assert.match(skill, /description: [^\n]*\bmerge\b/);
	assert.match(skill, /description: [^\n]*pull request/);
});

test('delegates to the sibling base skill instead of duplicating it', () => {
	// Shared reference lives once at the base skill; this wrapper resolves it via the plugin root.
	assert.match(skill, /\$\{CLAUDE_PLUGIN_ROOT\}\/skills\/walk-through-work-history\/SKILL\.md/);
	assert.match(skill, /\$\{CLAUDE_PLUGIN_ROOT\}\/skills\/walk-through-work-history\/references\/github-pr\.md/);
	assert.match(skill, /Codex: resolve `skills\/walk-through-work-history\/SKILL\.md`/);
	// No shell-default wrapper — Claude resolves the bare token mechanically.
	assert.doesNotMatch(skill, /\$\{CLAUDE_PLUGIN_ROOT:-/);
	// The wrapper must not re-embed github-pr.md's collection commands.
	assert.doesNotMatch(skill, /gh api --paginate/);
});

test('stays a thin wrapper: operate as the base skill, fold risk into the story', () => {
	// The failure this guards against is reworking the base skill's method instead of
	// wrapping it — the wrapper must run as if walk-through-work-history were called
	// directly, keep the causal chapters, and only add a lens.
	assert.match(skill, /as if that skill had been invoked directly/i);
	assert.match(skill, /does not replace the method/i);
	assert.match(skill, /causal chapters/i);
	assert.match(skill, /[Dd]o not invent new chapter types/);
	// Risk is woven into the story, not a bolted-on section, and the final page looks forward.
	assert.match(skill, /weave the risk thread/i);
	assert.match(skill, /next steps/i);
});

test('ships Codex metadata with plugin-qualified invocation', () => {
	assert.match(openai, /default_prompt: "Use \$walk-through-work-history:pr-merge-review /);
	assert.match(openai, /allow_implicit_invocation: true/);
	assert.match(readme, /\/walk-through-work-history:pr-merge-review/);
	assert.match(readme, /\$walk-through-work-history:pr-merge-review/);
});
