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

// Something happens to the card, through the board's own routes - the way it
// happens when somebody else is working while this page is open.
const fetch_comment = (page, base) => page.evaluate(async ({ base }) => {
  const dialog = document.querySelector('.card-dialog');
  await fetch('/comment/add', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: dialog.dataset.type, ref: dialog.dataset.ref,
                           author: 'michael', text: 'something else happened' }),
  });
}, { base });
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

  // Refreshing every second rather than every minute, because what is being
  // watched here is whether an open work log follows the card - and a test
  // that waits a minute to find out is a test nobody runs.
  await page.goto(base + '/?refresh=1', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.board', { timeout: 8000 });

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

  // --- the work log follows the card --------------------------------------

  // Michael, watching a card he had moved himself: "I still can't see how you
  // moved it to push but it does not show up in the work log." The log fetched
  // once when it was expanded and never again, so a log opened before a move
  // showed the card as it was when it was opened, for as long as the dialog
  // stayed open.
  {
    const before = await page.locator('.card-worklog__entry').count();

    // Something happens to the card while its log is open, the way it does
    // when the agent is working and he is watching.
    await fetch_comment(page, base);

    // Polled rather than waited on, so a failure can say what it saw.
    let after = before;
    for (let tries = 0; tries < 20 && after <= before; tries++) {
      await page.waitForTimeout(750);
      after = await page.locator('.card-worklog__entry').count();
    }
    if (after > before) {
      pass(`an open work log shows what has just happened, without being closed and reopened: ${before} to ${after}`);
    } else {
      fail(`the open work log never noticed the card had changed: still ${after} entries`);
    }

    // Looked at, not only counted. Two defects on this project passed every
    // assertion and were obvious the moment somebody looked at the screen -
    // and a screenshot of the top of a dialog whose work log is at the bottom
    // is a picture of nothing, so it is scrolled to first.
    await page.locator('.card-section--worklog').scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    await page.screenshot({ path: process.env.TIRA_WORKLOG_SHOT || '/tmp/worklog.png' });

    const named = await page.locator('.card-worklog__who').count();
    const rows = await page.locator('.card-worklog__entry').count();
    if (named === rows) pass('and every row has a name cell, so none of them slide out of shape');
    else fail(`only ${named} of ${rows} work log rows carry a name cell`);

    // --- and it can be read on a phone --------------------------------------
    //
    // Same class of defect police-log.js already caught for
    // .card-policelog__detail: the entry is a grid of fixed rem widths, and on
    // a phone the leftover 1fr can be squeezed to a column of single letters -
    // or, on this section, disappear from view entirely. His words, on a
    // screenshot of this exact section: "Why need to hide the details of the
    // event?"
    const phoneContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await phoneContext.addCookies(await context.cookies());
    const phone = await phoneContext.newPage();
    await phone.goto(base, { waitUntil: 'domcontentloaded' });
    await phone.waitForSelector('.board', { timeout: 8000 });
    await phone.locator('.card').first().click();
    await phone.waitForSelector('.card-dialog[open], dialog[open]', { timeout: 5000 }).catch(() => {});
    await phone.locator('.card-worklog__toggle').click();
    await phone.waitForSelector('.card-worklog__entry, .card-worklog__empty', { timeout: 5000 });

    const measured = await phone.evaluate(() => {
      const detail = document.querySelector('.card-worklog__detail');
      const section = document.querySelector('.card-section--worklog');
      return {
        detail: detail ? detail.getBoundingClientRect().width : 0,
        detailVisible: detail ? detail.getBoundingClientRect().height > 0 : false,
        section: section ? section.getBoundingClientRect().width : 0,
      };
    });
    if (!measured.detailVisible) {
      fail('the work log detail column has no rendered height on a phone - it is not visible at all');
    } else if (measured.detail < 150) {
      fail(`the work log detail is ${Math.round(measured.detail)}px wide on a phone - `
        + 'a column of single letters, the same defect already fixed once for the police log');
    } else if (measured.detail > measured.section + 1) {
      fail('the work log detail is wider than the section that holds it');
    } else {
      pass('the work log detail is readable on a phone, not squeezed or hidden');
    }
    await phoneContext.close();
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
