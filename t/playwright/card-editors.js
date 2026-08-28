// The three text editors in the card dialog, driven the way a person drives
// them: type into one and watch whether it grows.
//
// Reported by the owner with a screenshot (TG 5746): "The edit description box
// at the card modal the size is un-usable. I am expecting to be full width of
// the modal and the high is fully dynamic base on the content and also support
// richtext (show richtext, save markdown) allow to paste image like task card."
// Then expanded (TSK-165): "The problem also happen on new comment textarea and
// edit comment too."
//
// Every capability asked for already exists on a sibling editor in the same
// file, which is what makes this a wiring job rather than a new feature:
//
//   tasklist card input   input.rows=1  height = input.scrollHeight+"px"
//   question answer box   box.rows=3    height = Math.min(box.scrollHeight,420)+"px"
//   comment composer      has the markdown bar, and is rows=4 and ungrown
//   description editor    rows=5, no grow handler, and width:100% defeated by
//                         its inline-flex .card-edit parent
//
// The two grow handlers differ, and the difference decides which to copy: a
// description runs to paragraphs, and unbounded growth pushes the dialog's Save
// and Cancel off the bottom of the screen. That is what the answer box's 420
// cap exists for, so 420 is the precedent, and this test holds the fix to it.

const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath, dataPath] = process.argv.slice(2);
if (!htmlPath || !dataPath) {
  console.error('usage: card-editors.js <fixture.html> <board.json>');
  process.exit(2);
}

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };
const pass = message => console.log('  ok - ' + message);

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

const LONG = Array.from({ length: 14 }, (_, i) => `line ${i + 1} of a description that keeps going`).join('\n');

// The dialog is populated from /record, so this has to be served rather than
// loaded from a file:// page - the first version of this test opened nothing
// and timed out waiting for the dialog, which is a malformed red rather than a
// meaningful one.
const RECORD = {
  ref: 'TKT-001', type: 'ticket', column: 'in-progress', title: 'Live browser card',
  description: 'A description with **bold** and `code` in it', problem_or_feature: 'x',
  solution_needed: 'x', source: 'x', priority: 3, assignee: 'ada', reporter: 'ada',
  labels: [], start_date: null, due_date: null, sdlc_gate: null, lifecycle: null,
  fix_version: null, affects_versions: [], parent: null, key_details: [], deliverables: [],
  scope: { included: [], excluded: [] }, acceptance_criteria: [], test_steps: [],
  bdd: [], atdd: [], checklist: [], gate_passing_log: [], evidence: [], attachments: [],
  subtasks: [], linkage: { epic_ref: null, parent_ticket_ref: null, sub_ticket_refs: [], links: [] },
  comments: [{ id: 'CMT-001', author: 'ada', body: 'An existing comment to edit', format: 'markdown',
               created_at: '2026-08-01T09:00:00+0100', attachments: [] }],
  created_at: '2026-08-01T08:00:00+0100', last_updated: '2026-08-01T08:00:00+0100',
};

(async () => {
  const executablePath = [process.env.CHROMIUM_BIN, chromium.executablePath(), '/usr/bin/chromium', '/usr/bin/chromium-browser']
    .find(candidate => candidate && fs.existsSync(candidate));
  if (!executablePath) throw new Error('No Chromium executable found');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const board = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  await page.route('http://tira.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(board) });
    if (url.pathname === '/record') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(RECORD) });
    if (url.pathname === '/people' || url.pathname === '/link-types') return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');
  await page.click('[data-ref="TKT-001"] .card');
  await page.waitForSelector('.card-dialog[open]');

  // --- the description editor -------------------------------------------------

  // The pencil beside a section heading, which carries the field name. Found by
  // reading the renderer rather than guessing: sectionWithEdit sets
  // edit.dataset.edit = field, so the description's opener is [data-edit=...].
  // Criterion 3's display half: markdown SHOWN formatted while markdown is what
  // is stored. Checked before opening the editor, because that is the state a
  // reader sees - and the raw text is asserted separately, since "renders
  // formatted" and "stores markdown" are two claims and a renderer that ate the
  // asterisks would satisfy only the first.
  // Scoped by the class rather than by [data-section="description"]: section()
  // sets dataset.section but sectionWithEdit() - which is what renders the long
  // fields - does not, so that selector matches nothing. Only long fields get
  // .card-md-body, and only the description carries markdown in this fixture.
  const shown = page.locator('.card-dialog .card-md-body').first();
  if (await shown.count() === 0) {
    fail('the description is not rendered as markdown, while a comment beside it is');
  } else {
    const strongCount = await shown.locator('strong').count();
    const codeCount = await shown.locator('code').count();
    if (!strongCount || !codeCount) fail(`description markdown not rendered: ${strongCount} bold, ${codeCount} code`);
    else pass('description renders **bold** and `code` as formatted elements');
  }

  const editToggle = page.locator('.card-dialog .card-edit-button[data-edit="description"]');
  if (await editToggle.count() === 0) {
    fail('no edit control for the description was found - the dialog does not offer one');
  } else {
    await editToggle.first().click();
  }

  const area = page.locator('.card-dialog textarea.card-edit-input').first();
  if (await area.count() === 0) {
    fail('no description editor appeared after clicking its edit control');
  } else {
    // Full width, measured against the dialog's CONTENT box rather than its
    // border box. The dialog carries padding, so an editor filling its content
    // is about 90% of the outer box - and a threshold picked to sit just above
    // that would be a number tuned until the test passed rather than a
    // measurement. Subtracting the padding compares like with like.
    // Two assertions, because one of them kept landing on its own threshold.
    //
    // The first is what "spans" actually means: the editor fills the container
    // it sits in. That is a near-1.0 ratio and cannot drift with the dialog's
    // padding.
    //
    // The second is the reported fault, kept as a separate and deliberately
    // loose check against the dialog itself. It was measured at 44%; anything
    // over 0.8 is unambiguously not that, and a loose bound here is honest
    // where a tight one would just be a number tuned until the test passed.
    const raw = await area.inputValue();
    if (!raw.includes('**bold**') || !raw.includes('`code`')) fail(`the editor lost the raw markdown: ${JSON.stringify(raw)}`);
    else pass('the editor still holds the raw markdown, so markdown is what gets stored');

    const areaBox = await area.boundingBox();
    const ownBox = await area.evaluate(node => {
      const parent = node.closest('.card-value, .card-edit');
      const style = getComputedStyle(parent);
      return parent.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    });
    const fills = areaBox.width / ownBox;
    if (fills < 0.98) fail(`description editor fills only ${(fills * 100).toFixed(0)}% of its own container`);
    else pass(`description editor fills its container (${(fills * 100).toFixed(0)}%)`);

    const dialogWidth = (await page.locator('.card-dialog').boundingBox()).width;
    const ofDialog = areaBox.width / dialogWidth;
    if (ofDialog < 0.8) fail(`description editor is ${(ofDialog * 100).toFixed(0)}% of the dialog - the reported fault measured 44%`);
    else pass(`description editor is ${(ofDialog * 100).toFixed(0)}% of the dialog, against 44% before`);

    // Grows with content, and does not scroll internally for ordinary text.
    const before = (await area.boundingBox()).height;
    await area.fill(LONG);
    await page.waitForTimeout(50);
    const after = (await area.boundingBox()).height;
    if (after <= before) fail(`description editor did not grow: ${before}px before, ${after}px after 14 lines`);
    else pass(`description editor grew ${before}px -> ${after}px`);

    const scrolls = await area.evaluate(el => el.scrollHeight > el.clientHeight + 2);
    if (scrolls) fail('description editor has an inner scrollbar for ordinary text - it did not grow to fit');
    else pass('description editor shows its content without an inner scrollbar');

    // And it is capped, so a very long description cannot push the dialog's
    // own controls off the screen. 420 is the answer box's precedent.
    //
    // Both halves are asserted deliberately. "under 600px" alone passes on a box
    // that never grows at all - which is what it did on the first run, reporting
    // "capped at 126px" about a fixed-height textarea. A cap is only a cap if
    // the thing was growing on its way to it.
    await area.fill(Array.from({ length: 200 }, (_, i) => `line ${i}`).join('\n'));
    await page.waitForTimeout(50);
    const huge = (await area.boundingBox()).height;
    if (huge <= after) fail(`description editor did not grow past its 14-line height (${after}px) for 200 lines - the cap below proves nothing`);
    else if (huge > 600) fail(`description editor grew to ${huge}px unbounded - it needs the answer box's cap`);
    else pass(`description editor grew to ${huge}px for 200 lines and stopped there`);

    // Test step 3 of the card: APPLY bold from the bar, not merely find the bar.
    // Asserting the control exists says nothing about whether pressing it does
    // anything - which is the shape of dead control t/121 exists to catch on the
    // Perl side.
    await area.fill('make this bold');
    await area.evaluate(node => { node.selectionStart = 5; node.selectionEnd = 9; });
    const boldButton = page.locator('.card-dialog .card-edit .card-md-button[data-md="bold"]');
    if (await boldButton.count() === 0) {
      fail('the description editor has no bold control to press');
    } else {
      const heightBeforeBold = (await area.boundingBox()).height;
      await boldButton.first().click();
      await page.waitForTimeout(60);
      const bolded = await area.inputValue();
      if (bolded !== 'make **this** bold') fail(`bold did not wrap the selection: ${JSON.stringify(bolded)}`);
      else pass('bold from the bar wraps the selection and stores markdown');
      const heightAfterBold = (await area.boundingBox()).height;
      if (heightAfterBold < heightBeforeBold) fail('applying bold shrank the editor');
      else pass('the editor re-measured after a formatting click');
    }

    // Markdown shown formatted, markdown stored. Scoped to the editor's own
    // .card-edit wrapper, NOT to the dialog: the dialog already contains the
    // comment composer's bar, so a dialog-wide search reports success about a
    // different control - which is what it did on the first run.
    const bar = page.locator('.card-dialog .card-edit .card-md-bar');
    if (await bar.count() === 0) fail('the description editor itself has no markdown formatting bar');
    else pass('description editor has its own markdown formatting bar');
  }

  // --- the new-comment composer -----------------------------------------------

  const composerToggle = page.locator('.card-dialog .card-composer-toggle');
  if (await composerToggle.count()) await composerToggle.click();
  const comment = page.locator('.card-dialog .card-comment-form textarea[name="text"]');
  if (await comment.count() === 0) {
    fail('no new-comment textarea found');
  } else {
    const [cBox, formBox] = await Promise.all([
      comment.boundingBox(),
      page.locator('.card-dialog .card-comment-form').boundingBox(),
    ]);
    const cRatio = cBox.width / formBox.width;
    if (cRatio < 0.9) fail(`new-comment textarea is ${(cRatio * 100).toFixed(0)}% of its composer's width`);
    else pass(`new-comment textarea spans its composer (${(cRatio * 100).toFixed(0)}%)`);

    const cBefore = (await comment.boundingBox()).height;
    await comment.fill(LONG);
    await page.waitForTimeout(50);
    const cAfter = (await comment.boundingBox()).height;
    if (cAfter <= cBefore) fail(`new-comment textarea did not grow: ${cBefore}px before, ${cAfter}px after 14 lines`);
    else pass(`new-comment textarea grew ${cBefore}px -> ${cAfter}px`);
  }

    // Image paste, the fourth of the owner's asks. Driven with a real
    // DataTransfer carrying a file, because that is what a clipboard hands over
    // - asserting on a synthetic event the handler never sees would prove
    // nothing. The upload itself is stubbed at the route, so this checks what
    // the editor does: leave a marker where the caret was, and post the file.
    await area.fill('before after');
    await area.evaluate(node => { node.selectionStart = node.selectionEnd = 7; });
    const uploads = [];
    await page.route('http://tira.test/attachment/**', route => {
      uploads.push(route.request().url());
      // ok:true, which is what the real provider returns. Stubbing {} here sent
      // the frontend down the failure path, where nothing reloads - so the
      // marker survived for the wrong reason and the test passed while
      // production lost it. Codex review caught exactly that.
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    });
    await area.evaluate(node => {
      const data = new DataTransfer();
      data.items.add(new File([new Uint8Array([137, 80, 78, 71])], 'pasted.png', { type: 'image/png' }));
      node.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    });
    await page.waitForTimeout(120);
    const pastedValue = await area.inputValue();
    if (!pastedValue.includes('[image: pasted.png]')) fail(`pasting an image left no marker in the description: ${JSON.stringify(pastedValue)}`);
    else if (!pastedValue.startsWith('before [image: pasted.png]')) fail(`the marker did not land at the caret: ${JSON.stringify(pastedValue)}`);
    else pass('pasting an image leaves a marker at the caret');
    if (!uploads.length) fail('pasting an image posted nothing to the attachment endpoint');
    else pass(`pasting an image posted the file (${uploads.length} upload)`);

  // --- the edit-comment editor ------------------------------------------------
  //
  // The third control in scope. It had no rows set, no grow handler and no
  // markdown bar - the composer beside it has had a bar since it was written.

  const commentEdit = page.locator('.card-dialog [data-comment-edit]').first();
  if (await commentEdit.count() === 0) {
    fail('no Edit control on the existing comment - the fixture has no comment, or the control is gone');
  } else {
    await commentEdit.click();
    const editArea = page.locator('.card-dialog textarea.card-comment__editor').first();
    if (await editArea.count() === 0) {
      fail('clicking Edit on a comment produced no editor');
    } else {
      const eBar = page.locator('.card-dialog .card-comment__edit .card-md-bar');
      if (await eBar.count() === 0) fail('the edit-comment editor has no markdown bar, which the composer beside it has');
      else pass('edit-comment editor has its own markdown bar');

      const eBefore = (await editArea.boundingBox()).height;
      await editArea.fill(LONG);
      await page.waitForTimeout(50);
      const eAfter = (await editArea.boundingBox()).height;
      if (eAfter <= eBefore) fail(`edit-comment editor did not grow: ${eBefore}px before, ${eAfter}px after 14 lines`);
      else pass(`edit-comment editor grew ${eBefore}px -> ${eAfter}px`);
    }
  }

  await browser.close();
  if (!process.exitCode) console.log('card editors: all checks passed');
})();
