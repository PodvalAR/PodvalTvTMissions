const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

// Only editor source is read. All table/catalog/config/network data is synthetic.
const html = fs.readFileSync(path.join(__dirname, '..', 'UI', 'editor.html'), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const oldRef = "{1111111111111111}Prefabs/Old's.et";
const otherRef = '{2222222222222222}Prefabs/Other.et';
const targetRef = "{3333333333333333}Prefabs/New's.et";
const secondTarget = '{4444444444444444}Prefabs/Second.et';
const key = (group, ref = oldRef) => JSON.stringify([group, ref]);
const baseTree = () => ({
  _meta: { description: 'baseline', status: 'draft', custom: { retained: true } },
  Alpha: { [oldRef]: '', _note: 'baseline note' },
  "Unit's": { Exact: { [oldRef]: '' } },
  [otherRef]: ''
});

function element() {
  const classes = new Set();
  return {
    value: '', innerHTML: '', textContent: '', style: {}, disabled: false, inert: false,
    classList: {
      add: name => classes.add(name), remove: name => classes.delete(name),
      toggle(name, force) { if (force === undefined ? !classes.has(name) : force) classes.add(name); else classes.delete(name); },
      contains: name => classes.has(name)
    },
    appendChild() {}, setAttribute(name, value) { this[name] = value; }
  };
}

function setup({ tree = baseTree(), fetch } = {}) {
  const nodes = new Map();
  const lockRegions = Array.from({ length: 4 }, element);
  const requests = [];
  const alerts = [];
  const document = {
    body: element(),
    getElementById(id) { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); },
    createElement: element,
    querySelectorAll(selector) { return selector === 'header, .toolbar, main, .modal-backdrop' ? lockRegions : []; }
  };
  const context = vm.createContext({
    document, URLSearchParams, window: { location: { search: '' }, addEventListener() {} },
    navigator: { clipboard: { writeText: async () => {} } },
    alert: message => alerts.push(message), confirm: () => true, prompt: () => 'edited note',
    fetch: (url, options) => {
      requests.push({ url, options });
      if (!fetch) throw new Error('Unexpected synthetic request: ' + url);
      return fetch(url, options);
    }
  });
  vm.runInContext(source, context, { filename: 'editor.html' });
  const evaluate = code => vm.runInContext(code, context);
  const snapshot = code => JSON.parse(evaluate(`JSON.stringify(${code})`));
  evaluate(`gBaseline = { tree: ${JSON.stringify(tree)}, versionHash: 'hash1' };
    gModIndex = { '3333333333333333': "Prefabs/New's.et", '4444444444444444': 'Prefabs/Second.et' };
    gCatalogBaseline = { old: [{fullRef: ${JSON.stringify(oldRef)}, guid:'1111111111111111', isModPrefab:true, usageCount:2, missions:'synthetic'}],
      new: [{fullRef:${JSON.stringify(targetRef)}, guid:'3333333333333333',path:"Prefabs/New's.et",category:'Props'}] };
    gCsrfToken = 'synthetic-token'; adoptReplay(replayOperations(gBaseline.tree, []));`);
  return { context, evaluate, snapshot, requests, alerts, document, nodes, lockRegions };
}

function enqueue(env, operations) {
  return env.evaluate(`enqueueOperations(${JSON.stringify(operations)})`);
}

function decodeAttribute(value) {
  return value.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

function response(data, ok = true) { return { ok, json: async () => data }; }

test('real generated table handlers address duplicate rows and preserve apostrophes', () => {
  const env = setup();
  const handlers = [...env.document.getElementById('remapTableBody').innerHTML.matchAll(/onchange="([^"]+)"/g)]
    .map(match => decodeAttribute(match[1])).filter(handler => handler.startsWith('onLeafValueChange'));
  assert.equal(handlers.length, 3);
  for (const handler of handlers) new vm.Script(handler);
  env.evaluate(`(function(){${handlers[1]}}).call({value:${JSON.stringify(targetRef)}})`);
  assert.deepEqual(env.snapshot('gModel.entries.map(entry => entry.newRef)'), ['', targetRef, '']);
  assert.equal(env.snapshot('gPendingOps')[0].groupPath.join('/'), "Unit's/Exact");
  assert.equal(env.snapshot('gModel.tree')["Unit's"].Exact[oldRef], targetRef);
  assert.equal(env.snapshot('gBaseline.tree')["Unit's"].Exact[oldRef], '');
  assert.match(env.evaluate('buildTreeNodeHtml(gModel.tree, [], "Root")'), /New&#39;s\.et/);
});

test('all operation kinds replay into one working tree and undo restores baseline metadata/catalog', () => {
  const env = setup();
  enqueue(env, [
    { op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef },
    { op: 'meta', description: 'changed', status: 'verified' },
    { op: 'note', group: ['Alpha'], note: "note's <text>" },
    { op: 'move', groupPath: [], oldRef: otherRef, targetGroup: ['New/Exact'] }
  ]);
  const working = env.snapshot('gModel.tree');
  assert.equal(working._meta.custom.retained, true);
  assert.equal(working.Alpha._note, "note's <text>");
  assert.equal(working['New/Exact'][otherRef], '');
  assert.equal(Object.hasOwn(working, otherRef), false);
  assert.equal(env.snapshot('gOldCatalog')[0].status, 'mapped');
  assert.equal(env.snapshot('gNewCatalog')[0].mappedCount, 1);
  env.evaluate('revertOp(1)');
  assert.equal(env.snapshot('gModel.meta').description, 'baseline');
  assert.equal(env.snapshot('gModel.tree').Alpha._note, "note's <text>");
  env.evaluate('revertAllChanges()');
  assert.deepEqual(env.snapshot('gModel.tree'), baseTree());
  assert.equal(env.snapshot('gOldCatalog')[0].status, 'stub');
  assert.equal(env.snapshot('gNewCatalog')[0].mappedCount, 0);
  assert.equal(env.requests.length, 0);
});

test('set-delete-add-set preserves ordering and the last value', () => {
  const env = setup();
  const row = key(['Alpha']);
  env.evaluate(`onLeafValueChange(${JSON.stringify(row)}, ${JSON.stringify(targetRef)})`);
  enqueue(env, [{ op: 'delete', groupPath: ['Alpha'], oldRef }, { op: 'add', group: ['Alpha'], oldRef, newRef: secondTarget }]);
  env.evaluate(`onLeafValueChange(${JSON.stringify(row)}, ${JSON.stringify(targetRef)})`);
  assert.deepEqual(env.snapshot('gPendingOps.map(op => op.op)'), ['set', 'delete', 'add', 'set']);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], targetRef);
  env.evaluate('revertOp(0)');
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], targetRef);
  assert.equal(env.snapshot('gPendingOps').length, 3);
});

test('undo delete cancels recreated row and dependent edits, retaining unrelated edits', () => {
  const env = setup();
  enqueue(env, [
    { op: 'delete', groupPath: ['Alpha'], oldRef },
    { op: 'add', group: ['alpha'], oldRef: oldRef.toLowerCase(), newRef: targetRef },
    { op: 'set', groupPath: ['Alpha'], oldRef, newRef: secondTarget },
    { op: 'set', groupPath: [], oldRef: otherRef, newRef: targetRef }
  ]);
  env.evaluate('revertOp(0)');
  assert.deepEqual(env.snapshot('gPendingOps.map(op => op.clientId)'), [4]);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], '');
  assert.equal(env.snapshot('gModel.tree')[otherRef], targetRef);
  assert.match(env.alerts.at(-1), /зависимые операции: 2/);
});

test('undo move cancels destination edits and source reuse, but preserves later independent sets', () => {
  const env = setup();
  enqueue(env, [
    { op: 'move', groupPath: ['Alpha'], oldRef, targetGroup: ['Destination'] },
    { op: 'set', groupPath: ['Destination'], oldRef, newRef: targetRef },
    { op: 'add', group: ['Alpha'], oldRef, newRef: secondTarget },
    { op: 'set', groupPath: [], oldRef: otherRef, newRef: targetRef }
  ]);
  env.evaluate('revertOp(0)');
  assert.deepEqual(env.snapshot('gPendingOps.map(op => op.clientId)'), [4]);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], '');
  assert.equal(Object.hasOwn(env.snapshot('gModel.tree'), 'Destination'), false);
  enqueue(env, [{ op: 'set', groupPath: [], oldRef: otherRef, newRef: secondTarget }]);
  env.evaluate('revertOp(0)');
  assert.equal(env.snapshot('gModel.tree')[otherRef], secondTarget);
});

test('collisions reject entire batch, duplicate bulk selection addresses only selected row', () => {
  const env = setup();
  const original = env.snapshot('gModel.tree');
  assert.equal(enqueue(env, [
    { op: 'set', groupPath: [], oldRef: otherRef, newRef: targetRef },
    { op: 'move', groupPath: ['Alpha'], oldRef, targetGroup: ["Unit's", 'Exact'] }
  ]), false);
  assert.deepEqual(env.snapshot('gModel.tree'), original);
  assert.equal(env.snapshot('gPendingOps').length, 0);
  env.evaluate(`toggleSelectKey(${JSON.stringify(key(["Unit's", 'Exact']))}, true); bulkDeleteSelected()`);
  assert.equal(env.snapshot('gModel.entries.filter(entry => entry.oldRef === ' + JSON.stringify(oldRef) + ')').length, 1);
  assert.equal(Object.hasOwn(env.snapshot('gModel.tree').Alpha, oldRef), true);
  assert.equal(Object.hasOwn(env.snapshot('gModel.tree')["Unit's"].Exact, oldRef), false);
});

test('same-group bulk move clears both selection state and rendered checkboxes', () => {
  const env = setup();
  env.evaluate(`toggleSelectKey(${JSON.stringify(key(['Alpha']))}, true); openBulkMoveModal()`);
  env.document.getElementById('moveInputGroup').value = 'Alpha';
  env.evaluate('confirmMove()');
  assert.equal(env.evaluate('gSelectedKeys.size'), 0);
  assert.doesNotMatch(env.document.getElementById('remapTableBody').innerHTML, /type="checkbox" checked/);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], '');
});

test('deferred save locks all mutations/reentry and sends only scoped wire operations plus token', async () => {
  let complete;
  const env = setup({ fetch: () => new Promise(resolve => { complete = resolve; }) });
  enqueue(env, [{ op: 'set', groupPath: [], oldRef: otherRef, newRef: targetRef }]);
  const pending = env.evaluate('saveBatch()');
  assert(env.lockRegions.every(region => region.inert));
  env.evaluate(`onLeafValueChange(${JSON.stringify(key([], otherRef))}, ${JSON.stringify(secondTarget)}); revertOp(0); revertAllChanges();`);
  await env.evaluate('saveBatch()');
  assert.equal(env.requests.length, 1);
  const request = env.requests[0];
  assert.equal(request.options.headers['X-Restore-Token'], 'synthetic-token');
  assert.equal(request.options.headers['Content-Type'], 'application/json');
  const body = JSON.parse(request.options.body);
  assert.deepEqual(body, { operations: [{ op: 'set', groupPath: [], oldRef: otherRef, newRef: targetRef }], versionHash: 'hash1' });
  const savedTree = baseTree(); savedTree[otherRef] = targetRef;
  complete(response({ ok: true, applied: 1, model: { tree: savedTree, versionHash: 'hash2' } }));
  await pending;
  assert.equal(env.snapshot('gPendingOps').length, 0);
  assert.equal(env.snapshot('gBaseline.versionHash'), 'hash2');
  assert.equal(env.snapshot('gModel.tree')[otherRef], targetRef);
  assert(env.lockRegions.every(region => !region.inert));
});

test('failed save retains queue and optimistic model unchanged', async () => {
  const env = setup({ fetch: async () => response({ ok: false, error: 'version conflict' }, false) });
  enqueue(env, [{ op: 'set', groupPath: ['Alpha'], oldRef, newRef: targetRef }]);
  const queued = env.snapshot('gPendingOps');
  const working = env.snapshot('gModel.tree');
  await env.evaluate('saveBatch()');
  assert.deepEqual(env.snapshot('gPendingOps'), queued);
  assert.deepEqual(env.snapshot('gModel.tree'), working);
  assert.equal(env.snapshot('gBaseline.versionHash'), 'hash1');
  assert(env.lockRegions.every(region => !region.inert));
});

test('ranker uses uppercase backend fields, exact Ref and safe generated candidate handler', () => {
  const env = setup();
  env.evaluate(`gSuggestTarget = { key:${JSON.stringify(key(['Alpha']))}, oldRef:${JSON.stringify(oldRef)} };
    renderCandidates(${JSON.stringify([{ Ref: targetRef, Guid: '3333333333333333', Path: "Prefabs/New's.et", Score: '7.5', Warn: '<warning>' }])})`);
  const markup = env.document.getElementById('suggestCandidatesList').innerHTML;
  assert.doesNotMatch(markup, /undefined/);
  assert.match(markup, /&lt;warning&gt;/);
  const handler = decodeAttribute(markup.match(/onclick="([^"]+)"/)[1]);
  env.evaluate(handler);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], targetRef);
});

test('AI uses Ref and Reason and POST authentication', async () => {
  const env = setup({ fetch: async () => response({ ok: true, ai: { Ref: targetRef, Reason: 'synthetic reasoning' } }) });
  env.evaluate(`gSuggestTarget = { key:${JSON.stringify(key(['Alpha']))}, oldRef:${JSON.stringify(oldRef)} }`);
  await env.evaluate('requestAiSuggest()');
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], targetRef);
  assert.match(env.alerts[0], /synthetic reasoning/);
  assert.equal(env.requests[0].options.headers['X-Restore-Token'], 'synthetic-token');
});

test('Legacy edits expose pending controls and ambiguous legacy refs require row selection', async () => {
  const env = setup();
  env.evaluate("switchMainTab('legacy')");
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  assert.equal(env.document.getElementById('btnSaveBatch').style.display, 'inline-flex');
  await env.evaluate(`openSuggestModal(${JSON.stringify(oldRef)})`);
  assert.equal(env.snapshot('gActiveMainTab'), 'remap');
  assert.equal(env.requests.length, 0);
  assert.match(env.alerts.at(-1), /нескольких группах/);
});

test('catalog refresh preserves dirty working state and original optimistic concurrency hash', async () => {
  const env = setup({ fetch: async url => {
    if (url === '/api/catalog/rebuild') return response({ ok: true, oldCount: 1, newCount: 1 });
    if (url === '/api/modindex') return response({ '3333333333333333': "Prefabs/New's.et" });
    if (url === '/api/catalog/new') return response([{ fullRef: targetRef, guid: '3333333333333333', path: "Prefabs/New's.et", category: 'Props' }]);
    if (url === '/api/catalog/old') return response([{ fullRef: oldRef, guid: '1111111111111111', isModPrefab: true, usageCount: 3, missions: 'refreshed' }]);
    throw new Error('Unexpected endpoint ' + url);
  } });
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  const queued = env.snapshot('gPendingOps');
  await env.evaluate('rebuildCatalogs()');
  assert.deepEqual(env.snapshot('gPendingOps'), queued);
  assert.equal(env.snapshot('gBaseline.versionHash'), 'hash1');
  assert.equal(env.snapshot('gModel.tree')["Unit's"].Exact[oldRef], targetRef);
  assert.equal(env.snapshot('gOldCatalog')[0].status, 'mapped');
  assert.equal(env.snapshot('gOldCatalog')[0].usageCount, 3);
  assert.equal(env.requests.some(request => request.url === '/api/table'), false);
  assert.equal(env.requests[0].options.headers['X-Restore-Token'], 'synthetic-token');
});
