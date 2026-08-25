// TKT-516: a Task List section in the live dashboard, full CLI parity for
// the tasklist commands, sticky-note styled (pending=yellow, working=
// purple-blue, done=green). Driven the way a person drives it: read the
// section, add a task, change its status and watch the color update, and
// exercise the queue operations - checking what is actually sent against
// what was on screen, the same shape policy-editor.js already uses.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath] = process.argv.slice(2);
if (!htmlPath) {
  console.error('usage: tasklist-section.js <fixture.html>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

let items = [
  { id: 'TSK-001', text: 'Write the report', status: 0, session: '', refs: [], attachments: [] },
  { id: 'TSK-002', text: 'Ship it', status: 1, session: '', refs: [], attachments: [] },
  { id: 'TSK-003', text: 'Already finished', status: 2, session: '', refs: [], attachments: [] },
];
let nextNum = 4;

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  const posted = [];

  await page.route('**/*', route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (path === '/tasklist' && request.method() === 'GET') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(items) });
    }
    if (path === '/tasklist/add') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const entry = { id: 'TSK-00' + nextNum++, text: payload.text, status: 0, session: '', refs: [], attachments: [] };
      items.push(entry);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entry) });
    }
    if (path === '/tasklist/update') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const entry = items.find(item => item.id === payload.id);
      if (entry) entry.status = payload.status;
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entry || {}) });
    }
    if (path === '/tasklist/remove') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const removed = items.find(item => item.id === payload.id);
      items = items.filter(item => item.id !== payload.id);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(removed || {}) });
    }
    if (path === '/tasklist/shift') {
      posted.push({ path, payload: {} });
      const pending = items.filter(item => item.status === 0);
      const chosen = pending[0];
      if (chosen) items = items.filter(item => item.id !== chosen.id);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(chosen || {}) });
    }
    if (path === '/tasklist/prune') {
      posted.push({ path, payload: {} });
      const pruned = items.filter(item => item.status === 2);
      items = items.filter(item => item.status !== 2);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(pruned) });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card').length > 0);

  const section = page.locator('.board--tasklist');

  // --- the three seeded items render as colored sticky-note cards ---------
  const cardCount = await section.locator('.tasklist-card').count();
  if (cardCount !== 3) fail('expected 3 seeded tasklist cards, got ' + cardCount);

  const pendingCard = section.locator('.tasklist-card', { hasText: 'Write the report' });
  if ( ( await pendingCard.getAttribute('data-status') ) !== '0' )
    fail('the pending card did not carry data-status="0"');
  const pendingColor = await pendingCard.evaluate(node => getComputedStyle(node).backgroundColor);

  const workingCard = section.locator('.tasklist-card', { hasText: 'Ship it' });
  const workingColor = await workingCard.evaluate(node => getComputedStyle(node).backgroundColor);

  const doneCard = section.locator('.tasklist-card', { hasText: 'Already finished' });
  const doneColor = await doneCard.evaluate(node => getComputedStyle(node).backgroundColor);

  if (pendingColor === workingColor || workingColor === doneColor || pendingColor === doneColor) {
    fail(`the three statuses must render as three distinct colors, got pending=${pendingColor} working=${workingColor} done=${doneColor}`);
  }

  // --- adding a task from the section's own control ------------------------
  await section.locator('.tasklist-text').fill('A brand new task');
  await section.locator('.tasklist-add').click();
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card').length === 4);
  const added = posted.find(p => p.path === '/tasklist/add');
  if (!added || added.payload.text !== 'A brand new task') fail('adding did not post the typed text');
  const newCard = section.locator('.tasklist-card', { hasText: 'A brand new task' });
  if ( ( await newCard.getAttribute('data-status') ) !== '0' ) fail('a newly added task should start pending');

  // --- changing status via the per-card control updates its color ----------
  await newCard.locator('select').selectOption('2');
  await page.waitForFunction(
    text => document.evaluate(`//li[contains(., '${text}')]`, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null)
      .singleNodeValue?.dataset.status === '2',
    'A brand new task',
  );
  const statusUpdate = posted.find(p => p.path === '/tasklist/update' && p.payload.status === 2);
  if (!statusUpdate) fail('changing status via the dropdown did not post the update');
  const newCardColorAfter = await newCard.evaluate(node => getComputedStyle(node).backgroundColor);
  if (newCardColorAfter !== doneColor) fail('a card moved to done should render the same color as other done cards');

  // --- removing a card ------------------------------------------------------
  page.on('dialog', dialog => dialog.accept());
  await newCard.locator('button', { hasText: 'Remove' }).click();
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card').length === 3);
  const removed = posted.find(p => p.path === '/tasklist/remove');
  if (!removed) fail('removing did not post to /tasklist/remove');

  // --- shift (FIFO queue op) -------------------------------------------------
  await section.locator('.tasklist-shift').click();
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card').length === 2);
  if (!posted.find(p => p.path === '/tasklist/shift')) fail('the Shift control did not post to /tasklist/shift');
  if (await section.locator('.tasklist-card', { hasText: 'Write the report' }).count() !== 0)
    fail('shift should have removed the front pending item');

  // --- prune (removes every done item) ---------------------------------------
  await section.locator('.tasklist-prune').click();
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card[data-status="2"]').length === 0);
  if (!posted.find(p => p.path === '/tasklist/prune')) fail('the Prune control did not post to /tasklist/prune');

  await browser.close();
  if (!process.exitCode) console.log('tasklist section: all checks passed');
})().catch(error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});
