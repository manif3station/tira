// The toggle hides cards, so it has to hide exactly the right ones: a filter
// that quietly drops work is worse than no filter.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath] = process.argv.slice(2);
if (!htmlPath) { console.error('usage: review-toggle.js <fixture.html>'); process.exit(2); }
const fail = m => { console.error('FAIL: ' + m); process.exitCode = 1; };
process.on('unhandledRejection', e => { console.error('FAIL: ' + (e && e.message || e)); process.exit(1); });

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  await page.route('**/*', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    if (['/people', '/link-types', '/columns'].includes(path)) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const visible = () => page.locator('.board--ticket .cards > li:not([hidden])').evaluateAll(
    nodes => nodes.map(n => n.dataset.ref));
  const toReview = () => page.locator('.board--ticket .card--to-review').evaluateAll(
    nodes => nodes.map(n => n.dataset.ref));

  const everything = await visible();
  const reviewable = await toReview();
  if (everything.length !== 6) fail('expected six cards to start with, got ' + everything.length);
  if (reviewable.length !== 2) fail('expected two cards awaiting judgement, got ' + reviewable.length);

  // Off by default: a board must show all the work until somebody narrows it.
  const button = page.locator('.board--ticket .board-review');
  if (await button.count() !== 1) { fail('the board control has no review toggle'); await browser.close(); return; }
  if (await button.getAttribute('aria-pressed') !== 'false') fail('the toggle should start off');

  await button.click();
  await page.waitForTimeout(150);
  const narrowed = await visible();
  if (narrowed.length !== reviewable.length)
    fail('expected only the reviewable cards, got ' + narrowed.join(',') );
  if (narrowed.sort().join(',') !== reviewable.sort().join(','))
    fail('the wrong cards survived: ' + narrowed.join(',') + ' vs ' + reviewable.join(','));
  if (await button.getAttribute('aria-pressed') !== 'true') fail('the toggle did not report itself on');

  // The counts must agree with what is on screen, or one of them is lying.
  const counts = await page.locator('.board--ticket .column__count:not([hidden])').evaluateAll(
    nodes => nodes.reduce((sum, n) => sum + Number(n.textContent || 0), 0));
  if (counts !== narrowed.length) fail('counts say ' + counts + ' but ' + narrowed.length + ' are shown');

  await button.click();
  await page.waitForTimeout(150);
  const restored = await visible();
  if (restored.length !== everything.length) fail('switching off did not restore every card');

  await browser.close();
  if (!process.exitCode) console.log('review toggle: all checks passed (' + reviewable.length + ' of ' + everything.length + ')');
})();
