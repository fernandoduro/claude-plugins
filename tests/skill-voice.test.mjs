import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Every plugin here installs into someone else's machine, so a skill that names the
// maintainer or calls its reader "he" instructs the agent about a person who is not
// there. no-meat-proxy shipped to a public directory with "hand JT so he can say it"
// in its description and four more JT references in its body; the same text is also
// what Codex and Claude route on. The generic reader is "the user" / "you", and
// they/them where a pronoun is unavoidable.
//
// KNOWN_PERSONALIZED is a ratchet, not an exemption: each entry is either a quoted
// example where the name is the point, or pre-existing debt with a beads issue. New
// files may not join it — fix the text instead.

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

const KNOWN_PERSONALIZED = new Map([
	// The name appears inside an illustration of what a *caller* says, which is the
	// third-person phrasing the paragraph exists to explain.
	['plugins/hotline/skills/ringing/SKILL.md', 'quoted example of caller phrasing'],
	// Sample `gws calendar` output; the names are real event titles in the transcript.
	['plugins/gws/skills/calendar/SKILL.md', 'sample command output'],
	// Debt: written for one operator before these shipped publicly. claude-plugins-dw67.
	['plugins/beads-workflow/skills/triage-beads/SKILL.md', 'debt: claude-plugins-dw67'],
	['plugins/agentmail/skills/contacts/SKILL.md', 'debt: claude-plugins-dw67'],
	['plugins/agentmail/skills/relay-work-order/SKILL.md', 'debt: claude-plugins-dw67'],
]);

// Names stay case-sensitive so `/Users/jt` in a path example reads clean; pronouns match
// either case, because the defect that started this was a sentence-initial "He".
const NAMED = /\b(JT|Justin)\b/;
const GENDERED = /\b(he|him|his|she|her|hers)\b/i;
const personal = (line) => NAMED.test(line) || GENDERED.test(line);

// The GitHub handle carries the maintainer's name through repo URLs and author credits,
// which say who wrote the plugin rather than who is reading it.
const CREDIT = /jtsternberg/i;

const docs = readdirSync(join(repoRoot, 'plugins'), { recursive: true })
	.map((entry) => join('plugins', entry))
	.filter((entry) => /(?:^|\/)(?:SKILL|README)\.md$/.test(entry));

test('plugin skills and READMEs address whoever runs them, not a named person', () => {
	assert.ok(docs.length > 50, `expected the whole plugin tree, globbed ${docs.length} docs`);

	const offenders = docs.filter((doc) => {
		if (KNOWN_PERSONALIZED.has(doc)) return false;
		const text = readFileSync(join(repoRoot, doc), 'utf8');
		return text.split('\n').some((line) => personal(line) && !CREDIT.test(line));
	});

	assert.deepEqual(
		offenders,
		[],
		'these docs name the maintainer or use he/she for the reader; say "the user" / "you", or they/them',
	);
});

test('every ratchet entry still exists and still needs its exemption', () => {
	for (const [doc, reason] of KNOWN_PERSONALIZED) {
		const path = join(repoRoot, doc);
		let text;
		try {
			text = readFileSync(path, 'utf8');
		} catch {
			assert.fail(`${doc} is listed as personalized but no longer exists — drop the entry`);
		}
		const hit = text.split('\n').some((line) => personal(line) && !CREDIT.test(line));
		assert.ok(hit, `${doc} (${reason}) reads clean now — drop it from KNOWN_PERSONALIZED`);
	}
});

test('the ledger carries the rule these tests enforce', () => {
	const ledger = readFileSync(join(repoRoot, 'docs/compounding.md'), 'utf8');
	assert.match(ledger, /A published skill addresses whoever runs it/);
	assert.match(ledger, /tests\/skill-voice\.test\.mjs/);
});
