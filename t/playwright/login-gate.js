// The login, driven the way a person drives it: arrive at a board you have
// never seen, type a name and a password, and be let in - then be turned away
// again once the session has gone quiet for long enough.
//
// Nothing below reads the markup. The whole point of doing this in a browser
// is that everything up to now has been assertions about a document, and a
// login that renders correctly and cannot be used is a login that does not
// work.
const { chromium } = require('playwright');

const [base] = process.argv.slice(2);
if (!base) {
  console.error('usage: login-gate.js <base-url>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message : error));
  process.exit(1);
});

(async () => {
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();

  // --- a stranger ---------------------------------------------------------

  await page.goto(base, { waitUntil: 'domcontentloaded' });

  const password = page.locator('input[type="password"]');
  if (!(await password.count())) fail('a stranger should see a login page');
  else pass('a stranger arrives at the login page');

  if (await page.locator('.board').count()) fail('and should not see the board behind it');
  else pass('and not the board');

  // The page must not name anybody: it is the one thing outside the gate, and
  // a list of people is half of a login.
  const text = await page.textContent('body');
  for (const name of ['michael', 'claude']) {
    if (text.toLowerCase().includes(name)) fail(`the login page names ${name}`);
  }
  pass('and it names nobody on the project');

  // --- getting it wrong ---------------------------------------------------

  await page.fill('#id_', 'michael');
  await page.fill('#pw', 'not the password');
  await page.click('#go');
  await page.waitForSelector('.msg.bad', { timeout: 5000 });
  const wrong = await page.textContent('.msg.bad');
  pass('a wrong password is refused: ' + wrong.trim());

  // The same message for somebody who does not exist, so the page cannot be
  // used to find out who is on the project.
  await page.fill('#id_', 'nobody-at-all');
  await page.fill('#pw', 'anything');
  await page.click('#go');
  await page.waitForTimeout(300);
  const unknown = await page.textContent('.msg.bad');
  if (unknown.trim() !== wrong.trim()) {
    fail('an unknown person is answered differently from a wrong password');
  } else {
    pass('and an unknown person is answered identically');
  }

  // --- getting it right ---------------------------------------------------

  await page.fill('#id_', 'michael');
  await page.fill('#pw', 'hunter2');
  await page.click('#go');
  await page.waitForSelector('.board', { timeout: 8000 });
  pass('the right password reaches the board');

  const cookies = await context.cookies();
  const session = cookies.find(c => c.name === 'tira_session');
  if (!session) fail('no session cookie was set');
  else if (!session.httpOnly) fail('the session cookie is reachable by scripts');
  else pass('and the session cookie is out of reach of scripts');

  // --- a card, and its work log -------------------------------------------

  const card = page.locator('.card').first();
  if (await card.count()) {
    await card.click();
    await page.waitForSelector('.card-dialog[open], dialog[open]', { timeout: 5000 }).catch(() => {});

    const toggle = page.locator('.card-worklog__toggle');
    if (!(await toggle.count())) {
      fail('the card has no work log section');
    } else {
      const before = await page.locator('.card-worklog__entry').count();
      if (before !== 0) fail('the work log loaded before anybody asked for it');
      else pass('the work log is closed, and has fetched nothing');

      await toggle.click();
      await page.waitForSelector('.card-worklog__entry, .card-worklog__empty', { timeout: 5000 });
      const after = await page.locator('.card-worklog__entry').count();
      pass(`expanding it fetches the log: ${after} entries`);
    }
  }

  // --- a board that loses its session ------------------------------------

  // The owner photographed a board at five in the morning showing where things
  // were the previous day. Its page had been open across the login going in, so
  // every background refresh came back refused - and the page, having nothing
  // to do with a failure, kept drawing the cards it last managed to load.
  // Nothing on screen said it was signed out.
  await page.goto(base + '/?refresh=1', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.board', { timeout: 8000 });
  pass('the board is on screen and refreshing every second');

  // The session goes away underneath it, the way an expiry does.
  await context.clearCookies();

  await page.waitForSelector('input[type="password"]', { timeout: 15000 })
    .then(() => pass('and when a refresh is refused, the sign-in appears'))
    .catch(() => fail('the board kept showing old cards after losing its session'));

  if (await page.locator('.board').count()) {
    fail('the stale board is still on screen behind the sign-in');
  } else {
    pass('with the board it can no longer vouch for taken off the screen');
  }

  await page.screenshot({ path: process.env.TIRA_SHOT || '/tmp/signed-out.png' });

  await browser.close();
  if (!process.exitCode) console.log('all browser checks passed');
})();
