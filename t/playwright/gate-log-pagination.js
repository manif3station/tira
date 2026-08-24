// The Gate Passing Log paginates in a real browser.
//
// He asked for this after watching a card accumulate gate log entries over a
// long-running ticket: "If the Gate Passing Log length more then 10 start
// pagination... if there are 1000 logs. That will kill the browser
// performance. So do not load all gate log at once." TKT-495.
//
// Driven here rather than asserted against the markup, because the section
// decides for itself how many entries to render up front and reveals more
// only on demand - a static page cannot show that a click changes anything.

const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const [htmlPath, dataPath] = process.argv.slice(2);
  if (!htmlPath || !dataPath) throw new Error('HTML and JSON paths are required');
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');

  const html = fs.readFileSync(htmlPath, 'utf8');
  const data = fs.readFileSync(dataPath, 'utf8');

  const board = JSON.parse(data);
  const refs = Object.values(board.ticket || {}).flat().map(card => card.ref).filter(Boolean);
  if (refs.length < 2) throw new Error(`the fixture board needs two cards, it has ${refs.length}`);
  const [logged, empty] = refs;

  // Fourteen entries: past the first page of ten, with four left over so
  // "Load more" has something honest to say and something left to hide once
  // clicked.
  const gateLog = Array.from({ length: 14 }, (_, index) => ({
    id: `GATE-${String(index + 1).padStart(3, '0')}`,
    gate: 'required-action',
    result: 'pass',
    author: null,
    created_at: `2026-08-24T09:${String(index).padStart(2, '0')}:00+0100`,
    details: `Marked step ${index + 1} done`,
    annotations: [],
  }));

  const recordFor = (ref, log) => JSON.stringify({
    ref, type: 'ticket', title: 'A card', column: 'implement',
    description: '', comments: [], attachments: [], checklist: [], questions: [],
    evidence: [], gate_passing_log: log, subtasks: [], labels: [],
    scope: { included: [], excluded: [] }, linkage: { links: [], sub_ticket_refs: [] },
  });

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/record') {
      const ref = url.searchParams.get('ref');
      const body = ref === logged ? recordFor(ref, gateLog) : recordFor(ref, []);
      return route.fulfill({ status: 200, contentType: 'application/json', body });
    }
    if (url.pathname === '/data') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: data });
    }
    if (['/people', '/worklog', '/link-types', '/policelog'].includes(url.pathname)) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  // --- the card with fourteen entries ---------------------------------------

  await page.click(`[data-ref="${logged}"]`);
  await page.waitForSelector('.card-dialog[open]');
  const section = page.locator('[data-section="gate passing log"]');
  await section.waitFor({ state: 'attached', timeout: 15000 });

  let rows = await section.locator('.card-list li').count();
  if (rows !== 10) throw new Error(`expected ten entries on the first page, got ${rows}`);

  const more = section.locator('.card-list__more');
  if (await more.count() !== 1) throw new Error('no "Load more" control is offered past ten entries');
  if (await more.isHidden()) throw new Error('"Load more" is hidden when four entries are still unshown');

  const beforeClick = (await more.textContent()).trim();
  if (!beforeClick.includes('4')) throw new Error(`the button does not say four remain: "${beforeClick}"`);

  await more.click();

  rows = await section.locator('.card-list li').count();
  if (rows !== 14) throw new Error(`expected all fourteen entries after loading more, got ${rows}`);

  if (await more.isVisible()) throw new Error('"Load more" is still visible once every entry is shown');

  const text = await section.textContent();
  if (!text.includes('GATE-001') || !text.includes('GATE-014')) {
    throw new Error('the loaded entries do not cover the full log, first to last');
  }

  console.log('gate log pagination: ten shown up front, "Load more (4 more)" reveals the rest, then hides');

  // --- the card with nothing in its log --------------------------------------

  await page.keyboard.press('Escape');
  await page.click(`[data-ref="${empty}"]`);
  await page.waitForSelector('.card-dialog[open]');
  await page.waitForTimeout(500);

  const emptySections = await page.locator('[data-section="gate passing log"]').count();
  if (emptySections !== 0) throw new Error('a card with no gate log renders the section anyway');

  console.log('gate log pagination: all checks passed, and a card with nothing logged shows no section');
  await browser.close();
})().catch(error => {
  console.error(error.message || error);
  process.exit(1);
});
