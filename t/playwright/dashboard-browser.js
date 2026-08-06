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
    solution_needed: 'Sectioned dialog', source: 'DD-406', priority: 5,
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
      { sha: 'a'.repeat(64), extension: 'txt', original_filename: 'notes.txt', added_at: '2026-08-02T10:00:00+0100' },
      { sha: 'f'.repeat(64), extension: 'mp4', original_filename: 'clip.mp4', added_at: '2026-08-01T10:00:00+0100' },
      { sha: '9'.repeat(64), extension: 'tiff', original_filename: 'scan.tiff', added_at: '2026-08-01T09:00:00+0100' },
      { sha: 'e'.repeat(64), extension: 'txt', original_filename: 'fresh.txt', added_at: '2026-08-05T10:00:00+0100' }],
    subtasks: [],
    linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: ['TKT-005'], links: [{ type: 'blocks', ref: 'TKT-009' }] },
    comments: [
      { id: 'CMT-001', author: 'ada', format: 'markdown', body: 'First **bold** comment',
        attachments: [{ sha: 'b'.repeat(64), extension: 'png', original_filename: 'diagram.png', added_at: '2026-08-04T10:00:00+0100' }],
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
  const mutations = [];
  await page.route('http://tira.test/**', async route => {
    const requestUrl = new URL(route.request().url());
    if (requestUrl.pathname === '/move' && route.request().method() === 'POST') {
      moveRequests++;
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    }
    if (requestUrl.pathname === '/record') {
      detailRequests++;
      const askedRef = requestUrl.searchParams.get('ref') || 'TKT-001';
      const served = { ...record, ref: askedRef, title: askedRef === 'TKT-001' ? record.title : 'Resident card' };
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(served) });
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
    if (requestUrl.pathname === '/update' && route.request().method() === 'POST') {
      mutations.push({ path: '/update', body: JSON.parse(route.request().postData()) });
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
    pageRequests++;
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.goto('http://tira.test/?refresh=30');
  await page.waitForFunction(() => document.querySelector('.last-updated')?.textContent !== 'Last updated: pending');
  await page.waitForFunction(() => document.querySelector('[data-column="in-progress"] [data-ref="TKT-001"]'));
  if (pageRequests !== 1 || dataRequests !== 1) throw new Error(`unexpected requests page=${pageRequests} data=${dataRequests}`);
  if (JSON.parse(data).ticket['in-progress'][0].description) throw new Error('lightweight data leaked full record fields');
  if (await page.evaluate(() => window.__tiraTimerDelay) !== 30000) throw new Error('custom refresh interval was not scheduled');
  const backlogOrder = await page.locator('[data-column="backlog"] li').evaluateAll(nodes => nodes.map(node => node.dataset.ref + ':' + node.dataset.mtime));
  if (backlogOrder.length !== 2 || !backlogOrder[0].startsWith('TKT-003') || backlogOrder.some(entry => entry.endsWith(':0')))
    throw new Error(`last-modified sort broken after refresh: ${JSON.stringify(backlogOrder)}`);
  const dragFrom = await page.locator('[data-column="in-progress"] .card').boundingBox();
  const dragTo = await page.locator('[data-column="backlog"]').boundingBox();
  const boardBox = await page.locator('.board--ticket').boundingBox();
  await page.mouse.move(dragFrom.x + dragFrom.width / 2, dragFrom.y + 15);
  await page.mouse.down();
  // drop BELOW the column's content but inside the board stripe: the exact
  // dead zone that bounced drops on populated columns (DD-413)
  await page.mouse.move(dragTo.x + dragTo.width / 2, boardBox.y + boardBox.height - 25, { steps: 8 });
  const midDrag = await page.evaluate(() => ({ ghost: document.querySelectorAll('.card--ghost').length, target: document.querySelectorAll('.is-drop-target').length }));
  await page.mouse.up();
  await page.waitForFunction(() => document.querySelectorAll('.card--ghost').length === 0);
  if (midDrag.ghost !== 1 || midDrag.target !== 1) throw new Error(`drag affordances missing mid-drag: ${JSON.stringify(midDrag)}`);
  if (moveRequests !== 1) throw new Error(`drag move request missing: ${moveRequests}`);
  for (let i = 0; i < 80 && dataRequests < 2; i++) await new Promise(resolve => setTimeout(resolve, 25));
  if (dataRequests < 2) throw new Error('post-drag refresh never fetched /data');
  await page.evaluate(() => new Promise(requestAnimationFrame));

  const seq = () => page.evaluate(() => window.__tiraMutationSeq || 0);
  let before = 0;
  await page.locator('[data-ref="TKT-001"] .card').click();
  await page.waitForFunction(() => document.querySelector('.card-dialog')?.open);
  if (detailRequests !== 1) throw new Error(`lazy detail request missing: ${detailRequests}`);

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
  if (detailRequests < 2) throw new Error('a saved edit did not re-read the record');

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
  await page.locator('.card-dialog .card-comment-form select[name="author"]').selectOption('ada');
  await page.locator('.card-dialog .card-comment-form textarea[name="text"]').fill('A **new** comment');
  await page.locator('.card-dialog .card-comment-form button[type="submit"]').click();
  await page.waitForFunction(() => window.__tiraLastMutation === '/comment/add');
  const added = mutations.find(entry => entry.path === '/comment/add');
  if (!added || added.body.author !== 'ada' || added.body.text !== 'A **new** comment' || added.body.ref !== 'TKT-001')
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
  await page.locator('.card-viewer__close').click();
  await page.waitForSelector('.card-viewer', { state: 'hidden' });

  page.once('dialog', dialog => dialog.accept());
  await page.locator(`.card-dialog [data-detach-attachment="${'a'.repeat(64)}.txt"]`).click();
  await page.waitForFunction(() => window.__tiraLastMutation === '/attachment/remove');
  const detached = mutations.find(entry => entry.path === '/attachment/remove');
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
  await page.locator('.card-dialog [data-link-remove="blocks:TKT-009"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const linkRemove = mutations.find(e => e.path === '/link/remove');
  if (!linkRemove || linkRemove.body.from !== 'TKT-001' || linkRemove.body.type !== 'blocks' || linkRemove.body.to !== 'TKT-009')
    throw new Error(`unexpected link remove payload: ${JSON.stringify(linkRemove && linkRemove.body)}`);

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
  await page.locator('.card-dialog [data-linkage-unlink="sub_ticket_refs:TKT-005"]').click();
  await page.waitForFunction(prev => (window.__tiraMutationSeq || 0) > prev, before);
  const subUnlink = mutations.find(e => e.path === '/subitem/unlink');
  if (!subUnlink || subUnlink.body.parent !== 'TKT-001' || subUnlink.body.child !== 'TKT-005')
    throw new Error(`unexpected subitem unlink payload: ${JSON.stringify(subUnlink && subUnlink.body)}`);

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
  await mobile.route('http://tira.test/record**', async route => {
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ...record, title: mobileTitle }) });
  });
  let mobileMoves = 0;
  await mobile.route('http://tira.test/move', async route => {
    mobileMoves++;
    return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
  });
  await mobile.goto('http://tira.test/');
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
  mobileTitle = 'Edited elsewhere';
  await mobile.waitForFunction(() => document.querySelector('.card-dialog h2')?.textContent.includes('Edited elsewhere'), null, { timeout: 15000 });
  await mobile.locator('.card-dialog__close').click();
  const cdp = await mobile.context().newCDPSession(mobile);
  const cardBox = await mobile.locator('[data-column="in-progress"] [data-ref="TKT-001"] .card').boundingBox();
  const targetBox = await mobile.locator('[data-column="backlog"]').boundingBox();
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
