// Fit all used to squeeze every column onto one row, so thirteen
// columns meant 81px each - readable arithmetic, unreadable board. Fit now
// wraps them onto as many rows as it takes at a usable minimum width. Standard
// must be unchanged: one row, full-width columns, horizontal scroll.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath] = process.argv.slice(2);
if (!htmlPath) { console.error('usage: wrap-board.js <fixture.html>'); process.exit(2); }
const fail = m => { console.error('FAIL: ' + m); process.exitCode = 1; };
process.on('unhandledRejection', e => { console.error('FAIL: ' + (e && e.message || e)); process.exit(1); });

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  await page.route('**/*', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    if (path === '/people' || path === '/link-types' || path === '/columns') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const geometry = () => page.locator('.board--ticket .column').evaluateAll(nodes =>
    nodes.map(n => { const b = n.getBoundingClientRect(); return { top: Math.round(b.top), width: Math.round(b.width), right: Math.round(b.right) }; }));
  const spills = () => page.evaluate(() => {
    const found = [];
    document.querySelectorAll('.board--ticket .column').forEach(column => {
      const edge = column.getBoundingClientRect().right;
      column.querySelectorAll('.card').forEach(card => {
        const over = Math.round(card.getBoundingClientRect().right - edge);
        if (over > 1) found.push(over);
      });
    });
    return found;
  });

  // Standard: one row, full width columns, scrolled horizontally.
  const standard = await geometry();
  if (standard.length < 10) fail('expected a wide board, got ' + standard.length + ' columns');
  if (new Set(standard.map(c => c.top)).size !== 1) fail('standard mode must keep every column on one row');
  if (standard.some(c => c.width < 200)) fail('standard columns must keep their full width, got ' + standard.map(c => c.width));
  const standardSpill = await spills();
  if (standardSpill.length) fail('cards spill their column in standard mode: ' + standardSpill);

  // Fit: wrapped onto more than one row, each still readable.
  await page.locator('.board--ticket [data-width="fit"]').click();
  await page.waitForTimeout(150);
  const fit = await geometry();
  const rows = new Set(fit.map(c => c.top));
  if (rows.size < 2) fail('fit mode did not wrap: every column is still on one row');
  if (fit.some(c => c.width < 140)) fail('a wrapped column is narrower than the readable minimum, got ' + fit.map(c => c.width));
  if (fit.some(c => c.right > 1281)) fail('fit mode still runs off the right edge');
  const fitSpill = await spills();
  if (fitSpill.length) fail('cards spill their column in fit mode: ' + fitSpill);

  // The preference still persists, and standard still comes back.
  await page.locator('.board--ticket [data-width="standard"]').click();
  await page.waitForTimeout(150);
  const back = await geometry();
  if (new Set(back.map(c => c.top)).size !== 1) fail('switching back to standard did not unwrap');

  await browser.close();
  if (!process.exitCode) console.log('wrap board: all checks passed, ' + rows.size + ' rows in fit mode');
})();
