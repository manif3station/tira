// TKT-551. Michael, live: "when the user working on a task card. Do not
// refresh that card. It will wipe out what the user typed and attached."
//
// maybeRefreshDialog() already guards against this - it skips the refresh
// entirely when dialogEditingActive() is true - but the guard's own coverage
// is exactly what is in question here. Driven in a real browser because a
// guard's true behaviour is what the DOM shows after a refresh actually
// runs, not what the source code claims it checks.
//
// The refresh path is scheduled with a recursive setTimeout, captured here
// (not merely recorded, unlike dashboard-browser.js's own override) so a
// "poll fires" moment can be triggered deterministically, at the exact
// instant the test wants it, rather than by waiting on a real interval.

const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const [htmlPath, dataPath] = process.argv.slice(2);
  if (!htmlPath || !dataPath) throw new Error('HTML and JSON paths are required');
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const record = {
    ref: 'TKT-001', type: 'ticket', column: 'in-progress', title: 'Live browser card',
    description: 'Full popup detail', problem_or_feature: 'x', solution_needed: 'x',
    source: 'x', priority: 3, assignee: 'ada', reporter: 'ada', labels: [],
    start_date: null, due_date: null, sdlc_gate: null, lifecycle: null, fix_version: null,
    affects_versions: [], parent: null, key_details: [], deliverables: [],
    scope: { included: [], excluded: [] }, acceptance_criteria: [], test_steps: [],
    bdd: [], atdd: [], checklist: [], gate_passing_log: [], evidence: [], attachments: [],
    subtasks: [], linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
    comments: [], created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
  };

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  // Capture the recursive setTimeout's callback so the test can fire a "poll
  // just landed" moment on demand, deterministically, instead of waiting on
  // a real interval.
  await page.addInitScript(() => {
    window.__tiraPendingRefresh = null;
    const realSetTimeout = window.setTimeout.bind(window);
    window.setTimeout = (callback, delay, ...rest) => {
      if (delay >= 500) { window.__tiraPendingRefresh = callback; return 1; }
      return realSetTimeout(callback, delay, ...rest);
    };
  });

  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/data') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(board) });
    }
    if (url.pathname === '/record') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(record) });
    }
    if (url.pathname === '/people' || url.pathname === '/link-types') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.click('[data-ref="TKT-001"] .card');
  await page.waitForSelector('.card-dialog[open]');
  await page.locator('.card-dialog .card-composer-toggle').click();
  await page.waitForSelector('.card-dialog .card-comment-form:visible');

  const fireRefresh = async () => {
    const fired = await page.evaluate(async () => {
      if (!window.__tiraPendingRefresh) return false;
      await window.__tiraPendingRefresh();
      return true;
    });
    if (!fired) throw new Error('no refresh was scheduled to fire');
  };

  // --- typing a comment survives a poll that lands mid-type -------------------
  await page.locator('.card-dialog .card-comment-form textarea[name="text"]').fill('Half-written thought');
  await fireRefresh();
  const survived = await page.locator('.card-dialog .card-comment-form textarea[name="text"]').inputValue();
  if (survived !== 'Half-written thought') {
    throw new Error(`typed comment text was wiped by a refresh mid-type, got ${JSON.stringify(survived)}`);
  }
  console.log('card dialog refresh: an in-progress comment survives a poll landing mid-type');

  // --- typing into a list field's persistent "add item" box -------------------
  // Unlike an existing item's own edit (wrapped in a .card-edit span, already
  // covered), the box that adds a NEW item sits in .card-list__adder, which
  // dialogEditingActive() does not name - only a still-held focus protects it.
  await page.locator('.card-dialog [data-list-add="key_details"]').fill('Half-written key detail');
  await fireRefresh();
  const listSurvived = await page.locator('.card-dialog [data-list-add="key_details"]').inputValue();
  if (listSurvived !== 'Half-written key detail') {
    throw new Error(`the "add item" box text was wiped by a refresh mid-type, got ${JSON.stringify(listSurvived)}`);
  }
  console.log('card dialog refresh: an in-progress "add item" list box survives a poll landing mid-type');

  // --- selecting a file for the record-level attach input ---------------------
  // setInputFiles fires the input's change handler (which starts the upload
  // immediately) without moving document.activeElement onto the file input the
  // way a real click-through-to-native-picker + selection normally would - the
  // one guard clause that does not require a specific wrapper class.
  const uploadStarted = page.waitForRequest(request =>
    request.url().includes('/attachment/add') && request.method() === 'POST');
  await page.setInputFiles('.card-dialog .card-attach-input[data-attach-target="record"]',
    { name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('draft notes') });
  const activeInsideDialog = await page.evaluate(() =>
    document.activeElement && document.querySelector('.card-dialog').contains(document.activeElement)
      ? document.activeElement.tagName : null);
  await fireRefresh();
  const requestSeen = await Promise.race([
    uploadStarted.then(() => true),
    new Promise(resolve => setTimeout(() => resolve(false), 200)),
  ]);
  console.log(`card dialog refresh: after file selection, activeElement in dialog = ${activeInsideDialog}, upload request seen = ${requestSeen}`);
  if (!requestSeen) {
    throw new Error('the attachment upload never reached the server - selecting a file during/around a refresh lost it');
  }

  await browser.close();
})().catch(error => {
  console.error(error.message);
  process.exit(1);
});
