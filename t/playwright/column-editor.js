// The column editor is the only place a person changes the
// board's own shape, so it has to be driven the way a person drives it:
// open it, drag a row by its grip, toggle the eye, type a threshold, add a
// column, remove one, and check that what is sent is what was on screen.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath] = process.argv.slice(2);
if (!htmlPath) {
  console.error('usage: column-editor.js <fixture.html>');
  process.exit(2);
}

const COLUMNS = [
  { name: 'backlog', label: 'Backlog', protected: true, watched: 1, next: ['planning'] },
  { name: 'planning', label: 'Planning', protected: false, watched: 0 },
  { name: 'in-progress', label: 'In Progress', protected: false, watched: 1 },
  { name: 'review', label: 'Review', protected: false, watched: 1, notify_after: 45,
    required_actions: ['Run the suite', 'Update the docs'] },
  { name: 'done', label: 'Done', protected: false, watched: 1 },
  { name: 'discard', label: 'Discard', protected: true, watched: 1 },
];

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };

// A thrown error must report as a failure, not as an unhandled rejection that
// a pipe can swallow. This guard exists to catch regressions, so it has to be
// impossible for it to look green when it did not finish.
process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  let saved = null;

  await page.route('**/*', route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (path === '/columns') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(COLUMNS) });
    }
    if (path === '/columns/apply') {
      saved = JSON.parse(request.postData() || '{}');
      return route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ added: [], removed: [], reordered: true }) });
    }
    if (path === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    if (path === '/people' || path === '/link-types') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  // The board control offers the editor.
  const button = page.locator('.board--ticket .board-columns');
  if (await button.count() !== 1) {
    fail('the ticket board has no Columns button');
    await browser.close();
    return;
  }
  await button.click();
  await page.waitForFunction(() => document.querySelectorAll('.column-row').length > 0);

  const rows = () => page.locator('.column-row').evaluateAll(nodes => nodes.map(n => n.dataset.name));
  const before = await rows();
  if (before.join(',') !== COLUMNS.map(c => c.name).join(',')) {
    fail('the editor did not show the board layout, got ' + before.join(','));
  }

  // Protected columns cannot be removed; the rest can.
  const removable = await page.locator('.column-row__remove').count();
  if (removable !== 4) fail('expected 4 removable columns, got ' + removable);

  // The eye reflects what is stored, off for planning.
  const eyes = await page.locator('.column-row__eye').evaluateAll(
    nodes => nodes.map(n => n.getAttribute('aria-pressed')));
  if (eyes[1] !== 'false') fail('the unwatched column did not show as unwatched');
  if (eyes[2] !== 'true') fail('a watched column did not show as watched');

  // The stored threshold is shown.
  const minutes = await page.locator('.column-row').nth(3).locator('.column-row__minutes').inputValue();
  if (minutes !== '45') fail('the stored threshold was not shown, got ' + minutes);

  // The chain (next) and required-action template are shown for the columns
  // that declared them, and the fields exist but stay empty for the ones
  // that did not - no forced values.
  const backlogNext = await page.locator('.column-row[data-name="backlog"] .column-row__next')
    .evaluate(select => Array.from(select.selectedOptions).map(o => o.value));
  if (backlogNext.join(',') !== 'planning') fail('backlog\'s chain was not shown, got ' + backlogNext.join(','));

  const reviewActions = await page.locator('.column-row[data-name="review"] .column-row__actions').inputValue();
  if (reviewActions !== 'Run the suite\nUpdate the docs') {
    fail('review\'s required-action template was not shown, got ' + JSON.stringify(reviewActions));
  }

  const doneNext = await page.locator('.column-row[data-name="done"] .column-row__next')
    .evaluate(select => Array.from(select.selectedOptions).map(o => o.value));
  if (doneNext.length) fail('a column with no chain declared showed one anyway, got ' + doneNext.join(','));
  const doneActions = await page.locator('.column-row[data-name="done"] .column-row__actions').inputValue();
  if (doneActions !== '') fail('a column with no required-action template declared showed one anyway, got ' + JSON.stringify(doneActions));

  // Drag 'done' above 'review' by its grip, with real pointer events. The
  // rows now carry a chain select and a required-action textarea, so six of
  // them can outgrow the dialog and need a scroll - fetched together, in one
  // synchronous read after scrolling both into view, so a scroll triggered
  // while reading one box can't move the other one the drag was aimed at.
  const doneGrip = page.locator('.column-row[data-name="done"] .column-row__grip');
  const reviewRow = page.locator('.column-row[data-name="review"]');
  const [from, to] = await page.evaluate(() => {
    const grip = document.querySelector('.column-row[data-name="done"] .column-row__grip');
    const row = document.querySelector('.column-row[data-name="review"]');
    row.scrollIntoView({ block: 'center' });
    const g = grip.getBoundingClientRect();
    const r = row.getBoundingClientRect();
    return [
      { x: g.x, y: g.y, width: g.width, height: g.height },
      { x: r.x, y: r.y, width: r.width, height: r.height },
    ];
  });
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(to.x + to.width / 2, to.y + 4, { steps: 12 });
  await page.mouse.up();
  const reordered = await rows();
  if (reordered.indexOf('done') > reordered.indexOf('review')) {
    fail('dragging by the grip did not reorder, got ' + reordered.join(','));
  }

  // Change a threshold, turn an eye on, remove a column, add one, and edit
  // a required-action template.
  await page.locator('.column-row[data-name="in-progress"] .column-row__minutes').fill('90');
  await page.locator('.column-row[data-name="planning"] .column-row__eye').click();
  await page.locator('.column-row[data-name="review"] .column-row__actions').fill('Run the suite\nUpdate the docs\nAdd a Changes entry');
  await page.locator('.column-row[data-name="done"] .column-row__remove').click();
  await page.locator('.column-dialog__new').fill('Waiting On Client');
  await page.locator('.column-dialog__addbtn').click();

  const withNew = await rows();
  if (!withNew.includes('waiting-on-client')) fail('the new column was not added, got ' + withNew.join(','));
  if (withNew[withNew.length - 1] !== 'discard') fail('a new column was placed after Discard');
  if (withNew.includes('done')) fail('the removed column is still listed');

  await page.locator('.column-dialog__save').click();
  await page.waitForFunction(() => true);
  await page.waitForTimeout(300);

  if (!saved) fail('saving sent nothing');
  else {
    const sent = saved.columns.map(c => c.name).join(',');
    if (sent !== withNew.join(',')) fail('what was sent is not what was on screen: ' + sent);
    const progress = saved.columns.find(c => c.name === 'in-progress');
    if (progress.notify_after !== 90) fail('the edited threshold was not sent, got ' + progress.notify_after);
    const planning = saved.columns.find(c => c.name === 'planning');
    if (planning.watched !== 1) fail('turning the eye on was not sent');
    const backlog = saved.columns.find(c => c.name === 'backlog');
    if ('notify_after' in backlog) fail('an empty threshold was sent as a value');
    if (saved.type !== 'ticket') fail('the board type was not sent');
    if ((backlog.next || []).join(',') !== 'planning') fail('backlog\'s untouched chain was not sent back, got ' + JSON.stringify(backlog.next));
    const review = saved.columns.find(c => c.name === 'review');
    if ((review.required_actions || []).join('|') !== 'Run the suite|Update the docs|Add a Changes entry') {
      fail('the edited required-action template was not sent, got ' + JSON.stringify(review.required_actions));
    }
    const doneless = saved.columns.find(c => c.name === 'planning');
    if ('next' in doneless) fail('a column with no chain declared had one forced into the save, got ' + JSON.stringify(doneless.next));
    if ('required_actions' in doneless) fail('a column with no required-action template declared had one forced into the save');
  }

  await browser.close();
  if (!process.exitCode) console.log('column editor: all checks passed');
})().catch(error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});
