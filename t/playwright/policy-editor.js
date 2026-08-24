// TKT-493: the Policies dialog is the browser's only way to see and change
// the board-wide police policy engine (36 rules), separate from the Columns
// dialog's narrower per-column required-action template. Driven the way a
// person drives it: open it, read the three lists, declare a new policy from
// an undeclared rule (checking the rule-specific fields show or hide
// themselves), edit a declared one, remove one, and decline one - checking
// what is actually sent against what was on screen.
const { chromium } = require('playwright');
const fs = require('fs');

const [htmlPath] = process.argv.slice(2);
if (!htmlPath) {
  console.error('usage: policy-editor.js <fixture.html>');
  process.exit(2);
}

const RULES = {
  'card-duration': { needs: ['column', 'age'], forbids: [] },
  'card-unassigned': { needs: [], forbids: ['column', 'enter'] },
  'wip-limit': { needs: ['max'], forbids: [] },
  'checklist-idle': { needs: ['age'], forbids: [] },
};
const ACTIONS = ['bridge-reminder', 'print-reminder', 'log-only'];

let declared = [
  { id: 'POL-001', rule: 'card-duration', action: 'bridge-reminder', column: 'doing', age: '2h' },
  // A comma-joined value with no spaces - exactly what --require takes - is
  // one long unbreakable run a browser will not wrap on its own.
  { id: 'POL-002', rule: 'card-metrics', action: 'bridge-reminder', enter: 'in-progress',
    require: 'acceptance_criteria,test_steps,bdd,atdd,deliverables,scope,key_details,description' },
];
let declined = [ { rule: 'wip-limit', reason: 'no limit on this board' } ];

const fail = message => { console.error('FAIL: ' + message); process.exitCode = 1; };

process.on('unhandledRejection', error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});

(async () => {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_BIN });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  const posted = [];

  const policiesBody = () => JSON.stringify({
    declared, declined,
    undeclared: Object.keys(RULES).filter(name => !declared.some(p => p.rule === name) && !declined.some(d => d.rule === name)),
    rules: RULES, actions: ACTIONS,
  });

  await page.route('**/*', route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (path === '/policies') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: policiesBody() });
    }
    if (path === '/policy/add') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      const id = 'POL-00' + (declared.length + 2);
      declared.push({ id, ...payload });
      declined = declined.filter(d => d.rule !== payload.rule);
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id, ...payload }) });
    }
    if (path === '/policy/remove') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      declared = declared.filter(p => p.id !== payload.id);
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    }
    if (path === '/policy/decline') {
      const payload = JSON.parse(request.postData() || '{}');
      posted.push({ path, payload });
      declined.push(payload);
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    }
    if (path === '/data') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    if (path === '/people' || path === '/link-types') {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    return route.fulfill({ status: 200, contentType: 'text/html', body: html });
  });

  page.on('dialog', dialog => {
    if (dialog.type() === 'prompt') return dialog.accept('a reason typed at the prompt');
    return dialog.accept();
  });

  await page.goto('http://tira.test/');
  await page.waitForFunction(() => document.documentElement.dataset.ready === 'true');

  const button = page.locator('.board--ticket .board-policies');
  if (await button.count() !== 1) {
    fail('the ticket board has no Policies button');
    await browser.close();
    return;
  }
  await button.click();
  await page.waitForFunction(() => document.querySelectorAll('.policy-row').length > 0);

  // Declared shows first, with what was declared.
  const declaredText = await page.locator('[data-policy-pane="declared"] .policy-row').first().innerText();
  if (!declaredText.includes('POL-001') || !declaredText.includes('card-duration')) {
    fail('the declared pane did not show the declared policy, got ' + declaredText);
  }

  // TKT-501: on a narrow (phone) viewport, a long declared-policy line must
  // wrap within the dialog rather than push Edit/Remove off-screen.
  await page.setViewportSize({ width: 375, height: 700 });
  const longRow = page.locator('[data-policy-pane="declared"] .policy-row', { hasText: 'POL-002' });
  const dialogBox = await page.locator('.policy-dialog').boundingBox();
  const editBox = await longRow.locator('button', { hasText: 'Edit' }).boundingBox();
  if (!dialogBox || !editBox) fail('could not measure the policy dialog or its Edit button');
  else if (editBox.x + editBox.width > dialogBox.x + dialogBox.width + 1)
    fail(`Edit sits outside the dialog on a narrow viewport - dialog right edge ${dialogBox.x + dialogBox.width}, Edit right edge ${editBox.x + editBox.width}`);
  const rowOverflow = await longRow.evaluate(node => node.scrollWidth - node.clientWidth);
  if (rowOverflow > 1) fail(`the long policy row's own content overflows its box by ${rowOverflow}px on a narrow viewport`);
  await page.setViewportSize({ width: 1280, height: 900 });

  // Undeclared lists what neither declared nor declined named.
  await page.locator('[data-policy-tab="undeclared"]').click();
  const undeclaredNames = await page.locator('[data-policy-pane="undeclared"] .policy-row').evaluateAll(
    nodes => nodes.map(n => n.childNodes[0].textContent.trim()));
  if (undeclaredNames.join(',') !== 'card-unassigned,checklist-idle') {
    fail('undeclared did not list exactly the rules that are neither declared nor declined, got ' + undeclaredNames.join(','));
  }

  // Declaring an undeclared rule fills the rule select and hides fields that
  // rule forbids (card-unassigned forbids column and enter).
  await page.locator('[data-policy-pane="undeclared"] .policy-row', { hasText: 'card-unassigned' })
    .locator('button', { hasText: 'Declare' }).click();
  const ruleValue = await page.locator('.policy-form__rule').inputValue();
  if (ruleValue !== 'card-unassigned') fail('clicking Declare did not select the rule, got ' + ruleValue);
  const columnRowHidden = await page.locator('.policy-form [data-field="column"]').isHidden();
  if (!columnRowHidden) fail('a field the rule forbids was still shown');

  await page.locator('.policy-form__action').selectOption('log-only');
  await page.locator('.policy-form__declare').click();
  await page.waitForTimeout(400);

  const added = posted.find(p => p.path === '/policy/add' && p.payload.rule === 'card-unassigned');
  if (!added) fail('declaring the rule sent nothing to /policy/add');
  else if (added.payload.action !== 'log-only') fail('the chosen action was not sent, got ' + added.payload.action);
  else if ('column' in added.payload) fail('a forbidden field was sent anyway, got ' + JSON.stringify(added.payload));

  // Editing a declared policy prefills the form and offers Remove; saving it
  // removes the old declaration before re-adding, since policy_add itself
  // refuses to replace one in place.
  await page.locator('[data-policy-tab="declared"]').click();
  await page.locator('[data-policy-pane="declared"] .policy-row', { hasText: 'POL-001' })
    .locator('button', { hasText: 'Edit' }).click();
  const editedRule = await page.locator('.policy-form__rule').inputValue();
  if (editedRule !== 'card-duration') fail('editing did not select the policy\'s own rule, got ' + editedRule);
  const editedAge = await page.locator('.policy-form__age').inputValue();
  if (editedAge !== '2h') fail('editing did not prefill the stored age, got ' + editedAge);
  if (await page.locator('.policy-form__remove').isHidden()) fail('editing a declared policy did not offer Remove');

  await page.locator('.policy-form__age').fill('4h');
  posted.length = 0;
  await page.locator('.policy-form__declare').click();
  await page.waitForTimeout(400);

  const removeCall = posted.find(p => p.path === '/policy/remove');
  const addCall = posted.find(p => p.path === '/policy/add' && p.payload.rule === 'card-duration');
  if (!removeCall || removeCall.payload.id !== 'POL-001') fail('editing did not remove the old declaration first');
  if (!addCall || addCall.payload.age !== '4h') fail('editing did not re-declare with the new value, got ' + JSON.stringify(addCall && addCall.payload));

  // Declining a rule prompts for a reason and posts it.
  await page.locator('[data-policy-tab="undeclared"]').click();
  const stillUndeclared = await page.locator('[data-policy-pane="undeclared"] .policy-row').count();
  if (stillUndeclared !== 1) fail('expected exactly one rule left undeclared, got ' + stillUndeclared);
  await page.locator('[data-policy-pane="undeclared"] .policy-row', { hasText: 'checklist-idle' })
    .locator('button', { hasText: 'Decline' }).click();
  await page.waitForFunction(() => document.querySelectorAll('[data-policy-pane="undeclared"] .policy-row').length === 0);
  const declineCall = posted.find(p => p.path === '/policy/decline');
  if (!declineCall || declineCall.payload.reason !== 'a reason typed at the prompt') {
    fail('declining did not send the typed reason, got ' + JSON.stringify(declineCall && declineCall.payload));
  }

  // Removing a declared policy asks for confirmation, then removes it.
  await page.locator('[data-policy-tab="declared"]').click();
  const beforeRemove = await page.locator('[data-policy-pane="declared"] .policy-row').count();
  await page.locator('[data-policy-pane="declared"] .policy-row').first().locator('button', { hasText: 'Remove' }).click();
  await page.waitForFunction(count => document.querySelectorAll('[data-policy-pane="declared"] .policy-row').length < count, beforeRemove);

  await browser.close();
  if (!process.exitCode) console.log('policy editor: all checks passed');
})().catch(error => {
  console.error('FAIL: ' + (error && error.message ? error.message.split('\n')[0] : error));
  process.exit(1);
});
