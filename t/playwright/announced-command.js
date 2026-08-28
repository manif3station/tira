// A required action that has announced its command, in a real browser.
//
// The owner asked for a state between picking an item up and finishing it
// (TSK-194): "Agent can provide the command for a specific item first, so the
// user can see it is working on it". The engine half is t/418; this is the half
// he actually sees, and the reason he asked - a list of pending items tells him
// nothing about which one is being worked right now.
//
// Four states have to stay distinguishable, and the ordering matters: exempt
// wins over everything, done over announced, announced over untouched. A fixture
// with only an announced item would not catch an icon expression that had lost
// a branch, so all four are here and the three that are not new are the guard.

const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath, dataPath] = process.argv.slice(2);
if (!htmlPath || !dataPath) {
  console.error('usage: announced-command.js <fixture.html> <board.json>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('  ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

// REQ-002 is the new state: a command recorded, no proof yet. REQ-004 is the
// one that proves the distinction is real - same shape of proof array, but with
// the proof present, so it must read as done rather than as announced.
const ITEMS = [
  { id: 'REQ-001', item: 'untouched', status: 'pending', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
  { id: 'REQ-002', item: 'announced', status: 'pending', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100',
    proof: [ { command: 'prove -lr t' } ] },
  { id: 'REQ-003', item: 'exempt and announced', status: 'pending', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100',
    proof: [ { command: 'prove -lr t' } ] },
  { id: 'REQ-004', item: 'finished', status: 'done', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100',
    proof: [ { command: 'prove -lr t', proof: 'All tests successful.' } ] },
];

const RECORD = {
  ref: 'TKT-001', type: 'ticket', column: 'in-progress', title: 'Announced card',
  description: 'x', problem_or_feature: 'x', solution_needed: 'x', source: 'x',
  priority: 3, assignee: 'ada', reporter: 'ada', labels: [], start_date: null,
  due_date: null, sdlc_gate: null, lifecycle: null, fix_version: null,
  affects_versions: [], parent: null, key_details: [], deliverables: [],
  scope: { included: [], excluded: [] }, acceptance_criteria: [], test_steps: [],
  bdd: [], atdd: [], checklist: [], gate_passing_log: [], evidence: [], attachments: [],
  subtasks: [], linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
  comments: [],
  required_items: ITEMS,
  required_exempt: [{ item: 'exempt and announced', reason: 'covered elsewhere' }],
  created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
};

const TICK = '\u2705';
const BOX = '\u2b1c';
const EXEMPT = '\u2796';
const CLOCK = '\u23f1';

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(board) });
    if (url.pathname === '/record') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(RECORD) });
    if (url.pathname === '/people' || url.pathname === '/link-types') return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.click('[data-ref="TKT-001"] .card');
  await page.waitForSelector('.card-dialog[open]');

  const section = page.locator('.card-dialog .card-required');
  if (await section.count() === 0) {
    fail('the card dialog shows no required-action section');
    await browser.close();
    return;
  }

  const iconFor = async id => {
    const row = section.locator(`[data-required-action="${id}"]`);
    if (await row.count() === 0) return null;
    return (await row.first().innerText()).trim().charAt(0);
  };

  const expected = [
    ['REQ-001', BOX,    'untouched',            'an empty box'],
    ['REQ-002', CLOCK,  'announced',            'a clock'],
    ['REQ-003', EXEMPT, 'exempt and announced', 'the exempt mark, because exempt wins over announced'],
    ['REQ-004', TICK,   'finished',             'a tick, because done wins over announced'],
  ];

  for (const [id, want, what, described] of expected) {
    const got = await iconFor(id);
    if (got === null) fail(`${id} (${what}) did not render at all`);
    else if (got !== want) fail(`${id} (${what}) should render ${described}, and renders ${JSON.stringify(got)}`);
    else pass(`${id}, ${what}, renders ${described}`);
  }

  // Four DISTINCT icons, not merely four correct ones. A renderer that
  // collapsed two states onto one glyph would satisfy every assertion above if
  // the glyph happened to be right for both.
  const icons = [];
  for (const [id] of expected) icons.push(await iconFor(id));
  const distinct = new Set(icons.filter(Boolean));
  if (distinct.size !== 4) fail(`the four states share ${4 - distinct.size + 1} glyphs between them: ${JSON.stringify(icons)}`);
  else pass('the four states are four distinct marks, so none is indistinguishable from another');

  // The announced item is still OUTSTANDING - it has started, not finished. If
  // it stopped offering its checkbox the clock would have become a second way
  // of saying done.
  const check = section.locator('[data-required-action="REQ-002"] input[type="checkbox"]');
  if (await check.count() === 0) fail('an announced item is no longer offered its checkbox - the clock has been mistaken for done');
  else pass('an announced item is still offered its checkbox, because it has started and not finished');

  // The proof row is the one reader nothing had checked. It renders each pair
  // as command + detail, and the detail falls through to
  //   pair.proof || (pair.attachment ? "(attachment)" : dash)
  // so an announced entry - no proof, no attachment - lands on the dash by an
  // existing fallback rather than by design. That is graceful, and it is worth
  // an assertion precisely because nothing chose it: a later change to that
  // expression would otherwise put "undefined" in front of a person with no
  // test objecting.
  const announcedText = section.locator('[data-required-action="REQ-002"]');
  await announcedText.locator('.card-list__text').click();
  const proofRow = section.locator('[data-required-action-proof="REQ-002"]');
  if (await proofRow.count() === 0) {
    fail('an announced item offers no proof row, so its command cannot be seen');
  } else {
    const shown = await proofRow.first().innerText();
    if (!shown.includes('prove -lr t')) fail(`the announced command is not shown in its proof row: ${JSON.stringify(shown)}`);
    else pass('an announced item shows the command it recorded');
    if (/undefined|null/.test(shown)) fail(`the proof row renders a placeholder for the missing proof: ${JSON.stringify(shown)}`);
    else pass('and renders no undefined or null where the proof is not there yet');
  }

  await browser.close();

  if (process.exitCode) console.error('announced command: FAILED');
  else console.log('announced command: all checks passed');
})();
