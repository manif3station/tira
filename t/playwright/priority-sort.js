// A column really reorders by priority, in a browser, and still does after the
// board rebuilds itself.
//
// He asked for it with a screenshot of the two buttons the board had: "add 1
// more by prioity". Priority is the field the whole board is arranged around,
// and it was the one thing a column could not be ordered by.
//
// Driven here rather than asserted against the markup for two reasons. Clicking
// is the feature - a button that renders and does not reorder is the dead
// control t/121 exists to prevent. And the board rebuilds every card from the
// payload a minute later, so a sort that survives only until the first refresh
// is exactly the shape of defect this project keeps finding: it works on the
// path anybody checks and not on the one nobody does.

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

  // Priorities put on the board's own cards, so the fixture is the board rather
  // than a shape invented beside it.
  const columns = board.ticket || {};
  const busiest = Object.keys(columns).sort((a, b) => columns[b].length - columns[a].length)[0];
  const cards = columns[busiest] || [];
  if (cards.length < 3) throw new Error(`the fixture board needs three cards in one column, ${busiest} has ${cards.length}`);

  // Deliberately not in reference order, and one left unassessed.
  cards[0].priority = 2;
  cards[1].priority = 5;
  cards[2].priority = null;
  for (const spare of cards.slice(3)) spare.priority = 1;
  const wanted = [cards[1].ref, cards[0].ref];
  const unassessed = cards[2].ref;

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

  // Every list on the page, then the one holding the cards this is about. An
  // empty selector does not throw - it returns nothing - so guessing at the
  // column's own attribute would have looked like a passing sort of no cards.
  const order = async () => {
    const lists = await page.$$eval('.cards', hosts =>
      hosts.map(host => [...host.children].map(item => item.dataset.ref)));
    return lists.find(list => list.includes(wanted[0])) || [];
  };

  const seenPriorities = async () => page.$$eval('.cards > li',
    items => items.map(item => `${item.dataset.ref}=${item.dataset.priority}`));

  // The button on the ticket board, not the first one on the page. There are
  // three boards - statements of work, epics and tickets - each with its own
  // sorter, and each click sorts its own board while setting the mode for all
  // of them. Clicking the first and asserting on the third read as a sort that
  // did nothing.
  const button = page.locator('.board[data-type="ticket"] [data-sort="priority"]').first();
  if (await button.count() === 0) throw new Error('the ticket board offers no priority sort');

  // The priorities live in the payload, and the page is first painted from the
  // server's own HTML - where these cards have none. Clicking before the first
  // refresh sorted a board with no priorities on it and reported the fallback
  // order as a failure, which is the test being wrong rather than the sort.
  await page.waitForFunction(
    highest => {
      const card = document.querySelector(`.cards > li[data-ref="${highest}"]`);
      return card && card.dataset.priority === '5';
    },
    wanted[0],
    { timeout: 15000 },
  ).catch(async () => {
    throw new Error(`the payload never reached the cards: ${(await seenPriorities()).slice(0, 6).join(' ')}`);
  });

  await button.click();
  await page.waitForTimeout(200);

  const sorted = await order();
  const seen = sorted.filter(ref => wanted.includes(ref));
  if (seen.join(',') !== wanted.join(',')) {
    const mode = await page.evaluate(() => document.documentElement.dataset.sort);
    throw new Error(`highest first was not honoured: wanted ${wanted.join(',')}, saw ${seen.join(',')}`
      + ` (mode=${mode}, priorities ${(await seenPriorities()).join(' ')})`);
  }
  if (sorted.indexOf(unassessed) < sorted.indexOf(wanted[wanted.length - 1])) {
    throw new Error('a card nobody has prioritised was not put last');
  }
  console.log(`priority sort: ${sorted.length} cards ordered, highest first, unassessed last`);

  // --- and it survives the board rebuilding itself -------------------------------
  //
  // The refresh replaces every card from the payload. If the rebuilt card does
  // not carry its priority, the ordering is right until a minute passes.

  await page.waitForFunction(
    () => document.documentElement.dataset.sort === 'priority',
    null,
    { timeout: 5000 },
  );
  await page.waitForTimeout(1600);

  const carried = await page.$$eval('.cards > li', items =>
    items.map(item => ({ ref: item.dataset.ref, priority: item.dataset.priority })));
  const rebuilt = carried.find(card => card.ref === wanted[0]);
  if (!rebuilt) throw new Error('the highest card vanished across a refresh');
  if (rebuilt.priority !== '5') {
    throw new Error(`a rebuilt card lost its priority: ${JSON.stringify(rebuilt)}`);
  }

  console.log('priority sort: all checks passed, and a rebuilt card still knows its priority');
  await browser.close();
})().catch(error => {
  console.error(error.message || error);
  process.exit(1);
});
