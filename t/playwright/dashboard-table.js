const { chromium } = require('playwright-core');
const path = require('path');
const fs = require('fs');

(async () => {
  const htmlPath = process.argv[2];
  const screenshotPath = process.argv[3];
  if (!htmlPath || !screenshotPath) throw new Error('HTML and screenshot paths are required');
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    args: ['--no-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  await page.addInitScript(() => {
    window.setTimeout = (_callback, delay) => {
      window.__tiraTimerDelay = delay;
      return 1;
    };
  });
  const url = `file://${path.resolve(htmlPath)}`;
  const assertRefresh = async (query, seconds, delay) => {
    await page.goto(`${url}${query}`);
    const state = await page.evaluate(() => ({
      seconds: document.documentElement.dataset.refresh,
      delay: window.__tiraTimerDelay,
      text: document.querySelector('.refresh-status')?.textContent || '',
    }));
    if (state.seconds !== String(seconds) || state.delay !== delay || !state.text.includes(`${seconds}s`)) {
      throw new Error(`unexpected refresh state ${JSON.stringify(state)}`);
    }
    if (!await page.locator('.last-updated').textContent()) throw new Error('last-updated timestamp is missing');
  };
  await assertRefresh('', 5, 5000);
  await assertRefresh('?refresh=invalid', 5, 5000);
  await assertRefresh('?refresh=0', 1, 1000);
  await assertRefresh('?refresh=60', 60, 60000);
  if (await page.locator('.board').count() !== 1) throw new Error('expected one type-specific board');
  const headers = page.locator('.column__head');
  if (await headers.count() < 2) throw new Error('expected at least two columns');
  const first = await headers.nth(0).boundingBox();
  const second = await headers.nth(1).boundingBox();
  if (!first || !second || second.x <= first.x) throw new Error('columns are not left-to-right');
  const background = await page.locator('body').evaluate(el => getComputedStyle(el).backgroundImage);
  if (!background.includes('gradient')) throw new Error('gradient design is missing');
  const radius = parseFloat(await page.locator('.board').evaluate(el => getComputedStyle(el).borderRadius));
  if (radius < 16) throw new Error('board styling is unexpectedly plain');
  const card = page.locator('.card').first();
  await card.click();
  if (!await card.evaluate(el => el.classList.contains('is-selected'))) throw new Error('card selection failed');
  await page.locator('[data-sort="ref"]').click();
  if (await page.evaluate(() => document.documentElement.dataset.sort) !== 'ref') throw new Error('ref sorting failed');
  await page.locator('[data-sort="mtime"]').click();
  if (await page.evaluate(() => document.documentElement.dataset.sort) !== 'mtime') throw new Error('mtime sorting failed');
  if (await page.locator('link, img, iframe').count()) throw new Error('external resource found');
  await page.screenshot({ path: screenshotPath, fullPage: true });
  await browser.close();
  process.stdout.write('dashboard table Playwright PASS\n');
})().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
