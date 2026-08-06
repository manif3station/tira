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
  let pageRequests = 0;
  let dataRequests = 0;
  await page.route('http://tira.test/**', async route => {
    if (new URL(route.request().url()).pathname === '/data') {
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
  if (await page.evaluate(() => window.__tiraTimerDelay) !== 30000) throw new Error('custom refresh interval was not scheduled');
  await page.locator('[data-ref="TKT-001"] .card').click();
  if (!await page.locator('.card-dialog').evaluate(dialog => dialog.open)) throw new Error('card detail dialog did not open');
  const detail = await page.locator('.card-dialog pre').textContent();
  if (!detail.includes('Live browser card') || !detail.includes('Full popup detail')) throw new Error('full card detail is missing');
  await page.screenshot({ path: screenshotPath, fullPage: true });
  await browser.close();
  process.stdout.write('dashboard browser Playwright PASS\n');
})().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
