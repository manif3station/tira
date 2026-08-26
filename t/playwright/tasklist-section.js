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
  { id: 'TSK-003', text: 'Already finished', status: 2, session: '', refs: ['TKT-777'], attachments: [] },
];
let nextNum = 4;
const recordRequests = [];

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  page.on('pageerror', error => console.error('PAGE ERROR: ' + error.message));
  // TKT-549: the recursive setTimeout behind the 5-minute auto-prune is
  // captured before the page's own script runs, so it can be fired on
  // demand instead of waiting five real minutes - the 1s tasklist poll is
  // left running normally, only long delays are intercepted.
  await page.addInitScript(() => {
    window.__tiraPendingPrune = null;
    const real = window.setTimeout.bind(window);
    window.setTimeout = (callback, delay, ...rest) => {
      if (delay >= 290000) { window.__tiraPendingPrune = callback; return 1; }
      return real(callback, delay, ...rest);
    };
  });
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
      if (entry) {
        if (payload.status !== undefined) entry.status = payload.status;
        if (payload.text !== undefined) entry.text = payload.text;
      }
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
    if (path === '/tasklist/next') {
      posted.push({ path, payload: {} });
      const pending = items.filter(item => item.status === 0);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(pending[0] || {}) });
    }
    if (path === '/tasklist/slice') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const entry = { id: 'TSK-00' + nextNum++, text: payload.text, status: 0, session: '', refs: [], attachments: [] };
      items.splice(payload.position, 0, entry);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entry) });
    }
    if (path === '/tasklist/import') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([]) });
    }
    if (path === '/tasklist/prune') {
      posted.push({ path, payload: {} });
      const pruned = items.filter(item => item.status === 2);
      items = items.filter(item => item.status !== 2);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(pruned) });
    }
    if (path === '/tasklist/task/ref/link') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const entry = items.find(item => item.id === payload.id);
      if (entry) entry.refs = [...(entry.refs || []), payload.ref];
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entry || {}) });
    }
    if (path === '/tasklist/task/ref/unlink') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const entry = items.find(item => item.id === payload.id);
      if (entry) entry.refs = entry.refs.filter(ref => ref !== payload.ref);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entry || {}) });
    }
    if (path === '/record') {
      recordRequests.push(new URL(request.url()).searchParams.get('ref'));
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
        ref: 'TKT-777', type: 'ticket', column: 'in-progress', title: 'Linked from a tasklist chip',
        checklist: [], gate_passing_log: [], evidence: [], attachments: [], subtasks: [],
        linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
        comments: [], created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
      }) });
    }
    if (path === '/data' && request.method() === 'GET') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
        _column_order: { ticket: ['backlog'] },
        ticket: { backlog: [
          { ref: 'TKT-100', title: 'Existing ticket one hundred', column: 'backlog' },
          { ref: 'TKT-101', title: 'A different card', column: 'backlog' },
        ] } }) });
    }
    if (path === '/tasklist/task/attach/add') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const entry = items.find(item => item.id === payload.id);
      if (entry) entry.attachments.push({ original_filename: payload.filename });
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entry || {}) });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card').length > 0);

  const section = page.locator('.board--tasklist');

  // --- TKT-535: only Add + text input remain in the header, per Michael's
  // Q-081 answer (remove entirely, not tucked behind a toggle) ---------------
  if ((await section.locator('.tasklist-add').count()) !== 1) fail('the Add button should still be present');
  if ((await section.locator('.tasklist-text').count()) !== 1) fail('the new-task text input should still be present');
  for (const removed of ['.tasklist-unshift', '.tasklist-slice', '.tasklist-next', '.tasklist-shift', '.tasklist-pop', '.tasklist-import']) {
    if ((await section.locator(removed).count()) !== 0) fail(`${removed} should have been removed from the Task List header`);
  }
  // TKT-549: Prune came back, with new behavior beyond what TKT-535 removed.
  if ((await section.locator('.tasklist-prune').count()) !== 1) fail('the Prune button should be back in the header');

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

  // --- TKT-523: inline text edit ----------------------------------------------
  const workingCardText = section.locator('.tasklist-card', { hasText: 'Ship it' }).locator('.tasklist-card__text');
  await workingCardText.click();
  const editInput = section.locator('.tasklist-card__text-input');
  if ((await editInput.count()) !== 1) fail('clicking the text did not open an edit control');
  await editInput.fill('Ship it for real this time');
  await editInput.press('Enter');
  await page.waitForFunction(() => !document.querySelector('.tasklist-card__text-input'));
  const textUpdate = posted.find(p => p.path === '/tasklist/update' && p.payload.text === 'Ship it for real this time');
  if (!textUpdate) fail('editing a task\'s text did not post it to /tasklist/update');
  if (await section.locator('.tasklist-card', { hasText: 'Ship it for real this time' }).count() !== 1)
    fail('the edited text did not render after saving');

  // --- TKT-523: auto-refresh must not clobber an in-progress edit ------------
  const editAgain = section.locator('.tasklist-card', { hasText: 'Ship it for real this time' }).locator('.tasklist-card__text');
  await editAgain.click();
  const liveInput = section.locator('.tasklist-card__text-input');
  await liveInput.fill('still typing, not done yet');
  // Two auto-refresh ticks (1000ms each) must pass without wiping the input.
  await page.waitForTimeout(2200);
  if ((await section.locator('.tasklist-card__text-input').count()) !== 1)
    fail('an auto-refresh tick removed the edit control while typing');
  if ((await liveInput.inputValue()) !== 'still typing, not done yet')
    fail('an auto-refresh tick overwrote the text being typed');
  await liveInput.press('Escape');
  await page.waitForFunction(() => !document.querySelector('.tasklist-card__text-input'));
  if (await section.locator('.tasklist-card', { hasText: 'still typing, not done yet' }).count() !== 0)
    fail('pressing Escape should discard the edit, not save it');

  // --- TKT-524: drag-and-drop attach ------------------------------------------
  const dropTarget = section.locator('.tasklist-card', { hasText: 'Ship it for real this time' });
  await dropTarget.evaluate(node => {
    const file = new File(['hello'], 'dropped.txt', { type: 'text/plain' });
    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(file);
    node.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer }));
    node.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer }));
  });
  await page.waitForTimeout(200);
  const dropAttach = posted.find(p => p.path === '/tasklist/task/attach/add' && p.payload.filename === 'dropped.txt');
  if (!dropAttach) fail('dropping a file onto a card did not attach it');

  // --- TKT-524: paste-to-attach ------------------------------------------------
  await dropTarget.click();
  await dropTarget.evaluate(node => {
    const file = new File(['pasted'], 'pasted.png', { type: 'image/png' });
    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(file);
    const event = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dataTransfer });
    node.dispatchEvent(event);
  });
  await page.waitForTimeout(200);
  const pasteAttach = posted.find(p => p.path === '/tasklist/task/attach/add' && p.payload.filename === 'pasted.png');
  if (!pasteAttach) fail('pasting a file while a card is focused did not attach it');

  // --- TKT-534: the edit control is a dynamic-sizing textarea, not a
  // single-line input, and grows as multi-line text is typed -----------------
  await dropTarget.locator('.tasklist-card__text').click();
  const growInput = section.locator('.tasklist-card__text-input');
  const tagName = await growInput.evaluate(node => node.tagName);
  if (tagName !== 'TEXTAREA') fail('the edit control should be a textarea, not a single-line input');
  const heightBefore = await growInput.evaluate(node => node.getBoundingClientRect().height);
  await growInput.evaluate(node => { node.value = 'one\ntwo\nthree\nfour\nfive\nsix'; node.dispatchEvent(new Event('input')); });
  const heightAfter = await growInput.evaluate(node => node.getBoundingClientRect().height);
  if (!(heightAfter > heightBefore)) fail('the edit control did not grow for multi-line text');

  // --- TKT-534: pasting an image while editing attaches it (Q-080: embed
  // inline, but the file itself is stored as an attachment) ------------------
  await growInput.evaluate(node => {
    const file = new File(['pasted-while-editing'], 'edited-paste.png', { type: 'image/png' });
    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(file);
    node.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dataTransfer }));
  });
  await page.waitForTimeout(200);
  const editPasteAttach = posted.find(p => p.path === '/tasklist/task/attach/add' && p.payload.filename === 'edited-paste.png');
  if (!editPasteAttach) fail('pasting an image while editing did not attach it via the tasklist attachment mechanism');
  const valueAfterPaste = await growInput.inputValue();
  if (!valueAfterPaste.includes('edited-paste.png')) fail('pasting an image while editing did not embed a reference to it inline in the text');
  await growInput.press('Escape');
  await page.waitForFunction(() => !document.querySelector('.tasklist-card__text-input'));

  // --- TKT-528: clicking a linked ref chip's text opens that card's dialog ----
  const refChipCard = section.locator('.tasklist-card', { hasText: 'Already finished' });
  const refChip = refChipCard.locator('.tasklist-card__chip', { hasText: 'TKT-777' });
  if ((await refChip.count()) !== 1) fail('the linked ref chip for TKT-777 did not render');
  await refChip.locator('span').first().click();
  await page.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  if (!recordRequests.includes('TKT-777')) fail('clicking the ref chip text did not fetch the card record');
  if ((await page.locator('.card-dialog').getAttribute('data-ref')) !== 'TKT-777')
    fail('the opened dialog is not showing the clicked ref');
  await page.locator('.card-dialog__close').click();
  await page.waitForFunction(() => !document.querySelector('.card-dialog')?.open);

  // --- TKT-528: the chip's unlink button still unlinks, without opening the dialog
  recordRequests.length = 0;
  await refChipCard.locator('.tasklist-card__chip', { hasText: 'TKT-777' }).locator('button').click();
  await page.waitForTimeout(200);
  const unlinked = posted.find(p => p.path === '/tasklist/task/ref/unlink' && p.payload.ref === 'TKT-777');
  if (!unlinked) fail('clicking the unlink button on a ref chip did not post to /tasklist/task/ref/unlink');
  if (recordRequests.length !== 0) fail('clicking the unlink button should not also open the card dialog');

  // --- TKT-529: the board's own search box also filters tasklist cards -------
  const filterInput = page.locator('[data-filter]').first();
  if ((await filterInput.count()) !== 1) fail('no board search box found to test against');
  await filterInput.fill('finished');
  await page.waitForTimeout(300);
  const visibleAfterFilter = await section.locator('.tasklist-card:visible').allTextContents();
  if (!visibleAfterFilter.some(text => text.includes('Already finished')))
    fail('filtering for "finished" should keep the matching tasklist card visible');
  if (visibleAfterFilter.some(text => text.includes('Ship it for real this time')))
    fail('filtering for "finished" should hide non-matching tasklist cards');
  await filterInput.fill('');
  await page.waitForTimeout(300);
  if ((await section.locator('.tasklist-card:visible').count()) !== (await section.locator('.tasklist-card').count()))
    fail('clearing the search box should show every tasklist card again');

  // --- TKT-531: typing a ref suggests matching cards and clicking one links it
  await page.waitForTimeout(300);
  const suggestCard = section.locator('.tasklist-card', { hasText: 'Already finished' });
  const suggestRefInput = suggestCard.locator('input[placeholder="CARD-REF"]');
  await suggestRefInput.fill('100');
  await page.waitForTimeout(200);
  const suggestions = suggestCard.locator('.tasklist-card__ref-suggestion');
  const suggestionTexts = await suggestions.allTextContents();
  if (!suggestionTexts.some(text => text.includes('TKT-100')))
    fail('typing "100" did not suggest TKT-100 (a ref containing that number)');
  if (suggestionTexts.some(text => text.includes('TKT-101')))
    fail('typing "100" should not suggest TKT-101, which does not contain it');
  await suggestions.filter({ hasText: 'TKT-100' }).first().click();
  await page.waitForTimeout(200);
  const suggestLink = posted.find(p => p.path === '/tasklist/task/ref/link' && p.payload.ref === 'TKT-100');
  if (!suggestLink) fail('clicking a suggestion did not link it the same way the Link button does');

  // --- TKT-549: Prune - confirms on manual click, auto-interval does not -----
  let sawDialog = false;
  page.removeAllListeners('dialog');
  page.on('dialog', dialog => { sawDialog = true; dialog.dismiss(); });

  // Manual click: must ask first, and do nothing on Cancel.
  await section.locator('.tasklist-prune').click();
  await page.waitForTimeout(100);
  if (!sawDialog) fail('clicking Prune manually should ask for confirmation');
  const pruneCallsAfterCancel = posted.filter(p => p.path === '/tasklist/prune').length;
  if (pruneCallsAfterCancel !== 0) fail('cancelling the confirmation should not prune anything');

  sawDialog = false;
  page.removeAllListeners('dialog');
  page.on('dialog', dialog => { sawDialog = true; dialog.accept(); });
  await section.locator('.tasklist-prune').click();
  await page.waitForFunction(() => document.querySelectorAll('.tasklist-card').length === 2);
  if (!sawDialog) fail('a second manual click should also ask for confirmation');
  if (!posted.find(p => p.path === '/tasklist/prune')) fail('confirming should post to /tasklist/prune');

  // Auto-interval: fires without any confirmation dialog at all.
  items.push({ id: 'TSK-010', text: 'Another finished one', status: 2, session: '', refs: [], attachments: [] });
  sawDialog = false;
  page.removeAllListeners('dialog');
  page.on('dialog', dialog => { sawDialog = true; dialog.dismiss(); });
  const pruneCallsBeforeAuto = posted.filter(p => p.path === '/tasklist/prune').length;
  const fired = await page.evaluate(async () => {
    if (!window.__tiraPendingPrune) return false;
    await window.__tiraPendingPrune();
    return true;
  });
  if (!fired) fail('no 5-minute auto-prune interval was scheduled');
  for (let waited = 0; waited < 5000 && posted.filter(p => p.path === '/tasklist/prune').length === pruneCallsBeforeAuto; waited += 100) {
    await page.waitForTimeout(100);
  }
  if (sawDialog) fail('the automatic 5-minute prune must not show a confirmation dialog');
  const pruneCallsAfterAuto = posted.filter(p => p.path === '/tasklist/prune').length;
  if (pruneCallsAfterAuto !== pruneCallsBeforeAuto + 1) fail('the automatic prune did not post to /tasklist/prune');

  await browser.close();
  if (!process.exitCode) console.log('tasklist section: all checks passed');
})().catch(error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});
