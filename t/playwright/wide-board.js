// DD-451 guard. The main browser fixture has two columns, and with only two
// columns a broken column width is invisible: the table is narrower than the
// viewport either way. This board has nine, which is what the owner runs and
// what exposed the defect.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath, screenshotPath] = process.argv.slice(2);
if (!htmlPath) {
  console.error('usage: wide-board.js <fixture.html> [screenshot.png]');
  process.exit(2);
}

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
  await page.route('**/*', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const columnWidths = () => page.locator('.board--ticket th').evaluateAll(
    nodes => nodes.map(node => Math.round(node.getBoundingClientRect().width)));
  const spills = () => page.evaluate(() => {
    const found = [];
    document.querySelectorAll('.board--ticket td').forEach(cell => {
      const edge = cell.getBoundingClientRect().right;
      cell.querySelectorAll('.card').forEach(card => {
        const over = Math.round(card.getBoundingClientRect().right - edge);
        if (over > 1) found.push(over);
      });
    });
    return found;
  });

  const widths = await columnWidths();
  if (widths.length < 9) throw new Error(`expected a nine-column board, got ${widths.length}`);
  // 17rem is the standard column width; anything less means the fixed table
  // layout divided the space instead of honouring it.
  if (widths.some(width => width < 272))
    throw new Error(`standard columns must keep their full width, got ${JSON.stringify(widths)}`);
  let over = await spills();
  if (over.length) throw new Error(`cards spilled into the next column by ${JSON.stringify(over)}px`);

  await page.locator('[data-width="fit"]').first().click();
  await page.waitForFunction(() => document.documentElement.dataset.width === 'fit');
  const fitted = await columnWidths();
  if (fitted.some(width => width >= 272))
    throw new Error(`fit mode must shrink the columns, got ${JSON.stringify(fitted)}`);
  const boardOverflow = await page.locator('.board--ticket .board__scroll')
    .evaluate(node => node.scrollWidth - node.clientWidth);
  if (boardOverflow > 1) throw new Error(`fit mode must remove sideways scrolling, over by ${boardOverflow}px`);
  over = await spills();
  if (over.length) throw new Error(`cards spilled in fit mode by ${JSON.stringify(over)}px`);

  // DD-456: a column shows ten cards and offers the rest in batches.
  const visibleCards = column => page.locator(`[data-column="${column}"] > li:not([hidden])`).count();
  const backlogTotal = await page.locator('[data-column="backlog"] > li').count();
  if (backlogTotal <= 10) throw new Error(`this fixture needs more than ten cards to page, has ${backlogTotal}`);
  if (await visibleCards('backlog') !== 10)
    throw new Error(`a column must start with ten cards, showing ${await visibleCards('backlog')}`);
  const moreLabel = await page.locator('[data-more-for="backlog"]').textContent();
  if (!/Show \d+ more of \d+/.test(moreLabel))
    throw new Error(`the reveal button must say how many remain, got "${moreLabel}"`);
  if (await page.locator('[data-more-for="planning"]').evaluate(node => node.hidden) !== true)
    throw new Error('a column with nothing hidden must not offer to show more');
  await page.locator('[data-more-for="backlog"]').click();
  const revealed = await visibleCards('backlog');
  if (revealed !== Math.min(20, backlogTotal))
    throw new Error(`revealing must add ten more, showing ${revealed} of ${backlogTotal}`);
  const badge = await page.locator('[data-count-for="backlog"]').textContent();
  if (badge !== String(backlogTotal))
    throw new Error(`the count must stay the column total, got ${badge} for ${backlogTotal}`);

  if (screenshotPath) await page.screenshot({ path: screenshotPath });
  await browser.close();
  console.log('wide board Playwright PASS');
})().catch(error => { console.error(`Error: ${error.message}`); process.exit(1); });
