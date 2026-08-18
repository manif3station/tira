// A card worked recently is greener than one that has sat, in a real browser.
//
// His words: "to know progress on the board is easy. update the html dashboard.
// any cards the last updates timestamp is more recent is green, then older is
// the current colour. Except the questioned cards."
//
// He asked it after looking at the board and saying "board stall, are you
// working on something untracked?" while two cards were being actively gated.
// That is the whole problem: a card being worked and a card abandoned for six
// hours look identical.
//
// Recent compared to what was the one thing worth asking, and he answered it
// with a comparator rather than a threshold: `-M $b.json <=> -M $a.json`. So the
// ranking is relative to the other cards in the column and read from the file's
// modification time, which is already on every card as data-mtime and is already
// what the default sort orders by. A comparator answer means a fade down the
// ranking rather than one green band.
//
// Driven in a browser rather than asserted against the markup, for the reason
// priority-sort.js gives: the board rebuilds every card from the payload a
// minute later, so a treatment that survives only the first paint is the shape
// of defect this project keeps finding.

const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const [htmlPath, dataPath] = process.argv.slice(2);
  if (!htmlPath || !dataPath) throw new Error('HTML and JSON paths are required');
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');

  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const columns = board.ticket || {};
  const busiest = Object.keys(columns).sort((a, b) => columns[b].length - columns[a].length)[0];
  const cards = columns[busiest] || [];
  if (cards.length < 3) throw new Error(`the fixture board needs three cards in one column, ${busiest} has ${cards.length}`);

  // Distinct, known modification times, newest first. _mtime is seconds - the
  // page multiplies it by a thousand - so a minute apart is unambiguous however
  // the clock is read.
  const base = 1760000000;
  cards[0]._mtime = base;          // newest
  cards[1]._mtime = base - 3600;
  cards[2]._mtime = base - 7200;   // oldest of the three
  for (const spare of cards.slice(3)) spare._mtime = base - 86400;

  // The exclusion he named. A card carrying an unanswered question is painted
  // yellow already, and he said those keep what they have.
  cards[1].waiting = true;

  const newest = cards[0].ref;
  const stalest = cards.length > 3 ? cards[cards.length - 1].ref : cards[2].ref;
  const questioned = cards[1].ref;

  const payload = JSON.stringify(board);
  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/data') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: payload });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/?refresh=1');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  // Read after the first refresh, for the reason priority-sort.js records: the
  // page is first painted from the server's own HTML and rebuilt from the
  // payload, and a treatment that only survives the first paint is the defect.
  await page.waitForFunction(
    ref => !!document.querySelector(`.cards > li[data-ref="${ref}"]`), newest);

  const freshness = async ref => page.$eval(
    `.cards > li[data-ref="${ref}"]`,
    item => item.style.getPropertyValue('--fresh').trim());

  const fresh = await freshness(newest);
  if (fresh !== '1') throw new Error(`the newest card should be fully fresh, got --fresh=${JSON.stringify(fresh)}`);

  const stale = await freshness(stalest);
  if (stale !== '0') throw new Error(`the oldest card should carry no green, got --fresh=${JSON.stringify(stale)}`);

  // His exception, and the one that must not be traded away for the effect.
  const held = await freshness(questioned);
  if (held !== '') throw new Error(`a questioned card must take no green, got --fresh=${JSON.stringify(held)}`);

  const stillYellow = await page.$eval(`.cards > li[data-ref="${questioned}"] .card`,
    node => node.classList.contains('card--waiting'));
  if (!stillYellow) throw new Error('a questioned card lost its waiting treatment');

  console.log(`card freshness: newest ${newest} at 1, oldest ${stalest} at 0, questioned ${questioned} untouched`);

  // --- proved by making every card the same age -------------------------------
  //
  // A ranking of ties says nothing, and painting one would be inventing a
  // difference the board cannot see. This is the half that stops the effect
  // being decorative.
  for (const card of cards) card._mtime = base;
  await page.route('http://tira.test/data', route =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(board) }));
  await page.reload();
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.waitForFunction(
    ref => !!document.querySelector(`.cards > li[data-ref="${ref}"]`), newest);

  const tied = await page.$$eval('.cards > li',
    items => items.map(item => item.style.getPropertyValue('--fresh').trim()).filter(Boolean));
  const distinct = [...new Set(tied)];
  if (distinct.length > 1) {
    throw new Error(`cards of identical age must not be ranked against each other, got ${JSON.stringify(distinct)}`);
  }

  console.log('card freshness: all checks passed, and cards of one age are not ranked');
  await browser.close();
})().catch(error => {
  console.error(error.message);
  process.exit(1);
});
