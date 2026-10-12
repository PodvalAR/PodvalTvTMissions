const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

// Only UI source is read. Catalog, scan, AI and network responses are synthetic.
const html = fs.readFileSync(path.join(__dirname, '..', 'UI', 'index.html'), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace(/\bboot\(\);\s*$/, '');
const oldRef = '{1111111111111111}Prefabs/Old.et';
const targetRef = "{2222222222222222}Prefabs/New's.et";
const fallbackRef = '{3333333333333333}Prefabs/Fallback.et';

function element(tag = 'div') {
  const classes = new Set();
  let markup = '';
  const node = {
    tagName: tag.toUpperCase(), children: [], className: '', textContent: '', style: {}, disabled: false,
    isConnected: true, value: '', checked: false,
    get innerHTML() { return markup; },
    set innerHTML(value) { markup = value; this.children = []; },
    classList: {
      add: name => classes.add(name), remove: name => classes.delete(name),
      contains: name => classes.has(name) || node.className.split(' ').includes(name),
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); }
    },
    addEventListener() {}, setAttribute() {},
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
    insertAdjacentHTML(_position, text) { markup += text; },
    remove() { this.isConnected = false; },
    querySelector(selector) {
      if (selector.includes(' ')) {
        const [head, ...tail] = selector.split(' ');
        return this.querySelector(head)?.querySelector(tail.join(' ')) || null;
      }
      const matches = child => selector.startsWith('.') ? child.classList.contains(selector.slice(1)) : child.tagName.toLowerCase() === selector;
      for (const child of this.children) {
        if (matches(child)) return child;
        const descendant = child.querySelector(selector);
        if (descendant) return descendant;
      }
      return null;
    }
  };
  return node;
}

function allNodes(node) { return [node, ...node.children.flatMap(allNodes)]; }
function markup(node) { return allNodes(node).map(child => child.innerHTML).join('\n'); }
function response(data) { return { ok: true, json: async () => data }; }

function setup(fetch) {
  const nodes = new Map();
  const requests = [];
  const document = {
    body: element('body'), createElement: element,
    querySelector(selector) { if (!nodes.has(selector)) nodes.set(selector, element()); return nodes.get(selector); },
    querySelectorAll() { return []; }
  };
  const context = vm.createContext({
    document, Headers, Date, console,
    CSS: { escape: value => value }, window: { location: { href: '' } },
    confirm: () => true,
    fetch: (url, options) => { requests.push({ url, options }); return fetch(url, options); }
  });
  vm.runInContext(source, context, { filename: 'index.html' });
  const evaluate = code => vm.runInContext(code, context);
  evaluate(`CFG = { aiEnabled:true, csrfToken:'synthetic-token' };
    lastScan = {Mission:'synthetic', Refs:[{Ref:${JSON.stringify(oldRef)},Path:'Prefabs/Old.et',Guid:'1111111111111111',Status:'broken'}]};`);
  const box = element(), row = element('tr');
  context.testBox = box; context.testRow = row;
  evaluate(`renderCands(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',[],null,testRow)`);
  return { evaluate, context, document, nodes, requests, box, row };
}

test('mission AI recommendation does not write mapping until its explicit apply button is clicked', async () => {
  const env = setup(async url => url === '/api/ai-suggest'
    ? response({ ok: true, ai: { Status: 'match', Ref: targetRef, Reason: 'Совпала <роль>' }, candidates: [] })
    : response({ ok: true }));
  await env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  assert.equal(env.requests.length, 1);
  assert.match(markup(env.box), /Совпала &lt;роль&gt;/);
  assert.match(markup(env.box), /New&#39;s\.et/);
  const apply = allNodes(env.box).find(node => node.textContent === 'Применить рекомендацию');
  assert(apply);
  await apply.onclick();
  assert.equal(env.requests.length, 2);
  assert.equal(env.requests[1].url, '/api/map');
  assert.deepEqual(JSON.parse(env.requests[1].options.body), { oldRef, newRef: targetRef });
  assert.equal(env.requests[1].options.headers.get('X-Restore-Token'), 'synthetic-token');
});

test('mission AI no_match is a normal recommendation with a manual catalog link', async () => {
  const env = setup(async () => response({ ok: true, ai: { Status: 'no_match', Ref: '', Reason: 'Надёжной замены нет' }, candidates: [] }));
  await env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  assert.match(markup(env.box), /Надёжная замена не найдена/);
  assert.match(markup(env.box), /Выбрать в каталоге/);
  assert.equal(allNodes(env.box).some(node => /Применить/.test(node.textContent)), false);
  assert.equal(env.requests.length, 1);
  assert.doesNotMatch(env.document.querySelector('#log').innerHTML, /Ошибка ИИ/);
});

test('mission candidate cards escape explanations and place approximate candidates in manual fallback', () => {
  const env = setup(() => { throw new Error('No network expected'); });
  env.evaluate(`renderCands(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',${JSON.stringify([
    { Ref: targetRef, Path: "Prefabs/New's.et", Score: 11, Confidence: 1, Compatibility: 'compatible', MatchLabel: 'Высокое <соответствие>', Reasons: ['Совпала <роль>'], Warnings: [] },
    { Ref: fallbackRef, Path: 'Prefabs/Fallback.et', Score: 10, Compatibility: 'approximate', MatchLevel: 'low', Reasons: [], Warnings: ['Другой "масштаб" <группы>'] }
  ])},null,testRow)`);
  const cards = allNodes(env.box).filter(node => node.classList.contains('cand-row'));
  assert.equal(cards.length, 2);
  assert.equal(cards[1].parentNode.className, 'candidate-fallback');
  assert.match(markup(env.box), /Совпала &lt;роль&gt;/);
  assert.match(markup(env.box), /&quot;масштаб&quot; &lt;группы&gt;/);
  assert.match(markup(env.box), /Приблизительные замены — ручной выбор/);
  assert.doesNotMatch(markup(env.box), /100%|undefined|<роль>/);
});

test('mission AI ignores stale scan response and prevents duplicate requests', async () => {
  let complete;
  const env = setup(() => new Promise(resolve => { complete = resolve; }));
  const pending = env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  await env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  assert.equal(env.requests.length, 1);
  env.evaluate('lastScan = { Refs:[] }');
  complete(response({ ok: true, ai: { Status: 'match', Ref: targetRef, Reason: 'stale reasoning' }, candidates: [] }));
  await pending;
  assert.doesNotMatch(markup(env.box), /stale reasoning/);
  assert.equal(allNodes(env.box).some(node => node.textContent === 'Применить рекомендацию'), false);
});

test('uncertain mission AI cannot apply after the candidate row disconnects', async () => {
  const env = setup(async () => response({ ok: true, ai: { Status: 'uncertain', Ref: targetRef, Reason: 'Неизвестная роль' }, candidates: [] }));
  await env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  assert(allNodes(env.box).some(node => node.classList.contains('uncertain')));
  const apply = allNodes(env.box).find(node => node.textContent === 'Применить вручную');
  assert(apply);
  env.box.isConnected = false;
  await apply.onclick();
  assert.equal(env.requests.length, 1);
});

test('late mission AI response does not change the replacement session or clear its spinner', async () => {
  const pendingResponses = [];
  const env = setup(() => new Promise(resolve => pendingResponses.push(resolve)));
  const oldRequest = env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  env.evaluate(`renderCands(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',[],null,testRow)`);
  const newRequest = env.evaluate(`aiPick(testBox,${JSON.stringify(oldRef)},'Prefabs/Old.et',testRow)`);
  pendingResponses[0](response({ ok: true, ai: { Status: 'match', Ref: targetRef, Reason: 'stale reason' }, candidates: [] }));
  await oldRequest;
  assert(env.box.classList.contains('spin'));
  assert.equal(env.box.querySelector('.head button').disabled, true);
  assert.doesNotMatch(markup(env.box), /stale reason/);
  pendingResponses[1](response({ ok: true, ai: { Status: 'match', Ref: fallbackRef, Reason: 'fresh reason' }, candidates: [] }));
  await newRequest;
  assert.equal(env.box.classList.contains('spin'), false);
  assert.match(markup(env.box), /fresh reason/);
});
