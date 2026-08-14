// The card dialog shows what police has said, in a real browser.
//
// He raised it because he reads the board instead of asking for progress, and
// the dialog is what he opens. The enforcement log exists so that what police
// said about a card survives the bridge scrolling past - and the one place a
// person opens to see everything about a card did not show it.
//
// Driven here rather than asserted against the markup, because the section is
// fetched per card and decides for itself whether to appear. Rendering the
// element is not the feature; filling it for the card that has something, and
// staying hidden for the card that does not, is.

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

  // The card the board actually has, taken from the payload rather than
  // guessed - a fixture that names a card the board does not hold proves that
  // the dialog copes with a missing card, which is a different test.
  const board = JSON.parse(data);
  const refs = Object.values(board.ticket || {}).flat().map(card => card.ref).filter(Boolean);
  if (refs.length < 2) throw new Error(`the fixture board needs two cards, it has ${refs.length}`);
  const [chased, untouched] = refs;

  const chasedLog = [
    { at: '2026-08-13T09:00:00+0100', kind: 'violation', ref: chased,
      detail: 'VIO-0001 missing: description,problem_or_feature' },
    { at: '2026-08-13T09:30:00+0100', kind: 'suspension', ref: chased,
      detail: '60s: chasing one failing test to the bottom' },
  ];

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  let asked = [];
  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/policelog') {
      const ref = url.searchParams.get('ref');
      asked.push(ref);
      const body = ref === chased ? chasedLog : [];
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    }
    if (url.pathname === '/data') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: data });
    }
    if (url.pathname === '/record') {
      const ref = url.searchParams.get('ref');
      return route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ ref, type: 'ticket', title: 'A card', column: 'implement',
          description: '', comments: [], attachments: [], checklist: [], questions: [],
          evidence: [], gate_passing_log: [], subtasks: [], labels: [],
          scope: { included: [], excluded: [] }, linkage: { links: [], sub_ticket_refs: [] } }) });
    }
    if (url.pathname === '/people') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    if (url.pathname === '/worklog') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    if (url.pathname === '/link-types') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  // --- the card police chased ---------------------------------------------------

  await page.click(`[data-ref="${chased}"]`);
  await page.waitForSelector('.card-dialog[open]');
  const section = page.locator('.card-section--policelog');
  await page.waitForFunction(
    () => {
      const box = document.querySelector('.card-section--policelog');
      return box && !box.hidden;
    },
    null,
    { timeout: 15000 },
  );

  const heading = (await section.locator('.card-section__title').textContent()).trim();
  if (!/police/i.test(heading)) throw new Error(`the section is not titled for police: ${heading}`);
  if (!heading.includes('2')) throw new Error(`the heading does not say how many: ${heading}`);

  const rows = await section.locator('.card-policelog__entry').count();
  if (rows !== 2) throw new Error(`expected two entries, got ${rows}`);

  const said = await section.textContent();
  if (!said.includes('VIO-0001')) throw new Error('the entry does not carry what police said');
  if (!/violation/i.test(said)) throw new Error('the entry does not say what kind it was');
  if (!/suspension/i.test(said)) throw new Error('a suspension is not shown, and it is in the same log');

  // --- and it can be read on a phone ------------------------------------------
  //
  // He sent a photograph of this section on his own phone: "was answe / red and
  // never marke / d", one or two letters a line. The entry is a grid of 11rem,
  // 7rem and whatever is left, so on a screen about 22rem wide the detail got
  // about three - and the card sets overflow-wrap to anywhere, which breaks
  // words mid-character rather than at spaces.
  //
  // Measured rather than eyeballed: the width of the detail column, and whether
  // the section fits inside the card. The test that already existed passes on a
  // column of single letters, because it asks whether the content is there.
  {
    const phone = await browser.newPage({ viewport: { width: 390, height: 844 } });
    await phone.route('http://tira.test/**', async route => {
      const url = new URL(route.request().url());
      if (url.pathname === '/policelog') {
        return route.fulfill({ status: 200, contentType: 'application/json',
          body: JSON.stringify(chasedLog) });
      }
      if (url.pathname === '/data') {
        return route.fulfill({ status: 200, contentType: 'application/json', body: data });
      }
      if (url.pathname === '/record') {
        return route.fulfill({ status: 200, contentType: 'application/json',
          body: JSON.stringify({ ref: chased, type: 'ticket', title: 'A card',
            column: 'implement', description: '', comments: [], attachments: [],
            checklist: [], questions: [], evidence: [], gate_passing_log: [],
            subtasks: [], labels: [], scope: { included: [], excluded: [] },
            linkage: { links: [], sub_ticket_refs: [] } }) });
      }
      if (['/people', '/worklog', '/link-types'].includes(url.pathname)) {
        return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
      }
      return route.fulfill({ status: 200, contentType: 'text/html', body: html });
    });

    await phone.goto('http://tira.test/');
    await phone.waitForFunction(() => document.documentElement.dataset.ready === 'true');
    await phone.click(`[data-ref="${chased}"]`);
    await phone.waitForSelector('.card-dialog[open]');
    await phone.waitForFunction(() => {
      const box = document.querySelector('.card-section--policelog');
      return box && !box.hidden;
    }, null, { timeout: 15000 });

    const measured = await phone.evaluate(() => {
      const detail = document.querySelector('.card-policelog__detail');
      const section = document.querySelector('.card-section--policelog');
      return {
        detail: detail ? detail.getBoundingClientRect().width : 0,
        section: section ? section.getBoundingClientRect().width : 0,
      };
    });
    if (measured.detail < 150) {
      throw new Error(`the police log detail is ${Math.round(measured.detail)}px wide on a phone - `
        + 'that is the column of single letters he photographed');
    }
    if (measured.detail > measured.section + 1) {
      throw new Error('the detail is wider than the section that holds it');
    }
    await phone.close();
  }

  // Nothing to change it with. Police writes this and nobody else may, which is
  // why there is no command to add an entry - a button here would be the way
  // round that.
  const writable = await section.locator('button, input, textarea, select').count();
  if (writable !== 0) throw new Error(`the section offers ${writable} things to change it with`);

  console.log(`police log: "${heading}", ${rows} entries, nothing to edit`);

  // --- and the card it never mentioned -------------------------------------------

  await page.keyboard.press('Escape');
  await page.click(`[data-ref="${untouched}"]`);
  await page.waitForSelector('.card-dialog[open]');
  await page.waitForFunction(
    ref => window.__askedFor === undefined || true,
    untouched,
    { timeout: 5000 },
  ).catch(() => null);

  // Give the fetch a moment, then require silence rather than an empty heading.
  await page.waitForTimeout(500);
  const boxes = await page.locator('.card-section--policelog:not([hidden])').count();
  if (boxes !== 0) throw new Error('a card police never mentioned is showing an empty section');

  if (!asked.includes(untouched)) throw new Error('the dialog did not even ask about the second card');

  console.log(`police log: all checks passed, and a card with nothing recorded shows nothing`);
  await browser.close();
})().catch(error => {
  console.error(error.message || error);
  process.exit(1);
});
