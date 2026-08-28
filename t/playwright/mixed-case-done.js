// A card whose required actions are stored with mixed capitalisation, opened
// in a real browser, and asked what it shows.
//
// The engine has compared a required action's status against "done"
// case-insensitively since TKT-434, deliberately: "--status Done" must not be
// "refused forever with a message that names the very word the person already
// used". The dashboard had never got the same fix and compared against the
// literal "done" in three places - the done/total count, the tick-or-empty-box
// icon, and whether an actionable checkbox is drawn. Since 4.63 all three go
// through one predicate, isDone, and this file is what holds them there.
//
// Reported by the owner and still being seen on 2026-08-28: "the required
// action items are not showing on the dashboard with green tick while the item
// at the record is marked as done ... I still seeing this issue".
//
// Measured on a copy of a real board, in a container: 534 items stored as
// 'Done' against 2068 as 'done', mis-rendering across 21 cards. ZSD-286 and
// ZSD-287 each render 97 of 97 required actions as empty boxes while being
// provably complete.
//
// Why this file exists beside t/417, which reads the same three comparisons
// out of lib/Tira.pm: the source test can prove the comparison is gone. It
// cannot prove the page is right, and the card's sixth acceptance criterion
// asks for exactly that - "Proved in a real browser against a card carrying a
// mix of 'done' and 'Done' items".
//
// THE CHECKBOX IS THE ONE THAT MATTERS. The count and the icon mislead; the
// checkbox invites. It offers a live control to complete work that is already
// complete, and taking it up re-runs required_item_update on a done item,
// which since 4.48 can meet the duplicate-proof refusal. So the last assertion
// here is not about appearance - it is that the page cannot walk somebody into
// a refusal with a control that should never have been drawn.

const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath, dataPath] = process.argv.slice(2);
if (!htmlPath || !dataPath) {
  console.error('usage: mixed-case-done.js <fixture.html> <board.json>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('  ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

// Six items in four states, chosen so every branch of the renderer is exercised
// by something and so a fix that lowercases blindly is caught as well as one
// that does not lowercase at all:
//
//   done      lowercase, finished          -> tick, counted, no checkbox
//   Done      capitalised, finished        -> tick, counted, no checkbox   <- the bug
//   DONE      shouted, finished            -> tick, counted, no checkbox   <- the bug
//   pending   genuinely outstanding        -> box, not counted, checkbox
//   todo      genuinely outstanding        -> box, not counted, checkbox
//   Done      finished AND exempt          -> the exempt mark, never a checkbox
//
// The two genuinely-outstanding items are the control. A "fix" that made
// everything render as done would satisfy every assertion about the first
// three and is caught by these two - which is the overcorrection the card's
// fourth acceptance criterion is written against.
const ITEMS = [
  { id: 'REQ-001', item: 'stored lowercase', status: 'done', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
  { id: 'REQ-002', item: 'stored capitalised', status: 'Done', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
  { id: 'REQ-003', item: 'stored shouted', status: 'DONE', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
  { id: 'REQ-004', item: 'genuinely pending', status: 'pending', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
  { id: 'REQ-005', item: 'genuinely todo', status: 'todo', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
  { id: 'REQ-006', item: 'exempt and capitalised', status: 'Done', column: 'in-progress', last_updated: '2026-08-01T09:00:00+0100' },
];

const RECORD = {
  ref: 'TKT-001', type: 'ticket', column: 'in-progress', title: 'Mixed-case card',
  description: 'x', problem_or_feature: 'x', solution_needed: 'x', source: 'x',
  priority: 3, assignee: 'ada', reporter: 'ada', labels: [], start_date: null,
  due_date: null, sdlc_gate: null, lifecycle: null, fix_version: null,
  affects_versions: [], parent: null, key_details: [], deliverables: [],
  scope: { included: [], excluded: [] }, acceptance_criteria: [], test_steps: [],
  bdd: [], atdd: [], checklist: [], gate_passing_log: [], evidence: [], attachments: [],
  subtasks: [], linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
  comments: [],
  required_items: ITEMS,
  required_exempt: [{ item: 'exempt and capitalised', reason: 'covered by REQ-002' }],
  created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
};

const TICK = '✅';
const BOX = '⬜';
const EXEMPT = '➖';

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  // Served rather than loaded from file://, for the reason card-editors.js
  // records: the dialog is populated from /record, and a file:// page cannot
  // answer it - the first version of that test opened nothing and timed out,
  // which is a malformed red rather than a meaningful one.
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
    fail('the card dialog shows no required-action section for a card that has six');
    await browser.close();
    return;
  }

  // --- the count ------------------------------------------------------------
  //
  // Four of the six are done - three by spelling, and the fourth is the exempt
  // one, which is also stored 'Done'. The count is computed before exemptions
  // are applied, so all four count.
  //
  // Read from the SECTION rather than from the box: the renderer builds it as
  // section("Required actions ("+done+"/"+total+")", box), so the count is in
  // the section's heading and the box's own first line is the column group's
  // name. The first version of this test read the box and got "IN-PROGRESS",
  // which is a malformed assertion rather than a meaningful one - the same
  // mistake card-editors.js records making, and the same fix: read the
  // renderer instead of guessing the selector.
  const wrapper = page.locator('.card-dialog .card-section--required');
  if (await wrapper.count() === 0) {
    fail('the required-action section has no .card-section--required wrapper to read a count from');
  } else {
    const heading = await wrapper.first().innerText();
    // Case-insensitive, and the reason is not decoration. innerText returns
    // RENDERED text, and the section heading is uppercased by CSS - so this
    // read "REQUIRED ACTIONS (4/6)" and a case-sensitive match found nothing.
    // A test for a case-sensitivity bug, failing because of a case-sensitivity
    // bug of its own, against a page that was by then correct.
    const numbers = heading.match(/Required actions\s*\((\d+)\s*\/\s*(\d+)\)/i);
    if (!numbers) {
      fail(`the required-action heading carries no done/total count: ${JSON.stringify(heading.split('\n')[0])}`);
    } else if (numbers[1] !== '4') {
      fail(`the count says ${numbers[1]} of ${numbers[2]} done, but four of the six items are done - 'Done' and 'DONE' are being read as outstanding`);
    } else {
      pass(`the count reads ${numbers[1]} of ${numbers[2]}, counting every spelling of done`);
    }
  }

  // --- the icon -------------------------------------------------------------
  //
  // Per row, by required-action id, so a failure names the item rather than a
  // total. dataset.requiredAction is set on the row by the renderer.
  const iconFor = async id => {
    const row = section.locator(`[data-required-action="${id}"]`);
    if (await row.count() === 0) return null;
    return (await row.first().innerText()).trim().charAt(0);
  };

  for (const [id, spelling] of [['REQ-001', 'done'], ['REQ-002', 'Done'], ['REQ-003', 'DONE']]) {
    const icon = await iconFor(id);
    if (icon === null) fail(`${id} did not render at all`);
    else if (icon !== TICK) fail(`${id} is stored '${spelling}' and renders ${icon === BOX ? 'an empty box' : JSON.stringify(icon)} instead of a tick`);
    else pass(`${id}, stored '${spelling}', renders a tick`);
  }

  // The control, and the assertion that stops an overcorrection: a genuinely
  // outstanding item must still look outstanding. A fix that lowercased the
  // wrong side, or that treated any non-empty status as done, passes
  // everything above and fails here.
  for (const [id, spelling] of [['REQ-004', 'pending'], ['REQ-005', 'todo']]) {
    const icon = await iconFor(id);
    if (icon !== BOX) fail(`${id} is stored '${spelling}' and must still render an empty box, not ${JSON.stringify(icon)}`);
    else pass(`${id}, stored '${spelling}', still renders an empty box`);
  }

  // Exempt is decided before done-ness and renders its own mark. Three states,
  // not two - a fix that collapsed the icon to a boolean would lose this.
  const exemptIcon = await iconFor('REQ-006');
  if (exemptIcon !== EXEMPT) fail(`REQ-006 is exempt and must render the exempt mark, not ${JSON.stringify(exemptIcon)}`);
  else pass('an exempt item still renders its own mark rather than a tick or a box');

  // --- the checkbox, which is the harmful one -------------------------------
  //
  // Not appearance. A checkbox on a finished item offers to redo finished work,
  // and taking it up can meet the duplicate-proof refusal - so the page would
  // be leading somebody into a refusal with a control that should never have
  // been drawn.
  const hasCheck = async id => {
    const row = section.locator(`[data-required-action="${id}"]`);
    if (await row.count() === 0) return null;
    return (await row.first().locator('input[type="checkbox"]').count()) > 0;
  };

  for (const [id, spelling] of [['REQ-001', 'done'], ['REQ-002', 'Done'], ['REQ-003', 'DONE']]) {
    const offered = await hasCheck(id);
    if (offered !== false) fail(`${id} is stored '${spelling}' and is finished, yet the page offers a checkbox to finish it again`);
    else pass(`${id}, stored '${spelling}', is offered no checkbox`);
  }

  for (const [id, spelling] of [['REQ-004', 'pending'], ['REQ-005', 'todo']]) {
    const offered = await hasCheck(id);
    if (offered !== true) fail(`${id} is stored '${spelling}' and genuinely outstanding, so it must still be offered its checkbox`);
    else pass(`${id}, stored '${spelling}', is still offered its checkbox`);
  }

  const exemptOffered = await hasCheck('REQ-006');
  if (exemptOffered !== false) fail('an exempt item must never be offered a checkbox');
  else pass('an exempt item is offered no checkbox');

  await browser.close();

  if (process.exitCode) console.error('mixed-case done: FAILED');
  else console.log('mixed-case done: all checks passed');
})();
