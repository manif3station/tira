// TKT-952: his report, two screenshots (readonly card and edit dialog), both
// showing a tall empty column on the right of a job card that has never
// fired (JOB-003) - roughly a third of the card's width, doing nothing.
//
// The live page, not a static export: jobs-editor.js (which builds
// .jobs-card from /jobs) is only embedded when the page is rendered with
// live=>1 - a static dashboard export ships an empty <ol class="jobs-cards">
// and none of the script that would fill it, so this needs the real thing.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath, dataPath] = process.argv.slice(2);
if (!htmlPath || !dataPath) {
  console.error('usage: job-card-empty-column.js <fixture.html> <board.json>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('  ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

// JOB-003's actual shape: a command job that has never fired. No
// last_run_at, no recent output, not running - exactly what ruled out the
// output-panel explanation in his report.
const JOBS = [{
  id: 'JOB-003', enabled: true, mode: 'command', schedule: '0 6 * * *',
  schedule_words: 'at 06:00 every day', schedule_kind: 'cron',
  command: 'd2 tira.backup', message: null, running: false,
  last_run_at: null, last_due_at: null, last_output_at: null,
  expect_every: null, restart_every: null, recent: [],
}];

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  page.on('pageerror', error => console.error('PAGE ERROR: ' + error.message));

  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(board) });
    if (url.pathname === '/jobs') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(JOBS) });
    if (url.pathname === '/people' || url.pathname === '/link-types') return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.waitForSelector('.jobs-card[data-job="JOB-003"]');

  // --- readonly: no dead strip on the right ------------------------------

  const readonlyGap = await page.locator('.jobs-card[data-job="JOB-003"]').evaluate(card => {
    const cardBox = card.getBoundingClientRect();
    const kids = Array.from(card.children).filter(child => child.offsetParent !== null && !child.hidden);
    const rightmostContentEdge = Math.max(...kids.map(child => child.getBoundingClientRect().right));
    return cardBox.right - rightmostContentEdge;
  });
  // A little padding is expected (the card itself has padding:.9rem, ~14px);
  // anything past that is the reported dead strip.
  if (readonlyGap > 20) {
    fail(`the readonly job card reserves ${Math.round(readonlyGap)}px past its rightmost visible control - the strip his screenshot showed`);
  } else {
    pass(`the readonly job card's content reaches within ${Math.round(readonlyGap)}px of its right edge`);
  }

  // --- the message/command text uses the width the strip was holding -----

  const whatWidth = await page.locator('.jobs-card[data-job="JOB-003"] .jobs-card__what').evaluate(node => node.getBoundingClientRect().width);
  const cardWidth = await page.locator('.jobs-card[data-job="JOB-003"]').evaluate(node => node.getBoundingClientRect().width);
  if (whatWidth < cardWidth * 0.55) {
    fail(`the command text column is only ${Math.round(whatWidth)}px of a ${Math.round(cardWidth)}px card - still narrow, the strip was not reclaimed`);
  } else {
    pass(`the command text uses ${Math.round(whatWidth)}px of the ${Math.round(cardWidth)}px card`);
  }

  // --- the edit dialog: the same strip, his second screenshot -------------

  await page.click('.jobs-card[data-job="JOB-003"] .jobs-card__edit');
  await page.waitForSelector('.jobs-editor');

  const editorGap = await page.locator('.jobs-editor').evaluate(editor => {
    const editorBox = editor.getBoundingClientRect();
    const kids = Array.from(editor.querySelectorAll('*')).filter(
      child => child.offsetParent !== null && !child.hidden && child.getBoundingClientRect().width > 0);
    const rightmostContentEdge = Math.max(...kids.map(child => child.getBoundingClientRect().right));
    return editorBox.right - rightmostContentEdge;
  });
  if (editorGap > 20) {
    fail(`the edit dialog also reserves ${Math.round(editorGap)}px past its rightmost visible field - his second screenshot`);
  } else {
    pass(`the edit dialog's content reaches within ${Math.round(editorGap)}px of its right edge`);
  }

  await browser.close();
})();
