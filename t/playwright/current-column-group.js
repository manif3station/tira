// A card with required actions spread across five columns, opened in a real
// browser, and asked which group is the one in front of you.
//
// The dialog renders one group per column. On a card with a history that is a
// column of headings, exactly one of which is the work that is actually owed,
// and until 4.75 nothing marked it. The section's own count is card-wide -
// "Required actions (18/75)" - so it answers how much of the card's whole life
// is finished rather than what is owed here.
//
// tira.required-action.list --blocking answered this for the CLI in TKT-598.
// This is the browser getting the same answer.
//
// WHY THIS FILE EXISTS BESIDE t/432, which asserts the same feature from Perl:
// the source test can prove the provider agrees with _unmet_in_column. It
// cannot prove the page marks the right group, and the card's first acceptance
// criterion asks for exactly that - the group is VISIBLY distinguished.
//
// THE FOUR UNMARKED GROUPS ARE THE CONTROL. A change that marked every group,
// or that marked whichever came first, satisfies every assertion about the
// current one. They are the reason this file checks what is NOT marked as
// carefully as what is.

const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath, dataPath] = process.argv.slice(2);
if (!htmlPath || !dataPath) {
  console.error('usage: current-column-group.js <fixture.html> <board.json>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('  ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

// Five columns, and the card sits in the third. Two of implement's three items
// are outstanding and one is exempt, so the count the page shows can only be
// right if it applies the same three rules _unmet_in_column applies: this
// column, minus exemptions, minus anything done.
//
// The columns either side carry outstanding items too. If the page marked by
// position, or marked everything with unfinished work, those would catch it.
const ITEMS = [
  { id: 'REQ-001', item: 'backlog item, done', status: 'done', column: 'backlog', last_updated: null },
  { id: 'REQ-002', item: 'tests-red item, outstanding', status: 'pending', column: 'tests-red', last_updated: null },
  { id: 'REQ-003', item: 'implement item, outstanding', status: 'pending', column: 'implement', last_updated: null },
  { id: 'REQ-004', item: 'implement item, also outstanding', status: 'todo', column: 'implement', last_updated: null },
  { id: 'REQ-005', item: 'implement item, done', status: 'Done', column: 'implement', last_updated: null },
  { id: 'REQ-006', item: 'implement item, exempt', status: 'pending', column: 'implement', last_updated: null },
  { id: 'REQ-007', item: 'verify item, outstanding', status: 'pending', column: 'verify', last_updated: null },
  { id: 'REQ-008', item: 'done item, outstanding', status: 'pending', column: 'done', last_updated: null },
];

// What Perl decided, carried in the record the dialog already has. The page
// must render THIS rather than counting the entries itself - a filter written
// again in JavaScript would be a second opinion about what "done" means, which
// is the drift TKT-657 fixed when four readers of one status disagreed about
// case. REQ-005 is stored as 'Done' precisely so a JS recount would get it
// wrong and be caught here.
const UNMET_IN_COLUMN = { column: 'implement', count: 2, items: ['REQ-003', 'REQ-004'] };

const RECORD = {
  ref: 'TKT-001', type: 'ticket', column: 'implement', title: 'A card with a history',
  description: 'x', problem_or_feature: 'x', solution_needed: 'x', source: 'x',
  priority: 3, assignee: 'ada', reporter: 'ada', labels: [], start_date: null,
  due_date: null, sdlc_gate: null, lifecycle: null, fix_version: null,
  affects_versions: [], parent: null, key_details: [], deliverables: [],
  scope: { included: [], excluded: [] }, acceptance_criteria: [], test_steps: [],
  bdd: [], atdd: [], checklist: [], gate_passing_log: [], evidence: [], attachments: [],
  subtasks: [], linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
  comments: [],
  required_items: ITEMS,
  required_exempt: [{ item: 'implement item, exempt', reason: 'covered elsewhere' }],
  unmet_in_column: UNMET_IN_COLUMN,
  created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
};

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium',
    '/usr/bin/chromium-browser'].find(path => path && fs.existsSync(path));
  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = fs.readFileSync(dataPath, 'utf8');

  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/') return route.fulfill({ status: 200, contentType: 'text/html', body: html });
    if (url.pathname === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: board });
    if (url.pathname === '/record') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(RECORD) });
    }

    // These two answer with ARRAYS, and the first version of this file replied
    // {} to everything it did not recognise. The dialog then had an object
    // where it iterates, threw before it rendered a single group, and the wait
    // for .card-required__group timed out thirty seconds later saying nothing
    // about why. mixed-case-done.js and required-actions.js both get this
    // right; this file was written from neither closely enough.
    if (url.pathname === '/people' || url.pathname === '/link-types') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.click('[data-ref="TKT-001"] .card');
  await page.waitForSelector('.card-dialog[open]');
  await page.waitForSelector('.card-required__group');

  const groups = await page.$$('.card-required__group');
  if (groups.length !== 5) {
    fail(`expected five column groups, one per column with items - saw ${groups.length}`);
  } else {
    pass('the dialog still renders one group per column - five of them');
  }

  const marked = await page.$$('.card-required__group--current');
  if (marked.length !== 1) {
    fail(`exactly one group is the card's own column - ${marked.length} are marked`);
  } else {
    pass('exactly one group is marked, not none and not all of them');
  }

  if (marked.length === 1) {
    const heading = (await marked[0].innerText()).trim();

    if (!heading.toLowerCase().startsWith('implement')) {
      fail(`the marked group is the card's column - marked "${heading.split('\n')[0]}" while the card is in implement`);
    } else {
      pass('and it is implement, the column the card is actually in');
    }

    // The number, and where it came from. Two of implement's four items are
    // outstanding: REQ-005 is done (stored 'Done', which a JavaScript recount
    // would miscount) and REQ-006 is exempt.
    if (!/\b2\b/.test(heading)) {
      fail(`the marked heading states what is owed here - read "${heading.split('\n')[0]}", expected it to carry 2`);
    } else {
      pass('and states that 2 are owed in it - excluding the done one and the exempt one');
    }

    // A card-wide count would say 6. If the page shows that beside the column
    // it has answered the wrong question, which is the fault this card exists
    // for rather than a cosmetic slip.
    if (/\b6\b/.test(heading)) {
      fail(`the marked heading shows the CARD-WIDE outstanding count (6) rather than this column's - "${heading.split('\n')[0]}"`);
    } else {
      pass('and not the card-wide outstanding total, which is the question it is not asking');
    }
  }

  // The control. Four groups carry outstanding work and none of them is the
  // card's column; a change that marked by position, or marked anything with
  // unfinished items, passes every assertion above and fails here.
  const others = await page.$$eval('.card-required__group:not(.card-required__group--current) .card-required__column',
    nodes => nodes.map(node => node.textContent.trim()));
  const wrongly = others.filter(text => /owed here/i.test(text));
  if (wrongly.length) {
    fail(`only the current column says what is owed - these also do: ${wrongly.join(', ')}`);
  } else {
    pass(`the other four groups say nothing about what is owed - ${others.length} unmarked`);
  }

  await browser.close();
})();
