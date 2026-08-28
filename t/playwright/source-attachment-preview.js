// A program attached to a card, opened in a real browser, and asked what it shows.
//
// TKT-645. The viewer previewed nine text extensions and refused everything
// else - "Preview is not supported for this file in this browser" - so a
// script attached to a card could not be read from the board at all. The owner
// hit it on tasklist-check.sh, the reference implementation he had asked to be
// attached to TKT-639.
//
// t/423 proves what the ENGINE serves and that the viewer keeps no extension
// list of its own. It cannot prove the page renders, which is what this file is
// for - the same division t/417 and mixed-case-done.js already have.
//
// Two things are asserted here that a source test cannot reach: that a .pl
// attachment shows its text rather than the refusal, with highlighting spans
// actually in the DOM; and that a binary still refuses, which is the card's
// fourth acceptance criterion and the one thing "show everything as text"
// would break.

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const htmlPath = process.argv[2];
const dataPath = process.argv[3];

let failures = 0;
const pass = m => console.log('  ok - ' + m);
const fail = m => { failures++; console.log('  FAIL - ' + m); };

const PERL_SOURCE = [
  '#!/usr/bin/env perl',
  'use strict;',
  'my $count = 42;',
  'print "hello\\n";',
].join('\n');

const BINARY = Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x00, 0x00, 0x01, 0x02, 0x00, 0x03]);

const ATTACHMENTS = [
  { sha: 'aaa1', extension: 'pl', original_filename: 'check.pl',
    content_type: 'text/plain; charset=UTF-8', added_at: '2026-08-01T09:00:00+0100', size: PERL_SOURCE.length },
  { sha: 'bbb2', extension: 'bin', original_filename: 'blob.bin',
    content_type: 'application/octet-stream', added_at: '2026-08-01T09:00:00+0100', size: BINARY.length },
];

const RECORD = {
  ref: 'TKT-001', type: 'ticket', column: 'in-progress', title: 'Card with a script on it',
  description: 'x', problem_or_feature: 'x', solution_needed: 'x', source: 'x',
  priority: 3, assignee: 'ada', reporter: 'ada', labels: [], start_date: null,
  due_date: null, sdlc_gate: null, lifecycle: null, fix_version: null,
  affects_versions: [], parent: null, key_details: [], deliverables: [],
  scope: { included: [], excluded: [] }, acceptance_criteria: [], test_steps: [],
  bdd: [], atdd: [], checklist: [], gate_passing_log: [], evidence: [],
  attachments: ATTACHMENTS,
  subtasks: [], linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
  comments: [], required_items: [], required_exempt: [],
  created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
};

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  // Every request the page makes is answered here, so anything it tried to
  // fetch from off-origin would surface as an unhandled route rather than
  // silently working - which is the self-contained property this card must not
  // cost, asserted again at the end.
  const offOrigin = [];
  await page.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.host !== 'tira.test') { offOrigin.push(url.href); return route.abort(); }
    if (url.pathname === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(board) });
    if (url.pathname === '/record') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(RECORD) });
    if (url.pathname === '/people' || url.pathname === '/link-types') return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    if (url.pathname === '/attachment') {
      const sha = url.searchParams.get('sha') || '';
      if (sha.startsWith('bbb2')) return route.fulfill({ status: 200, contentType: 'application/octet-stream', body: BINARY });
      return route.fulfill({ status: 200, contentType: 'text/plain; charset=UTF-8', body: PERL_SOURCE });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.click('[data-ref="TKT-001"] .card');
  await page.waitForSelector('.card-dialog[open]');

  const views = page.locator('.card-dialog .card-attachment__view');
  if (await views.count() < 2) {
    fail('the card dialog did not render both attachments');
    await browser.close();
    process.exit(1);
  }
  pass('both attachments render on the card');

  // --- the script ----------------------------------------------------------
  await views.nth(0).click();
  await page.waitForSelector('.card-viewer', { state: 'visible' });
  await page.waitForFunction(() => {
    const pane = document.querySelector('.card-viewer__text');
    return pane && !pane.hidden && pane.textContent && pane.textContent !== 'Loading…';
  }, { timeout: 5000 }).catch(() => {});

  const shown = await page.evaluate(() => {
    const pane = document.querySelector('.card-viewer__text');
    const fallback = document.querySelector('.card-viewer__fallback');
    return {
      paneHidden: !pane || pane.hidden,
      text: pane ? pane.textContent : '',
      fallbackHidden: !fallback || fallback.hidden,
      tokens: pane ? Array.from(pane.querySelectorAll('span[class*="tok--"]')).map(s => s.className.replace('tok tok--', '')) : [],
    };
  });

  if (shown.paneHidden) fail('a .pl attachment does not open in the text pane at all');
  else pass('a .pl attachment opens in the text pane');

  if (!shown.text.includes('my $count = 42')) fail('the text pane does not contain the script - it shows ' + JSON.stringify(shown.text.slice(0, 60)));
  else pass('and shows the script itself, not a refusal');

  if (!shown.fallbackHidden) fail('the "preview is not supported" fallback is showing for a readable script');
  else pass('and the unsupported-file message is not shown');

  for (const want of ['keyword', 'string', 'number', 'comment']) {
    if (!shown.tokens.includes(want)) fail(`the script is not highlighted: no ${want} token in the DOM (got ${JSON.stringify(shown.tokens)})`);
    else pass(`highlighted: a ${want} token is in the DOM`);
  }

  // --- and the binary, which must still refuse -----------------------------
  //
  // The control, and the card's fourth acceptance criterion. A change that
  // showed everything as text would pass every assertion above and fail here.
  await page.click('.card-viewer__close').catch(() => {});
  await views.nth(1).click();
  await page.waitForSelector('.card-viewer', { state: 'visible' });
  await page.waitForTimeout(400);

  const binary = await page.evaluate(() => {
    const pane = document.querySelector('.card-viewer__text');
    const fallback = document.querySelector('.card-viewer__fallback');
    return { paneHidden: !pane || pane.hidden, fallbackHidden: !fallback || fallback.hidden };
  });

  if (binary.fallbackHidden) fail('a binary attachment does not show the unsupported-file message');
  else pass('a binary attachment still refuses, rather than rendering as mojibake');
  if (!binary.paneHidden) fail('a binary attachment was rendered into the text pane');
  else pass('and is not put through the text pane');

  if (offOrigin.length) fail('the page requested something off-origin: ' + offOrigin.join(', '));
  else pass('and the page requested nothing off-origin while doing it');

  await browser.close();
  console.log(failures ? `source attachment preview: ${failures} check(s) failed` : 'source attachment preview: all checks passed');
  process.exit(failures ? 1 : 0);
})();
