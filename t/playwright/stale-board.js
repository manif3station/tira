// A board that cannot become the version installed under it says so.
//
// The version check used to exec from inside the worker serving /data. A worker
// is not the board - the master owns the socket - so it could not bind the port,
// died, and took the request with it. Four boards did that every sixty-five
// seconds for twenty hours and never upgraded; from the page it looked like the
// auto-refresh had stopped working, because the poll returned nothing at all.
//
// Now only the launching process may restart, which under a pre-forked server is
// never the one serving /data. So a served board does not replace itself - and
// has to say so, or the silence is the same silence in a different place.
//
// Driven in a real browser rather than asserted against the HTML, because the
// notice only ever appears as the result of a refresh. Rendering the element is
// not the feature; filling it on a poll is.

const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const [htmlPath, dataPath] = process.argv.slice(2);
  if (!htmlPath || !dataPath) throw new Error('HTML and JSON paths are required');
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');

  const html = fs.readFileSync(htmlPath, 'utf8');
  const base = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  // The version the page was built by. Saying something different would make the
  // page reload rather than paint, and prove nothing about the notice.
  const serving = /data-version="([^"]+)"/.exec(html);
  if (!serving) throw new Error('the page does not say which version built it');
  const version = serving[1];

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  let payload = { ...base, _version: version };
  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/data') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(payload) });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/?refresh=1');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const notice = page.locator('.stale-notice');
  if (await notice.count() !== 1) throw new Error('the board has nowhere to say it is stale');
  if (await notice.isVisible()) throw new Error('a board with nothing to report is saying something');

  // --- a newer Tira is installed under it -----------------------------------

  payload = { ...base, _version: version, _stale: '9.99' };
  await page.waitForFunction(
    () => {
      const element = document.querySelector('.stale-notice');
      return element && !element.hidden && element.textContent.includes('9.99');
    },
    null,
    { timeout: 15000 },
  );

  const said = (await notice.textContent()).trim();
  if (!said.includes('9.99')) throw new Error(`the notice does not name the version: ${said}`);
  if (!/restart/i.test(said)) throw new Error(`the notice does not say what to do: ${said}`);
  console.log(`stale board: the page says "${said}"`);

  // --- and the board is still usable while it says it ------------------------
  //
  // A notice that stopped the board working would be worse than the bug. The
  // cards are still there and still refreshing.

  const cards = await page.locator('.card').count();
  if (cards < 1) throw new Error('the board stopped showing cards while reporting a new version');

  // --- it goes away when there is nothing to say -----------------------------
  //
  // The other half nobody would notice being broken: a board restarted into the
  // new code must stop saying it is behind.

  payload = { ...base, _version: version };
  await page.waitForFunction(
    () => {
      const element = document.querySelector('.stale-notice');
      return element && element.hidden;
    },
    null,
    { timeout: 15000 },
  );

  console.log(`stale board: all checks passed, ${cards} cards still on screen`);
  await browser.close();
})().catch(error => {
  console.error(error.message || error);
  process.exit(1);
});
