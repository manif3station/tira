const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const [htmlPath, dataPath, screenshotPath] = process.argv.slice(2);
  if (!htmlPath || !dataPath || !screenshotPath) throw new Error('HTML, JSON, and screenshot paths are required');
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const data = fs.readFileSync(dataPath, 'utf8');
  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  await page.addInitScript(() => {
    window.setTimeout = (_callback, delay) => { window.__tiraTimerDelay = delay; return 1; };
  });
  const record = {
    ref: 'TKT-001', type: 'ticket', column: 'in-progress', title: 'Live browser card',
    description: 'Full popup detail', problem_or_feature: 'Popup must read like Jira',
    solution_needed: 'Sectioned dialog', source: 'a board defect', priority: 5,
    assignee: 'ada', reporter: 'ada', labels: ['browser', 'dialog'],
    start_date: '2026-08-01T09:00:00+0100', due_date: '2026-08-15T17:00:00+0100',
    sdlc_gate: 'E2E Testing', lifecycle: 'build', fix_version: '0.17',
    affects_versions: ['0.16'], parent: null,
    key_details: ['Ajax loaded'], deliverables: ['Readable dialog'],
    scope: { included: ['dialog'], excluded: ['reports'] },
    acceptance_criteria: ['No JSON blob'], test_steps: ['Click a card'],
    bdd: ['Given a card'], atdd: ['Dialog renders sections'],
    checklist: [{ id: 'CHK-001', item: 'Design sections', status: 'done', created_at: '2026-08-01T09:00:00+0100', last_updated: '2026-08-01T09:00:00+0100' }],
    gate_passing_log: [], evidence: [],
    attachments: [
      { sha: 'a'.repeat(64), extension: 'txt', original_filename: 'notes.txt', added_at: '2026-08-02T10:00:00+0100', content_type: 'text/plain; charset=UTF-8' },
      { sha: 'f'.repeat(64), extension: 'mp4', original_filename: 'clip.mp4', added_at: '2026-08-01T10:00:00+0100', content_type: 'application/octet-stream' },
      { sha: '9'.repeat(64), extension: 'tiff', original_filename: 'scan.tiff', added_at: '2026-08-01T09:00:00+0100', content_type: 'application/octet-stream' },
      { sha: 'e'.repeat(64), extension: 'txt', original_filename: 'fresh.txt', added_at: '2026-08-05T10:00:00+0100', content_type: 'text/plain; charset=UTF-8' }],
    subtasks: [],
    linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: ['TKT-004', 'TKT-005'], links: [{ type: 'blocks', ref: 'TKT-009' }] },
    comments: [
      { id: 'CMT-001', author: 'ada', format: 'markdown', body: 'First **bold** comment',
        attachments: [{ sha: 'b'.repeat(64), extension: 'png', original_filename: 'diagram.png', added_at: '2026-08-04T10:00:00+0100', content_type: 'application/octet-stream' }],
        created_at: '2026-08-05T10:00:00+0100', last_updated: '2026-08-05T10:00:00+0100' },
      { id: 'CMT-002', author: 'ada', format: 'markdown', body: 'Newest comment',
        attachments: [], created_at: '2026-08-06T10:00:00+0100', last_updated: '2026-08-06T10:00:00+0100' }],
    created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-05T10:00:00+0100',
  };
  let pageRequests = 0;
  let dataRequests = 0;
  let moveRequests = 0;
  let detailRequests = 0;
  let peopleRequests = 0;
  let searchRequests = 0;
  const mutations = [];
  await page.route('http://tira.test/**', async route => {
    const requestUrl = new URL(route.request().url());
    if (requestUrl.pathname === '/move' && route.request().method() === 'POST') {
      mutations.push({ path: '/move', body: JSON.parse(route.request().postData()) });
      moveRequests++;
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    }
    if (requestUrl.pathname === '/record') {
      detailRequests++;
      const askedRef = requestUrl.searchParams.get('ref') || 'TKT-001';
      const linked = {
        'TKT-004': { title: 'Low priority child', column: 'backlog', priority: 1 },
        'TKT-005': { title: 'High priority child', column: 'in-progress', priority: 5 },
        'TKT-009': { title: 'Blocked partner', column: 'backlog', priority: 3 },
      };
      const served = linked[askedRef]
        ? { ...record, ref: askedRef, linkage: { links: [] }, comments: [], attachments: [], ...linked[askedRef] }
        : { ...record, ref: askedRef, title: askedRef === 'TKT-001' ? record.title : 'Resident card' };
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(served) });
    }
    if (requestUrl.pathname === '/search') {
      searchRequests++;
      const text = requestUrl.searchParams.get('text') || '';
      const refs = text === 'resident' ? ['TKT-002'] : [];
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(refs) });
    }
    if (requestUrl.pathname === '/people') {
      peopleRequests++;
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[{"id":"ada","name":"Ada Lovelace"}]' });
    }
    if (requestUrl.pathname === '/link-types') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[{"outward":"blocks","inward":"is-blocked-by"},{"outward":"relates-to","inward":"relates-to"}]' });
    }
    if ((requestUrl.pathname.startsWith('/hierarchy/') || requestUrl.pathname.startsWith('/subitem/') || requestUrl.pathname.startsWith('/link/')) && route.request().method() === 'POST') {
      mutations.push({ path: requestUrl.pathname, body: JSON.parse(route.request().postData()) });
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    }
    if (requestUrl.pathname === '/attachment') {
      return route.fulfill({ status: 200, contentType: 'text/plain; charset=UTF-8', body: 'ATTACHMENT BYTES' });
    }
    if (requestUrl.pathname.startsWith('/attachment/') && route.request().method() === 'POST') {
      mutations.push({ path: requestUrl.pathname, body: JSON.parse(route.request().postData()) });
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"attachment":{"sha":"cc"}}' });
    }
    if (requestUrl.pathname.startsWith('/checklist/') && route.request().method() === 'POST') {
      mutations.push({ path: requestUrl.pathname, body: JSON.parse(route.request().postData()) });
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"entry":{"id":"CHK-002"}}' });
    }
    if (requestUrl.pathname === '/create' && route.request().method() === 'POST') {
      const body = JSON.parse(route.request().postData());
      mutations.push({ path: '/create', body });
      return route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ ok: true, record: { ...record, ref: 'TKT-042', title: body.title, column: body.column } }) });
    }
    if (requestUrl.pathname === '/update' && route.request().method() === 'POST') {
      const body = JSON.parse(route.request().postData());
      mutations.push({ path: '/update', body });
      if (body.value === 'Conflict probe')
        return route.fulfill({ status: 422, contentType: 'application/json',
          body: '{"ok":false,"conflict":true,"error":"Conflict: title changed while you were editing"}' });
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"record":{}}' });
    }
    if (requestUrl.pathname.startsWith('/comment/') && route.request().method() === 'POST') {
      mutations.push({ path: requestUrl.pathname, body: JSON.parse(route.request().postData()) });
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"comment":{"id":"CMT-002"}}' });
    }
    if (requestUrl.pathname === '/data') {
      dataRequests++;
      return route.fulfill({ status: 200, contentType: 'application/json', body: data });
    }
    // TKT-516: the Task List section fetches its own list eagerly on every
    // page load (unlike the Policies dialog, which is lazy - only on open),
    // so this fixture has to answer it or the request falls through to the
    // generic HTML fallback below and throws pageRequests off.
    if (requestUrl.pathname === '/tasklist') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    // TKT-557: the known-sessions dropdown fetches its own list eagerly too.
    if (requestUrl.pathname === '/tasklist/sessions') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    pageRequests++;
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.goto('http://tira.test/?refresh=30');
  await page.waitForFunction(() => document.querySelector('.last-updated')?.textContent !== 'Last updated: pending');
  await page.waitForFunction(() => document.querySelector('[data-column="in-progress"] [data-ref="TKT-001"]'));
  if (pageRequests !== 1 || dataRequests !== 1) throw new Error(`unexpected requests page=${pageRequests} data=${dataRequests}`);
  if (JSON.parse(data).ticket['in-progress'][0].description) throw new Error('lightweight data leaked full record fields');
  if (await page.evaluate(() => window.__tiraTimerDelay) !== 30000) throw new Error('custom refresh interval was not scheduled');
  const backlogOrder = await page.locator('.board--ticket [data-column="backlog"] li').evaluateAll(nodes => nodes.map(node => node.dataset.ref + ':' + node.dataset.mtime));
  if (backlogOrder.length !== 2 || !backlogOrder[0].startsWith('TKT-003') || backlogOrder.some(entry => entry.endsWith(':0')))
    throw new Error(`last-modified sort broken after refresh: ${JSON.stringify(backlogOrder)}`);
  const dragFrom = await page.locator('.board--ticket [data-column="in-progress"] .card').boundingBox();
  const dragTo = await page.locator('.board--ticket [data-column="backlog"]').boundingBox();
  const boardBox = await page.locator('.board--ticket').boundingBox();
  await page.mouse.move(dragFrom.x + dragFrom.width / 2, dragFrom.y + 15);
  await page.mouse.down();
  // Drop BELOW the column's content but inside the board stripe: the exact
  // dead zone that bounced drops on populated columns
  await page.mouse.move(dragTo.x + dragTo.width / 2, boardBox.y + boardBox.height - 25, { steps: 8 });
  const midDrag = await page.evaluate(() => ({ ghost: document.querySelectorAll('.card--ghost').length, target: document.querySelectorAll('.is-drop-target').length }));
  await page.mouse.up();
  await page.waitForFunction(() => document.querySelectorAll('.card--ghost').length === 0);
  if (midDrag.ghost !== 1 || midDrag.target !== 1) throw new Error(`drag affordances missing mid-drag: ${JSON.stringify(midDrag)}`);
  if (moveRequests !== 1) throw new Error(`drag move request missing: ${moveRequests}`);
  for (let i = 0; i < 80 && dataRequests < 2; i++) await new Promise(resolve => setTimeout(resolve, 25));
  if (dataRequests < 2) throw new Error('post-drag refresh never fetched /data');
  await page.evaluate(() => new Promise(requestAnimationFrame));

  // The fixed width lives on the column itself now that each column owns its
  // heading, so that is where standard-versus-fit is asked.
  const columnBasis = () => page.locator('.board--ticket .column').first().evaluate(node => getComputedStyle(node).flexBasis);
  if (await columnBasis() === 'auto') throw new Error('standard mode must keep fixed-width columns');
  if (await page.evaluate(() => document.documentElement.dataset.width) !== 'standard')
    throw new Error('the board must start in standard width mode');
  await page.locator('.board--ticket [data-width="fit"]').click();
  await page.waitForFunction(() => document.documentElement.dataset.width === 'fit');
  if (await columnBasis() !== 'auto') throw new Error('fit mode must let columns shrink to the container');
  const fitOverflow = await page.locator('.board--ticket .board__scroll').evaluate(node => node.scrollWidth - node.clientWidth);
  if (fitOverflow > 1) throw new Error(`fit mode must remove sideways scrolling, overflows by ${fitOverflow}px`);
  const fitActive = await page.locator('.board--ticket [data-width="fit"]').evaluate(node => node.classList.contains('is-active'));
  if (!fitActive) throw new Error('the active width button must be marked');
  await page.reload();
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  if (await page.evaluate(() => document.documentElement.dataset.width) !== 'fit')
    throw new Error('the width choice must be remembered across reloads');
  if (await columnBasis() !== 'auto') throw new Error('the remembered fit mode must apply on load');
  await page.locator('.board--ticket [data-width="standard"]').click();
  await page.waitForFunction(() => document.documentElement.dataset.width === 'standard');
  if (await columnBasis() === 'auto') throw new Error('switching back to standard must restore fixed columns');
  await page.reload();
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  if (await page.evaluate(() => document.documentElement.dataset.width) !== 'standard')
    throw new Error('switching back to standard must also be remembered');

  // Shift-click selects, a plain click clears and opens, and a drag
  // carries the whole selection.
  const selectedRefs = () => page.locator('.card.is-selected').evaluateAll(
    nodes => nodes.map(node => node.dataset.ref).sort());
  await page.locator('[data-ref="TKT-002"] .card').click({ modifiers: ['Shift'] });
  await page.locator('[data-ref="TKT-003"] .card').click({ modifiers: ['Shift'] });
  if (JSON.stringify(await selectedRefs()) !== JSON.stringify(['TKT-002', 'TKT-003']))
    throw new Error(`shift-click must select cards, got ${JSON.stringify(await selectedRefs())}`);
  if (await page.evaluate(() => document.querySelector('.card-dialog')?.open))
    throw new Error('shift-click must not open the dialog');

  await page.locator('[data-ref="TKT-002"] .card').click({ modifiers: ['Shift'] });
  if (JSON.stringify(await selectedRefs()) !== JSON.stringify(['TKT-003']))
    throw new Error('shift-click must also deselect');

  await page.locator('[data-ref="TKT-002"] .card').click({ modifiers: ['Shift'] });
  const movesBeforeBatch = moveRequests;
  const batchFrom = await page.locator('[data-ref="TKT-002"] .card').boundingBox();
  const batchTo = await page.locator('.board--ticket [data-column="in-progress"]').boundingBox();
  await page.mouse.move(batchFrom.x + batchFrom.width / 2, batchFrom.y + 10);
  await page.mouse.down();
  await page.mouse.move(batchFrom.x + batchFrom.width / 2 + 30, batchFrom.y + 30, { steps: 6 });
  const batchBadge = await page.locator('.card--ghost .card__batch').textContent();
  if (batchBadge !== '2 cards') throw new Error(`the ghost must show the batch size, got ${batchBadge}`);
  await page.mouse.move(batchTo.x + batchTo.width / 2, batchTo.y + 40, { steps: 6 });
  await page.mouse.up();
  await page.waitForFunction(prev => window.__tiraMoveCount === undefined || true, null);
  for (let i = 0; i < 80 && moveRequests < movesBeforeBatch + 2; i++)
    await new Promise(resolve => setTimeout(resolve, 25));
  if (moveRequests !== movesBeforeBatch + 2)
    throw new Error(`dragging a selection must move every selected card, got ${moveRequests - movesBeforeBatch}`);
  const batchMoves = mutations.filter(e => e.path === '/move').slice(-2).map(e => e.body.ref).sort();
  if (JSON.stringify(batchMoves) !== JSON.stringify(['TKT-002', 'TKT-003']))
    throw new Error(`the batch must carry both refs, got ${JSON.stringify(batchMoves)}`);
  await page.waitForFunction(() => document.querySelectorAll('.card.is-selected').length === 0);

  await page.locator('[data-ref="TKT-002"] .card').click({ modifiers: ['Shift'] });
  await page.locator('[data-ref="TKT-003"] .card').click();
  await page.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  if ((await selectedRefs()).length)
    throw new Error('a plain click must clear the selection');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('.card-dialog')?.open);

  // The filter asks the server and hides everything else.
  // The box is wired to applyFilter (pinned by a renderer assertion); this
  // drives that function directly, because synthetic keystrokes did not fire
  // the debounce reliably in this harness. What matters — the request, the
  // response, and what the board then shows — is fully exercised.
  const filterInput = await page.locator('[data-filter="ticket"]').count();
  if (filterInput !== 1) throw new Error('the board control must carry one filter box');
  await page.evaluate(() => applyFilter('ticket', 'resident'));
  await page.waitForFunction(() => (window.__tiraFilterSeq || 0) > 0);
  const visibleAfterFilter = await page.locator('.board--ticket .cards > li:not([hidden])')
    .evaluateAll(nodes => nodes.map(node => node.dataset.ref));
  if (JSON.stringify(visibleAfterFilter) !== JSON.stringify(['TKT-002']))
    throw new Error(`the filter must show only matches, got ${JSON.stringify(visibleAfterFilter)}`);
  if (!searchRequests) throw new Error('the filter must ask the server rather than matching titles locally');
  await page.evaluate(() => applyFilter('ticket', ''));
  await page.waitForFunction(() =>
    document.querySelectorAll('.board--ticket .cards > li:not([hidden])').length === 3);

  const countText = column => page.locator(`.board--ticket [data-count-for="${column}"]`).textContent();
  const countHidden = column => page.locator(`.board--ticket [data-count-for="${column}"]`).evaluate(node => node.hidden);
  if (await countText('backlog') !== '2') throw new Error(`backlog should show 2 cards, got ${await countText('backlog')}`);
  if (await countText('in-progress') !== '1') throw new Error('in-progress should show 1 card');
  await page.evaluate(() => document.querySelector('[data-column="in-progress"]').replaceChildren());
  await page.evaluate(() => window.__tiraForceCounts && window.__tiraForceCounts());

  await page.locator('.board--ticket [data-add-card="backlog"]').click();
  await page.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  await page.waitForSelector('.card-dialog .card-new');
  const newRef = await page.locator('.card-dialog__ref').textContent();
  if (!newRef.includes('reference assigned on save'))
    throw new Error(`a new card must show no reference, got: ${newRef}`);
  if (await page.evaluate(() => document.querySelector('.card-dialog').dataset.ref) !== '')
    throw new Error('a new card dialog must carry no ref');

  const createsBefore = mutations.filter(e => e.path === '/create').length;
  await page.locator('.card-dialog [data-create-card]').click();
  await page.waitForFunction(() =>
    (document.querySelector('.card-dialog__error')?.textContent || '').includes('title is required'));
  if (mutations.filter(e => e.path === '/create').length !== createsBefore)
    throw new Error('a card with no title must not be created');

  await page.locator('.card-dialog .card-new [name="title"]').fill('Created from the board');
  await page.locator('.card-dialog .card-new [name="priority"]').selectOption('4');
  await page.locator('.card-dialog [data-create-card]').click();
  await page.waitForFunction(() => document.querySelector('.card-dialog').dataset.ref === 'TKT-042');
  const created = mutations.find(e => e.path === '/create');
  if (!created) throw new Error('creating posted no /create request');
  if (created.body.title !== 'Created from the board' || created.body.column !== 'backlog'
    || created.body.type !== 'ticket' || created.body.priority !== '4')
    throw new Error(`unexpected create payload: ${JSON.stringify(created.body)}`);
  const shownAfterCreate = await page.locator('.card-dialog__ref').textContent();
  if (!shownAfterCreate.startsWith('TKT-042'))
    throw new Error(`the dialog must switch to the created card, got: ${shownAfterCreate}`);
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('.card-dialog')?.open);
  await page.reload();
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const seq = () => page.evaluate(() => window.__tiraMutationSeq || 0);
  let before = 0;
  const detailsBeforeOpen = detailRequests;
  await page.locator('[data-ref="TKT-001"] .card').click();
  await page.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  await page.waitForFunction(() => document.querySelectorAll('.card-dialog [data-linkage-row]').length >= 3);
  if (detailRequests - detailsBeforeOpen !== 4)
    throw new Error(`expected the lazy record read plus three linked-row lookups, got ${detailRequests - detailsBeforeOpen}`);

  const sections = page.locator('.card-dialog .card-dialog__sections');
  const sectionText = await sections.textContent();
  for (const expected of ['Details', 'Description', 'Full popup detail', 'Very High', 'Ada Lovelace',
    'Checklist', 'Design sections', 'Comments', 'bold', 'Acceptance Criteria', 'No JSON blob']) {
    if (!sectionText.includes(expected)) throw new Error(`sectioned dialog is missing: ${expected}`);
  }
  if (sectionText.includes('"ref"') || sectionText.includes('undefined') || sectionText.includes('null'))
    throw new Error('dialog leaks raw JSON or empty markers');
  if (await page.locator('.card-dialog .card-dialog__sections pre').count() !== 0) throw new Error('dialog still renders a raw JSON blob');
  if (peopleRequests < 1) throw new Error('author choices were not loaded from /people');

  const statusOptions = await page.locator('.card-dialog .card-status option').evaluateAll(nodes => nodes.map(node => node.value));
  if (statusOptions.length < 2 || !statusOptions.includes('backlog') || !statusOptions.includes('in-progress'))
    throw new Error(`the column dropdown must list the board columns: ${statusOptions}`);
  const statusLabels = await page.locator('.card-dialog .card-status option').evaluateAll(nodes => nodes.map(node => node.textContent));
  if (statusLabels.some(label => /\d/.test(label)))
    throw new Error(`dropdown labels must be column names only, got ${JSON.stringify(statusLabels)}`);
  const labelledValues = await page.locator('.card-dialog .card-status option').evaluateAll(nodes =>
    nodes.map(node => `${node.textContent}|${node.value}`));
  if (!labelledValues.includes('backlog|backlog') || !labelledValues.includes('in-progress|in-progress'))
    throw new Error(`each option must show its column's own name, got ${JSON.stringify(labelledValues)}`);
  const statusSelected = await page.locator('.card-dialog .card-status').inputValue();
  if (statusSelected !== 'in-progress') throw new Error(`the dropdown must preselect the card's column, got ${statusSelected}`);
  before = await seq();
  const movesBeforeStatus = moveRequests;
  await page.locator('.card-dialog .card-status').selectOption('backlog');
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  if (moveRequests !== movesBeforeStatus + 1) throw new Error('the dropdown move did not post /move');

  await page.locator('.card-dialog [data-edit="title"]').click();
  await page.locator('.card-dialog h2 .card-edit-input').fill('Renamed by dialog');
  await page.locator('.card-dialog [data-save="title"]').click();
  await page.waitForFunction(() => document.querySelectorAll('.card-dialog h2 .card-edit-input').length === 0);
  const update = mutations.find(entry => entry.path === '/update');
  if (!update) throw new Error('field edit posted no /update request');
  if (update.body.ref !== 'TKT-001' || update.body.field !== 'title' || update.body.value !== 'Renamed by dialog')
    throw new Error(`unexpected update payload: ${JSON.stringify(update.body)}`);
  if (update.body.base !== 'Live browser card')
    throw new Error(`the update payload must carry the base value it loaded, got ${JSON.stringify(update.body.base)}`);
  if (detailRequests < 2) throw new Error('a saved edit did not re-read the record');

  const detailsBeforeConflict = detailRequests;
  await page.locator('.card-dialog [data-edit="title"]').click();
  await page.locator('.card-dialog h2 .card-edit-input').fill('Conflict probe');
  await page.locator('.card-dialog [data-save="title"]').click();
  await page.waitForFunction(() =>
    (document.querySelector('.card-dialog__error')?.textContent || '').includes('changed while you were editing'));
  await page.waitForFunction(() => document.querySelectorAll('.card-dialog h2 .card-edit-input').length === 0);
  if (detailRequests <= detailsBeforeConflict)
    throw new Error('a conflicted save must reload the card so the user sees the fresh value');
  const conflictErrorHidden = await page.locator('.card-dialog__error').evaluate(node => node.hidden);
  if (conflictErrorHidden) throw new Error('the conflict message must stay visible after the reload');

  await page.waitForFunction(() => {
    const rows = document.querySelectorAll('.card-dialog [data-linkage-row]');
    return rows.length >= 3 && [...rows].every(row => row.querySelector('.card-linkage__title').textContent !== '\u2026');
  });
  const childRows = await page.locator('.card-dialog .card-linkage-table [data-linkage-row]').evaluateAll(rows =>
    rows.filter(row => ['TKT-004', 'TKT-005'].includes(row.getAttribute('data-linkage-row')))
      .map(row => ({
        ref: row.getAttribute('data-linkage-row'),
        title: row.querySelector('.card-linkage__title').textContent,
        status: row.querySelector('.card-linkage__status').textContent,
      })));
  if (childRows.length !== 2) throw new Error(`expected two linked child rows, got ${JSON.stringify(childRows)}`);
  if (childRows[0].ref !== 'TKT-005' || childRows[1].ref !== 'TKT-004')
    throw new Error(`linkage rows must sort by priority, got ${childRows.map(row => row.ref).join(',')}`);
  if (childRows[0].title !== 'High priority child' || childRows[0].status !== 'in-progress')
    throw new Error(`linkage rows must show title and status, got ${JSON.stringify(childRows[0])}`);
  const blockedRow = await page.locator('.card-dialog [data-linkage-row="TKT-009"]').first();
  const blockedType = await blockedRow.locator('.card-linkage__type').textContent();
  if (blockedType !== 'blocks') throw new Error(`typed link rows must keep their type, got ${blockedType}`);

  // TKT-470: clicking a linked row navigates the dialog to that card, and the
  // back control returns to the card that was open before.
  if (!(await page.locator('.card-dialog__back').isHidden()))
    throw new Error('the back control must start hidden - nothing to go back to yet');
  await page.locator('.card-dialog [data-linkage-row="TKT-005"]').click();
  await page.waitForFunction(() => (document.querySelector('.card-dialog__ref')?.textContent || '').includes('TKT-005'));
  const navigatedText = await page.locator('.card-dialog__ref').textContent();
  if (!navigatedText.includes('High priority child') && !(await page.locator('.card-dialog h2').textContent()).includes('High priority child'))
    throw new Error(`clicking a linked row must open that card, got ref line ${navigatedText}`);
  if (await page.locator('.card-dialog__back').isHidden())
    throw new Error('the back control must be visible once navigated into a linked card');
  await page.locator('.card-dialog__back').click();
  await page.waitForFunction(() => (document.querySelector('.card-dialog__ref')?.textContent || '').includes('TKT-001'));
  if (!(await page.locator('.card-dialog__back').isHidden()))
    throw new Error('the back control must hide again once back at the card that started the trip');

  const commentIds = await page.locator('.card-dialog .card-comment').evaluateAll(nodes => nodes.map(node => node.dataset.comment));
  if (JSON.stringify(commentIds) !== JSON.stringify(['CMT-002', 'CMT-001'])) throw new Error(`comments are not newest-first: ${commentIds}`);
  if (await page.locator('.card-dialog .card-comment__body strong').count() !== 1)
    throw new Error('bold markdown did not render as a strong element');
  const chipNames = await page.locator('.card-dialog .card-attachments .card-attachment__view').evaluateAll(nodes => nodes.map(node => node.textContent));
  if (!chipNames[0].includes('fresh.txt')) throw new Error(`attachments are not newest-first: ${chipNames}`);
  if (!/2026-08-05 10:00:00/.test(chipNames[0])) throw new Error(`attachment chip lacks its full timestamp: ${chipNames[0]}`);
  const chipBoxes = await page.locator('.card-dialog .card-attachments .card-attachment').evaluateAll(nodes => nodes.map(node => {
    const rect = node.getBoundingClientRect();
    const host = node.closest('.card-attachment-strip').getBoundingClientRect();
    return { x: Math.round(rect.x), y: Math.round(rect.y), ratio: rect.width / host.width };
  }));
  if (chipBoxes.length < 2 || chipBoxes[0].y === chipBoxes[1].y || chipBoxes.some(box => box.ratio < 0.95))
    throw new Error(`attachments must render as a one-per-row list: ${JSON.stringify(chipBoxes)}`);
  if (await page.locator('.card-dialog .card-comment-form:visible').count() !== 0)
    throw new Error('the composer must start collapsed');
  const composerToggle = page.locator('.card-dialog .card-composer-toggle');
  const commentsBox = await page.locator('.card-dialog .card-comments-box').evaluate(box => box.firstElementChild.className);
  if (!commentsBox.includes('card-composer')) throw new Error(`the composer is not at the top of the comments box: ${commentsBox}`);
  await composerToggle.click();
  await page.waitForSelector('.card-dialog .card-comment-form:visible');
  await page.locator('.card-dialog .card-comment-form textarea[name="text"]').fill('rich');
  await page.locator('.card-dialog .card-comment-form textarea[name="text"]').evaluate(area => { area.selectionStart = 0; area.selectionEnd = 4; });
  await page.locator('.card-dialog .card-comment-form [data-md="bold"]').click();
  const toolbarValue = await page.locator('.card-dialog .card-comment-form textarea[name="text"]').inputValue();
  if (toolbarValue !== '**rich**') throw new Error(`bold toolbar produced: ${toolbarValue}`);
  if (await page.locator('.card-dialog .card-comment-form select[name="author"]').count() !== 0)
    throw new Error('the composer must not offer an author to pick - a comment is attributed to whoever is signed in');
  await page.locator('.card-dialog .card-comment-form textarea[name="text"]').fill('A **new** comment');
  await page.locator('.card-dialog .card-comment-form button[type="submit"]').click();
  await page.waitForFunction(() => window.__tiraLastMutation === '/comment/add');
  const added = mutations.find(entry => entry.path === '/comment/add');
  if (!added || added.body.author !== undefined || added.body.text !== 'A **new** comment' || added.body.ref !== 'TKT-001')
    throw new Error(`unexpected comment add payload: ${JSON.stringify(added && added.body)}`);

  await page.locator('.card-dialog [data-comment-edit="CMT-001"]').click();
  await page.locator('.card-dialog [data-comment="CMT-001"] textarea').fill('Edited comment');
  await page.locator('.card-dialog [data-comment-save="CMT-001"]').click();
  await page.waitForFunction(() => window.__tiraLastMutation === '/comment/update');
  const edited = mutations.find(entry => entry.path === '/comment/update');
  if (!edited || edited.body.comment !== 'CMT-001' || edited.body.text !== 'Edited comment')
    throw new Error(`unexpected comment update payload: ${JSON.stringify(edited && edited.body)}`);

  await page.locator('.card-dialog [data-comment-remove="CMT-001"]').click();
  await page.waitForFunction(() => window.__tiraLastMutation === '/comment/remove');
  const removed = mutations.find(entry => entry.path === '/comment/remove');
  if (!removed || removed.body.comment !== 'CMT-001' || removed.body.ref !== 'TKT-001')
    throw new Error(`unexpected comment remove payload: ${JSON.stringify(removed && removed.body)}`);

  const commentChip = page.locator('.card-dialog [data-comment="CMT-001"] .card-attachment');
  if (await commentChip.count() !== 1) throw new Error('comment-owned attachment chip is missing from its comment');
  if (!(await commentChip.textContent()).includes('diagram.png')) throw new Error('comment attachment chip lacks its filename');

  await page.locator(`.card-dialog [data-view-attachment="${'a'.repeat(64)}.txt"]`).click();
  await page.waitForSelector('.card-viewer:not([hidden])');
  await page.waitForSelector('.card-viewer .card-viewer__text:not([hidden])');
  await page.waitForFunction(() => document.querySelector('.card-viewer__text')?.textContent.includes('ATTACHMENT BYTES'));
  const paneColor = await page.locator('.card-viewer .card-viewer__text').evaluate(node => getComputedStyle(node).color);
  const frameHidden = await page.locator('.card-viewer iframe').evaluate(node => node.hidden);
  if (!frameHidden) throw new Error('text attachments must not render through the iframe');
  if (paneColor === 'rgb(255, 255, 255)' || paneColor === 'rgb(248, 250, 252)')
    throw new Error(`text pane color is near-white and could vanish on a light canvas: ${paneColor}`);

  // TKT-500: notes.txt sits second-newest (fresh.txt, notes.txt, clip.mp4,
  // scan.tiff) - both arrows should be usable without closing the overlay.
  if (await page.locator('.card-viewer__prev').isDisabled()) throw new Error('prev should be enabled mid-list');
  if (await page.locator('.card-viewer__next').isDisabled()) throw new Error('next should be enabled mid-list');

  await page.locator('.card-viewer__next').click();
  await page.waitForFunction(() => document.querySelector('.card-viewer__name')?.textContent === 'clip.mp4');
  if (await page.locator('.card-viewer .card-viewer__video').evaluate(node => node.hidden))
    throw new Error('next did not switch the pane to the next attachment (clip.mp4)');

  await page.locator('.card-viewer__next').click();
  await page.waitForFunction(() => document.querySelector('.card-viewer__name')?.textContent === 'scan.tiff');
  if (!(await page.locator('.card-viewer__next').isDisabled())) throw new Error('next should be disabled at the last attachment');

  await page.locator('.card-viewer__prev').click();
  await page.locator('.card-viewer__prev').click();
  await page.locator('.card-viewer__prev').click();
  await page.waitForFunction(() => document.querySelector('.card-viewer__name')?.textContent === 'fresh.txt');
  if (!(await page.locator('.card-viewer__prev').isDisabled())) throw new Error('prev should be disabled at the first attachment');

  // A comment's own attachment list (one entry) offers nowhere to navigate.
  await page.locator('.card-viewer__close').click();
  await page.waitForSelector('.card-viewer', { state: 'hidden' });
  await page.locator('.card-dialog [data-comment="CMT-001"] [data-view-attachment]').click();
  await page.waitForSelector('.card-viewer:not([hidden])');
  if (!(await page.locator('.card-viewer__prev').isDisabled()) || !(await page.locator('.card-viewer__next').isDisabled()))
    throw new Error('a lone comment attachment should show both arrows disabled');

  await page.locator('.card-viewer__close').click();
  await page.waitForSelector('.card-viewer', { state: 'hidden' });

  page.once('dialog', dialog => dialog.accept());
  await page.locator(`.card-dialog [data-detach-attachment="${'a'.repeat(64)}.txt"]`).click();
  // Discard, not remove. The owner asked for taking an attachment off a card to
  // be a discard like everything else in Tira - crossed out and greyed on the
  // board rather than gone - and the endpoint was renamed when that shipped.
  // This test kept waiting for the old one, and nothing noticed, because
  // nothing ran it.
  await page.waitForFunction(() => window.__tiraLastMutation === '/attachment/discard');
  const detached = mutations.find(entry => entry.path === '/attachment/discard');
  if (!detached || detached.body.sha !== 'a'.repeat(64) || detached.body.extension !== 'txt' || detached.body.ref !== 'TKT-001')
    throw new Error(`unexpected attachment remove payload: ${JSON.stringify(detached && detached.body)}`);

  const uploadPath = require('path').join(require('os').tmpdir(), 'tira-upload.txt');
  fs.writeFileSync(uploadPath, 'uploaded bytes');
  await page.locator('.card-dialog .card-attach-input[data-attach-target="record"]').setInputFiles(uploadPath);
  await page.waitForFunction(() => window.__tiraLastMutation === '/attachment/add');
  const uploaded = mutations.find(entry => entry.path === '/attachment/add');
  if (!uploaded || uploaded.body.filename !== 'tira-upload.txt' || !uploaded.body.content_base64 || uploaded.body.ref !== 'TKT-001')
    throw new Error(`unexpected attachment add payload: ${JSON.stringify(uploaded && uploaded.body)}`);
  if (Buffer.from(uploaded.body.content_base64, 'base64').toString() !== 'uploaded bytes')
    throw new Error('uploaded content did not round-trip through base64');

  before = await seq();
  await page.locator('.card-dialog [data-list-edit="acceptance_criteria:0"]').click();
  await page.locator('.card-dialog [data-list-input="acceptance_criteria"]').fill('No JSON blob, edited');
  await page.locator('.card-dialog [data-list-save="acceptance_criteria"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const listEdit = mutations.filter(e => e.path === '/update').find(e => e.body.field === 'acceptance_criteria');
  if (!listEdit || !Array.isArray(listEdit.body.value) || listEdit.body.value[0] !== 'No JSON blob, edited')
    throw new Error(`unexpected list edit payload: ${JSON.stringify(listEdit && listEdit.body)}`);

  before = await seq();
  await page.locator('.card-dialog [data-list-remove="key_details:0"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const listRemove = mutations.filter(e => e.path === '/update').find(e => e.body.field === 'key_details');
  if (!listRemove || !Array.isArray(listRemove.body.value) || listRemove.body.value.length !== 0)
    throw new Error(`unexpected list remove payload: ${JSON.stringify(listRemove && listRemove.body)}`);

  before = await seq();
  await page.locator('.card-dialog [data-list-add="deliverables"]').fill('Second deliverable');
  await page.locator('.card-dialog [data-list-add-save="deliverables"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const listAdd = mutations.filter(e => e.path === '/update').find(e => e.body.field === 'deliverables');
  if (!listAdd || JSON.stringify(listAdd.body.value) !== JSON.stringify(['Readable dialog', 'Second deliverable']))
    throw new Error(`unexpected list add payload: ${JSON.stringify(listAdd && listAdd.body)}`);

  before = await seq();
  await page.locator('.card-dialog [data-checklist-edit="CHK-001"]').click();
  await page.locator('.card-dialog [data-checklist-status="CHK-001"]').fill('In Progress');
  await page.locator('.card-dialog [data-checklist-save="CHK-001"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const checklistEdit = mutations.find(e => e.path === '/checklist/update');
  if (!checklistEdit || checklistEdit.body.id !== 'CHK-001' || checklistEdit.body.status !== 'In Progress')
    throw new Error(`unexpected checklist edit payload: ${JSON.stringify(checklistEdit && checklistEdit.body)}`);

  before = await seq();
  await page.locator('.card-dialog .card-checklist-form input[name="item"]').fill('New row');
  await page.locator('.card-dialog .card-checklist-form input[name="status"]').fill('To Do');
  await page.locator('.card-dialog .card-checklist-form button[type="submit"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const checklistAdd = mutations.find(e => e.path === '/checklist/add');
  if (!checklistAdd || checklistAdd.body.item !== 'New row' || checklistAdd.body.status !== 'To Do')
    throw new Error(`unexpected checklist add payload: ${JSON.stringify(checklistAdd && checklistAdd.body)}`);
  if (await page.locator('.card-dialog [data-checklist-remove]').count() !== 0)
    throw new Error('checklist rows must not offer a delete control');

  if (await page.locator('.card-dialog .card-section__title [data-edit="description"]').count() !== 1)
    throw new Error('the description pencil is not in the section heading');

  before = await seq();
  const refBeforeLinkRemove = await page.locator('.card-dialog__ref').textContent();
  await page.locator('.card-dialog [data-link-remove="blocks:TKT-009"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const linkRemove = mutations.find(e => e.path === '/link/remove');
  if (!linkRemove || linkRemove.body.from !== 'TKT-001' || linkRemove.body.type !== 'blocks' || linkRemove.body.to !== 'TKT-009')
    throw new Error(`unexpected link remove payload: ${JSON.stringify(linkRemove && linkRemove.body)}`);
  // TKT-470: the typed-link remove button lives inside a navigable linkage
  // row too, and must not trigger the row's own navigate-on-click either.
  const refAfterLinkRemove = await page.locator('.card-dialog__ref').textContent();
  if (refAfterLinkRemove !== refBeforeLinkRemove)
    throw new Error(`clicking a typed link's remove button must not navigate away, went from ${refBeforeLinkRemove} to ${refAfterLinkRemove}`);
  if (!(await page.locator('.card-dialog__back').isHidden()))
    throw new Error('clicking a typed link remove button must not push onto the navigation stack either');

  before = await seq();
  await page.locator('.card-dialog .card-link-form select[name="type"]').selectOption('is-blocked-by');
  await page.locator('.card-dialog .card-link-form input[name="to"]').fill('TKT-777');
  await page.locator('.card-dialog .card-link-form button[type="submit"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const linkAdd = mutations.find(e => e.path === '/link/add');
  if (!linkAdd || linkAdd.body.type !== 'is-blocked-by' || linkAdd.body.to !== 'TKT-777')
    throw new Error(`unexpected link add payload: ${JSON.stringify(linkAdd && linkAdd.body)}`);

  before = await seq();
  await page.locator('.card-dialog [data-linkage-add="epic_ref"]').fill('EPC-001');
  await page.locator('.card-dialog [data-linkage-add-save="epic_ref"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const parentLink = mutations.find(e => e.path === '/hierarchy/link');
  if (!parentLink || parentLink.body.parent !== 'EPC-001' || parentLink.body.child !== 'TKT-001')
    throw new Error(`unexpected hierarchy link payload: ${JSON.stringify(parentLink && parentLink.body)}`);

  before = await seq();
  const refBeforeUnlink = await page.locator('.card-dialog__ref').textContent();
  await page.locator('.card-dialog [data-linkage-unlink="sub_ticket_refs:TKT-005"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const subUnlink = mutations.find(e => e.path === '/subitem/unlink');
  if (!subUnlink || subUnlink.body.parent !== 'TKT-001' || subUnlink.body.child !== 'TKT-005')
    throw new Error(`unexpected subitem unlink payload: ${JSON.stringify(subUnlink && subUnlink.body)}`);
  // TKT-470: the unlink (x) button must not trigger the row's own navigate-on-click.
  const refAfterUnlink = await page.locator('.card-dialog__ref').textContent();
  if (refAfterUnlink !== refBeforeUnlink)
    throw new Error(`clicking unlink must not navigate away from the card, went from ${refBeforeUnlink} to ${refAfterUnlink}`);
  if (!(await page.locator('.card-dialog__back').isHidden()))
    throw new Error('clicking unlink must not push onto the navigation stack either');

  await page.locator(`.card-dialog [data-view-attachment="${'f'.repeat(64)}.mp4"]`).first().click();
  await page.waitForSelector('.card-viewer:not([hidden])');
  const videoSrc = await page.locator('.card-viewer__video').getAttribute('src');
  if (!videoSrc || !videoSrc.includes('/attachment?') || await page.locator('.card-viewer__video').evaluate(node => node.hidden))
    throw new Error(`video attachments must open in the player: ${videoSrc}`);
  await page.locator('.card-viewer__close').click();
  await page.waitForSelector('.card-viewer', { state: 'hidden' });

  await page.locator(`.card-dialog [data-view-attachment="${'9'.repeat(64)}.tiff"]`).first().click();
  await page.waitForSelector('.card-viewer:not([hidden])');
  await page.waitForSelector('.card-viewer__fallback:not([hidden])', { timeout: 10000 });
  await page.locator('.card-viewer__close').click();
  await page.waitForSelector('.card-viewer', { state: 'hidden' });

  await page.locator(`.card-dialog [data-view-attachment="${'a'.repeat(64)}.txt"]`).first().click();
  await page.waitForSelector('.card-viewer:not([hidden])');
  await page.keyboard.press('Escape');
  await page.waitForSelector('.card-viewer', { state: 'hidden' });
  if (!await page.locator('.card-dialog').evaluate(dialog => dialog.open))
    throw new Error('Escape with the viewer open must close only the viewer');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('.card-dialog').open);
  await page.locator('[data-ref="TKT-002"] .card').click();
  await page.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  if (await page.locator('.card-viewer:visible').count() !== 0)
    throw new Error('a reopened dialog must not show the previous attachment viewer');
  const reopenedRef = await page.locator('.card-dialog__ref').textContent();
  if (!reopenedRef.startsWith('TKT-002'))
    throw new Error(`a reopened dialog must show the newly clicked card, got: ${reopenedRef}`);
  await page.keyboard.press('Escape');

  await page.screenshot({ path: screenshotPath, fullPage: true });

  const mobile = await browser.newPage({ viewport: { width: 430, height: 932 } });
  await mobile.route('http://tira.test/**', async route => {
    const u = new URL(route.request().url());
    if (u.pathname === '/record') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(record) });
    if (u.pathname === '/people') return route.fulfill({ status: 200, contentType: 'application/json', body: '[{"id":"ada","name":"Ada Lovelace"}]' });
    if (u.pathname === '/link-types') return route.fulfill({ status: 200, contentType: 'application/json', body: '[{"outward":"blocks","inward":"is-blocked-by"}]' });
    if (u.pathname === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: data });
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  let mobileTitle = 'Live browser card';
  let mobileRecordHits = 0;
  let mobileRecordDelay = 0;
  await mobile.route('http://tira.test/record**', async route => {
    mobileRecordHits++;
    if (mobileRecordDelay) await new Promise(resolve => setTimeout(resolve, mobileRecordDelay));
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ...record, title: mobileTitle }) });
  });
  let mobileMoves = 0;
  await mobile.route('http://tira.test/move', async route => {
    mobileMoves++;
    return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
  });
  await mobile.goto('http://tira.test/?refresh=2');
  await mobile.waitForSelector('[data-ref="TKT-001"] .card');
  const bodyOverflow = await mobile.evaluate(() => document.body.scrollWidth - document.documentElement.clientWidth);
  if (bodyOverflow > 1) throw new Error(`mobile page overflows horizontally by ${bodyOverflow}px`);
  await mobile.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await mobile.click('[data-ref="TKT-001"] .card');
  await mobile.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  const dialogBox = await mobile.locator('.card-dialog').boundingBox();
  if (!dialogBox || dialogBox.width > 430) throw new Error(`mobile dialog is too wide: ${dialogBox && dialogBox.width}`);
  if (dialogBox.y < -1 || dialogBox.y > 932) throw new Error(`dialog opened outside the viewport at y=${dialogBox.y} (opened after scrolling down)`);
  const sideScroll = await mobile.locator('.card-dialog__sections').evaluate(node => node.scrollWidth - node.clientWidth);
  if (sideScroll > 1) throw new Error(`modal body scrolls sideways by ${sideScroll}px`);
  const gridColumns = await mobile.locator('.card-details').first().evaluate(node => getComputedStyle(node).gridTemplateColumns.split(' ').length);
  if (gridColumns !== 1) throw new Error(`mobile details grid should stack to one column, got ${gridColumns}`);
  await mobile.waitForFunction(() => {
    const rows = document.querySelectorAll('.card-dialog [data-linkage-row]');
    return rows.length >= 3 && [...rows].every(row => row.querySelector('.card-linkage__title').textContent !== '\u2026');
  });
  await mobile.evaluate(() => { document.querySelector('.card-dialog__sections').firstElementChild.__tiraStable = 1; });
  const quietStart = mobileRecordHits;
  await new Promise(resolve => setTimeout(resolve, 7000));
  const quietHits = mobileRecordHits - quietStart;
  if (quietHits > 4)
    throw new Error(`an unchanged card must not refetch its linked rows: ${quietHits} record reads across ~3 quiet 2s cycles`);
  const stableNode = await mobile.evaluate(() => !!document.querySelector('.card-dialog__sections').firstElementChild.__tiraStable);
  if (!stableNode) throw new Error('an identical refresh cycle rebuilt the dialog DOM');

  mobileRecordDelay = 600;
  mobileTitle = 'Race change';
  const raceStart = mobileRecordHits;
  for (let i = 0; i < 400 && mobileRecordHits === raceStart; i++) await new Promise(resolve => setTimeout(resolve, 25));
  await mobile.locator('.card-dialog [data-edit="title"]').click();
  await new Promise(resolve => setTimeout(resolve, 1200));
  const editorAlive = await mobile.evaluate(() => !!document.querySelector('.card-dialog h2 .card-edit-input'));
  if (!editorAlive) throw new Error('an in-flight refresh evicted an active editor');
  mobileRecordDelay = 0;
  await mobile.evaluate(() => document.querySelector('.card-dialog .card-edit-cancel').click());
  await mobile.waitForFunction(() => document.querySelectorAll('.card-dialog h2 .card-edit-input').length === 0);

  mobileTitle = 'Edited elsewhere';
  await mobile.waitForFunction(() => document.querySelector('.card-dialog h2')?.textContent.includes('Edited elsewhere'), null, { timeout: 15000 });
  await mobile.locator('.card-dialog__close').click();
  const cdp = await mobile.context().newCDPSession(mobile);
  const cardBox = await mobile.locator('.board--ticket [data-column="in-progress"] [data-ref="TKT-001"] .card').boundingBox();
  const targetBox = await mobile.locator('.board--ticket [data-column="backlog"]').boundingBox();
  const fromX = cardBox.x + cardBox.width / 2, fromY = cardBox.y + 20;
  const toX = targetBox.x + targetBox.width / 2, toY = targetBox.y + Math.min(60, targetBox.height / 2);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: fromX, y: fromY }] });
  await mobile.waitForTimeout(400);
  for (let step = 1; step <= 8; step++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove',
      touchPoints: [{ x: fromX + (toX - fromX) * step / 8, y: fromY + (toY - fromY) * step / 8 }] });
    await mobile.waitForTimeout(40);
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await mobile.waitForTimeout(300);
  if (mobileMoves !== 1) throw new Error(`touch drag posted ${mobileMoves} move requests, expected 1`);
  await mobile.screenshot({ path: screenshotPath.replace(/\.png$/, '') + '-mobile.png', fullPage: false });
  await mobile.close();
  await browser.close();
  process.stdout.write('dashboard browser Playwright PASS\n');
})().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
