// Required-action items get their own labeled section in the card dialog, in
// a real browser - not folded into the general checklist. TKT-440, split out
// of TKT-438 (owner, TG voice msg 4188): "在html dashboard有一個setion，是
// specifically給這些required item show出來，當user click那些card的時候，他就可以
// 看到這些item做了多少，有什麼還沒做" (the html dashboard has a section
// specifically for required items - opening a card shows how many are done).
//
// Driven here rather than asserted against the markup, for the same reason
// police-log.js gives: the section decides for itself whether to appear, and
// rendering the element is not the feature - filling it for a card that has
// required_items, and staying absent for one that does not, is.

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
  const [withRequired, withoutRequired] = refs;

  const requiredItems = [
    { id: 'REQ-001', column: 'planning', item: 'left a note', status: 'pending', last_updated: '2026-08-21T09:00:00Z' },
    { id: 'REQ-002', column: 'planning', item: 'reviewed by someone else', status: 'done', last_updated: '2026-08-21T09:05:00Z',
      proof: [ { command: 'ran the review checklist', proof: 'all items checked, no findings' } ] },
    { id: 'REQ-003', column: 'doc', item: 'said why', status: 'pending', last_updated: '2026-08-21T09:10:00Z' },
  ];

  const recordFor = (ref, items) => ({
    ref, type: 'ticket', title: 'A card', column: 'planning',
    description: '', comments: [], attachments: [], checklist: [], questions: [],
    evidence: [], gate_passing_log: [], subtasks: [], labels: [], required_items: items,
    scope: { included: [], excluded: [] }, linkage: { links: [], sub_ticket_refs: [] },
  });

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  let requestedRef;
  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/record') {
      const ref = url.searchParams.get('ref');
      requestedRef = ref;
      const record = ref === withRequired ? recordFor(ref, requiredItems) : recordFor(ref, []);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(record) });
    }
    if (url.pathname === '/data') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: data });
    }
    if (['/people', '/worklog', '/policelog', '/link-types'].includes(url.pathname)) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  // --- a card carrying required_items shows the labeled section, grouped ----
  await page.click(`[data-ref="${withRequired}"]`);
  await page.waitForSelector('.card-dialog[open]');
  if (requestedRef !== withRequired) throw new Error('the dialog did not fetch the card it opened');

  const section = page.locator('.card-section--required');
  await section.waitFor({ state: 'attached', timeout: 15000 });

  const heading = (await section.locator('.card-section__title').textContent()).trim();
  if (!/required/i.test(heading)) throw new Error(`the section is not titled for required actions: ${heading}`);
  if (!heading.includes('1/3') && !heading.includes('1') ) throw new Error(`the heading does not carry a done/total count: ${heading}`);

  const groups = await section.locator('.card-required__group').count();
  if (groups !== 2) throw new Error(`expected two column groups (planning, doc), got ${groups}`);

  const shown = await section.textContent();
  for (const text of ['left a note', 'reviewed by someone else', 'said why']) {
    if (!shown.includes(text)) throw new Error(`the section does not show "${text}"`);
  }

  console.log('required-actions: labeled section appears, grouped by column, with a done/total count');

  // --- a pending item's action is a checkbox, right-aligned in its row ------
  //
  // His words, from a screenshot of the text-button version wrapping onto
  // three lines on a narrow dialog: "just give me a checkbox. you don't need
  // to have text button like this and the checkbox align to right." TKT-460.
  const pendingBox = page.locator('[data-required-action-done="REQ-001"]');
  const tagName = await pendingBox.evaluate(node => node.tagName.toLowerCase());
  if (tagName !== 'input') throw new Error(`the pending action is a <${tagName}>, not a checkbox input`);
  const inputType = await pendingBox.evaluate(node => node.type);
  if (inputType !== 'checkbox') throw new Error(`the pending action input is type="${inputType}", not checkbox`);
  if (await pendingBox.isChecked()) throw new Error('a pending item is shown checked');

  const rowBox = await pendingBox.evaluate(node => {
    const row = node.closest('.card-list__row');
    const rowRect = row.getBoundingClientRect();
    const checkRect = node.getBoundingClientRect();
    return { rowRight: rowRect.right, checkRight: checkRect.right };
  });
  if (Math.abs(rowBox.rowRight - rowBox.checkRight) > 4) {
    throw new Error(`the checkbox is not right-aligned in its row: row right ${rowBox.rowRight}, checkbox right ${rowBox.checkRight}`);
  }

  console.log('required-actions: a pending item shows an unchecked checkbox, right-aligned in its row');

  // --- item text shows a checkmark/unchecked emoji and a timestamp, not [done]/[pending] --
  //
  // His words, from a screenshot of the [done]/[pending] text version: "can
  // you show the timestamp, instead of show the wording done, use the emoji
  // green tick and pending just a unchecked emoji and align to left with
  // timestamp." TKT-461.
  if (shown.includes('[done]') || shown.includes('[pending]')) {
    throw new Error('the section still shows literal [done]/[pending] text');
  }
  if (!shown.includes('✅') || !shown.includes('⬜')) {
    throw new Error('the section does not show both the done and pending emoji');
  }
  if (!shown.includes('2026-08-21 09:00:00')) {
    throw new Error('the section does not show the item timestamp');
  }

  console.log('required-actions: items show a checkmark/unchecked emoji and a timestamp, not [done]/[pending] text');

  // --- a done item's command/proof is collapsed, click-to-expand ------------
  //
  // His words, from a screenshot of the gate-passing log with nowhere for
  // this to live in the required-actions section itself: "for the ran
  // commands and proof to show under the the required actions and collesped
  // and when user click on the item will expend it and see the cmmand and
  // proof." TKT-462.
  const proofRow = page.locator('[data-required-action-proof="REQ-002"]');
  await proofRow.waitFor({ state: 'attached', timeout: 15000 });
  if (!(await proofRow.isHidden())) throw new Error('a done item\'s proof is shown expanded by default');

  const proofText = await proofRow.textContent();
  if (!proofText.includes('ran the review checklist') || !proofText.includes('all items checked, no findings')) {
    throw new Error(`the collapsed proof does not carry the command/proof pair: ${proofText}`);
  }

  const doneText = page.locator('[data-required-action="REQ-002"] .card-list__text');
  await doneText.click();
  await page.waitForFunction(
    el => el.getAttribute('aria-expanded') === 'true',
    await doneText.elementHandle(), { timeout: 15000 }
  );
  if (await proofRow.isHidden()) throw new Error('clicking the done item did not expand its proof');

  await doneText.click();
  await page.waitForFunction(
    el => el.getAttribute('aria-expanded') === 'false',
    await doneText.elementHandle(), { timeout: 15000 }
  );
  if (!(await proofRow.isHidden())) throw new Error('clicking the expanded item a second time did not collapse it');

  console.log('required-actions: a done item\'s command/proof is collapsed, and expands on click');

  // --- marking one done updates the count without a page reload -------------
  await page.route('http://tira.test/required-action/update', route => {
    const done = requiredItems.find(entry => entry.id === 'REQ-001');
    done.status = 'done';
    const record = recordFor(withRequired, requiredItems);
    return route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ ok: true, record }) });
  });
  await page.click('[data-required-action-done="REQ-001"]');
  await page.waitForFunction(() => {
    const box = document.querySelector('.card-section--required .card-section__title');
    return box && /2\/3|2/.test(box.textContent);
  }, null, { timeout: 15000 });

  console.log('required-actions: marking one done updates the count in place');

  // --- a card with no required_items renders exactly as before --------------
  await page.keyboard.press('Escape');
  await page.click(`[data-ref="${withoutRequired}"]`);
  await page.waitForSelector('.card-dialog[open]');
  await page.waitForTimeout(500);
  const absent = await page.locator('.card-section--required').count();
  if (absent !== 0) throw new Error('a card with no required items shows the section anyway');

  console.log('required-actions: a card with no required_items renders exactly as before - no section appears');
  await browser.close();
})().catch(error => {
  console.error(error.message || error);
  process.exit(1);
});
