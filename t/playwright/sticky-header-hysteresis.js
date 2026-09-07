// TKT-955: his screen recording, 2026-09-05 - scrolling to the top and then
// down a little makes the sticky header shake, right at the point it tries
// to shrink. A single threshold (scrollY > 24) toggling a class that changes
// the header's own height is a feedback loop: compacting shortens the page,
// which can put scrollY back under 24, expanding it again, in the same
// scroll gesture.
//
// Driven the way he found it: scroll to the exact pixel that used to
// oscillate and hold there, watching for more than one class change.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath] = process.argv.slice(2);
if (!htmlPath) {
  console.error('usage: sticky-header-hysteresis.js <fixture.html>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('  ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.route('**/*', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const hero = page.locator('.hero');
  if (await hero.count() === 0) throw new Error('this fixture has no .hero header to test');

  // A spacer, so this test does not depend on the fixture happening to have
  // enough content below the fold - the defect is about the threshold logic,
  // not about how many cards a particular board fixture carries.
  await page.evaluate(() => {
    const spacer = document.createElement('div');
    spacer.style.height = '4000px';
    document.body.appendChild(spacer);
  });

  // --- the exact shake: hold at a point that used to oscillate ------------

  // exposeFunction cannot be registered twice on one page, so the counter
  // lives in a Playwright-side variable the exposed function closes over,
  // reset before each scroll rather than re-exposed each time.
  let heroClassChanges = 0;
  await page.exposeFunction('tiraNoteHeroClassChange', () => { heroClassChanges++; });

  const countClassChanges = async atY => {
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(50);
    heroClassChanges = 0;
    await page.evaluate(() => {
      const hero = document.querySelector('.hero');
      window.__tiraHeroObserver = new MutationObserver(() => window.tiraNoteHeroClassChange());
      window.__tiraHeroObserver.observe(hero, { attributes: true, attributeFilter: ['class'] });
    });
    await page.evaluate(y => window.scrollTo(0, y), atY);
    // Scroll is a passive listener; give the browser a moment to settle any
    // reflow-triggered re-entry before reading the tally.
    await page.waitForTimeout(150);
    await page.evaluate(() => window.__tiraHeroObserver.disconnect());
    return heroClassChanges;
  };

  for (const y of [20, 24, 28, 40, 60]) {
    const changes = await countClassChanges(y);
    if (changes > 1) {
      fail(`scrolling to y=${y}px changed the hero's class ${changes} times - this is the shake his recording showed`);
    } else {
      pass(`scrolling to y=${y}px changes the hero's class ${changes} time(s), no shake`);
    }
  }

  // --- state still changes, in each direction, away from the old edge -----

  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(50);
  if (await hero.evaluate(node => node.classList.contains('hero--compact'))) {
    fail('the hero starts compact at the very top of the page');
  } else {
    pass('the hero is full-size at the top of the page');
  }

  await page.evaluate(() => window.scrollTo(0, 500));
  await page.waitForTimeout(50);
  if (!(await hero.evaluate(node => node.classList.contains('hero--compact')))) {
    fail('the hero never compacts on a real scroll down the page');
  } else {
    pass('the hero compacts once scrolled well past the threshold');
  }

  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(50);
  if (await hero.evaluate(node => node.classList.contains('hero--compact'))) {
    fail('the hero does not return to full size on scrolling back to the top');
  } else {
    pass('and returns to full size scrolling back to the top');
  }

  // --- the counts stay visible in the compact state, TKT-797's intent ------

  await page.evaluate(() => window.scrollTo(0, 500));
  await page.waitForTimeout(50);
  // hero-counts.js leaves .hero__counts empty when there is nothing to
  // report - "a zero says nothing worth the space it takes" - so this
  // fixture (a static export with no live counts) never gives it visible
  // pixels either way. What TKT-797's compact mode must not do is HIDE the
  // element itself; checked directly rather than through rendered size.
  const countsHidden = await page.locator('.hero__counts').first().evaluate(node => {
    const style = getComputedStyle(node);
    return node.hidden || style.display === 'none' || style.visibility === 'hidden';
  });
  if (countsHidden) {
    fail('the compact header hides .hero__counts outright - that is what the shrink exists to keep visible');
  } else {
    pass('the compact header does not hide .hero__counts');
  }

  // --- and the same holds on a narrow viewport, what the shrink is for ----

  await page.setViewportSize({ width: 390, height: 700 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(50);
  const narrowChanges = await countClassChanges(28);
  if (narrowChanges > 1) {
    fail(`on a phone-width viewport, scrolling to y=28px changed the hero's class ${narrowChanges} times`);
  } else {
    pass(`on a phone-width viewport, scrolling to y=28px changes the hero's class ${narrowChanges} time(s), no shake`);
  }
  const narrowCountsHidden = await page.locator('.hero__counts').first().evaluate(node => {
    const style = getComputedStyle(node);
    return node.hidden || style.display === 'none' || style.visibility === 'hidden';
  });
  if (narrowCountsHidden) {
    fail('the compact header hides .hero__counts on a narrow viewport');
  } else {
    pass('the compact header does not hide .hero__counts on a narrow viewport either');
  }

  await browser.close();
})();
