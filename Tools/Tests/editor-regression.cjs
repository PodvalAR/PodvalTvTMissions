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
    gCatalogBaseline = { new: [{fullRef:${JSON.stringify(targetRef)}, guid:'3333333333333333',path:"Prefabs/New's.et",category:'Props'}] };
    gUsageReport = { exists:true, stale:false, sourceRoot:'C:/Legacy', scannedAt:'2026-10-13T00:00:00Z', missionCount:2, refCount:2,
      refs:[{fullRef:${JSON.stringify(oldRef)}, usageCount:2, missions:['Region/Mission','Region/Other'], status:'broken'},
            {fullRef:${JSON.stringify(otherRef)}, usageCount:1, missions:['Region/Mission'], status:'broken'}] };
    // These fixtures inject the external snapshots directly, so the deferred loader must
    // treat them as already present. The lazy-load path itself is covered separately below.
    gExternalLoaded = true;
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
  assert.equal(env.evaluate(`gUsageState.get(${JSON.stringify(oldRef.toLowerCase())}).status`), 'mapped');
  assert.equal(env.snapshot('gNewCatalog')[0].mappedCount, 1);
  env.evaluate('revertOp(1)');
  assert.equal(env.snapshot('gModel.meta').description, 'baseline');
  assert.equal(env.snapshot('gModel.tree').Alpha._note, "note's <text>");
  env.evaluate('revertAllChanges()');
  assert.deepEqual(env.snapshot('gModel.tree'), baseTree());
  assert.equal(env.evaluate(`gUsageState.get(${JSON.stringify(oldRef.toLowerCase())}).status`), 'stub');
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

test('AI renders escaped recommendation without mutating until explicit apply and uses POST authentication', async () => {
  const env = setup({ fetch: async () => response({ ok: true, ai: { Status: 'match', Ref: targetRef, Reason: '<synthetic reasoning>' }, candidates: [] }) });
  env.evaluate(`gSuggestTarget = { key:${JSON.stringify(key(['Alpha']))}, oldRef:${JSON.stringify(oldRef)} }`);
  await env.evaluate('requestAiSuggest()');
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], '');
  assert.equal(env.snapshot('gPendingOps').length, 0);
  assert.equal(env.alerts.length, 0);
  const markup = env.document.getElementById('suggestAiRecommendation').innerHTML;
  assert.match(markup, /&lt;synthetic reasoning&gt;/);
  assert.match(markup, /New&#39;s\.et/);
  const apply = decodeAttribute(markup.match(/onclick="([^"]+)"/)[1]);
  env.evaluate(apply);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], targetRef);
  assert.equal(env.snapshot('gPendingOps').length, 1);
  assert.equal(env.requests[0].options.headers['X-Restore-Token'], 'synthetic-token');
});

test('AI no_match with empty Ref is normal and exposes manual catalog without an apply action', async () => {
  const env = setup({ fetch: async () => response({ ok: true, ai: { Status: 'no_match', Ref: '', Reason: 'Роль сапёра не найдена' }, candidates: [] }) });
  env.evaluate(`gSuggestTarget = { key:${JSON.stringify(key(['Alpha']))}, oldRef:${JSON.stringify(oldRef)} }`);
  await env.evaluate('requestAiSuggest()');
  const markup = env.document.getElementById('suggestAiRecommendation').innerHTML;
  assert.match(markup, /Надёжная замена не найдена/);
  assert.match(markup, /switchSuggestMode/);
  assert.doesNotMatch(markup, /applyAiRecommendation/);
  assert.equal(env.snapshot('gAiRecommendation'), null);
  assert.equal(env.snapshot('gPendingOps').length, 0);
  assert.equal(env.alerts.length, 0);
});

test('uncertain AI recommendation is visibly marked and requires manual apply', async () => {
  const env = setup({ fetch: async () => response({ ok: true, ai: { Status: 'uncertain', Ref: targetRef, Reason: 'Неизвестная экипировка' }, candidates: [] }) });
  env.evaluate(`gSuggestTarget = { key:${JSON.stringify(key(['Alpha']))}, oldRef:${JSON.stringify(oldRef)} }`);
  await env.evaluate('requestAiSuggest()');
  const markup = env.document.getElementById('suggestAiRecommendation').innerHTML;
  assert.match(markup, /ai-recommendation uncertain/);
  assert.match(markup, /Применить вручную/);
  assert.equal(env.snapshot('gPendingOps').length, 0);
});

test('ranker separates approximate replacements and escapes structured explanations without confidence percentages', () => {
  const env = setup();
  const candidates = [
    { Ref: targetRef, Path: "Prefabs/New's.et", Score: 9, Confidence: 1, Compatibility: 'compatible', MatchLevel: 'high', MatchLabel: 'Высокое <соответствие>', Reasons: ['Совпала <роль>', 'Строка "с кавычками"'], Warnings: [] },
    { Ref: secondTarget, Score: 8, Compatibility: 'approximate', MatchLevel: 'low', Reasons: ['Совпала сторона'], Warnings: ['Масштаб <отличается>'] },
    null,
    { Ref: 'invalid', Path: '<invalid>' }
  ];
  env.evaluate(`renderCandidates(${JSON.stringify(candidates)})`);
  const markup = env.document.getElementById('suggestCandidatesList').innerHTML;
  assert.match(markup, /Высокое &lt;соответствие&gt;/);
  assert.match(markup, /Совпала &lt;роль&gt;/);
  assert.match(markup, /&quot;с кавычками&quot;/);
  assert.match(markup, /Масштаб &lt;отличается&gt;/);
  assert.match(markup, /Приблизительные замены — ручной выбор/);
  assert(markup.indexOf('Приблизительные замены') < markup.indexOf('Prefabs\/Second.et'));
  assert.doesNotMatch(markup, /100%|undefined|<invalid>|<роль>/);
});

test('late AI response cannot overwrite another picker or unlock its pending request', async () => {
  const aiResponses = [];
  const env = setup({ fetch: url => url === '/api/suggest' ? Promise.resolve(response([])) : new Promise(resolve => aiResponses.push(resolve)) });
  await env.evaluate(`openSuggestModal(${JSON.stringify(key(['Alpha']))})`);
  const oldRequest = env.evaluate('requestAiSuggest()');
  env.evaluate("closeModal('modalSuggest')");
  await env.evaluate(`openSuggestModal(${JSON.stringify(key([], otherRef))})`);
  const newRequest = env.evaluate('requestAiSuggest()');
  aiResponses[0](response({ ok: true, ai: { Status: 'match', Ref: targetRef, Reason: 'stale reason' }, candidates: [] }));
  await oldRequest;
  assert.equal(env.document.getElementById('btnAiSuggest').disabled, true);
  assert.doesNotMatch(env.document.getElementById('suggestAiRecommendation').innerHTML, /stale reason/);
  aiResponses[1](response({ ok: true, ai: { Status: 'match', Ref: secondTarget, Reason: 'fresh reason' }, candidates: [] }));
  await newRequest;
  assert.equal(env.document.getElementById('btnAiSuggest').disabled, false);
  assert.match(env.document.getElementById('suggestAiRecommendation').innerHTML, /fresh reason/);
  assert.equal(env.snapshot('gPendingOps').length, 0);
  env.evaluate('applyAiRecommendation()');
  assert.equal(env.snapshot('gModel.tree')[otherRef], secondTarget);
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], '');
});

test('AI cannot apply a stored recommendation while editor is busy or after picker closes', async () => {
  const env = setup({ fetch: async () => response({ ok: true, ai: { Status: 'match', Ref: targetRef, Reason: 'test' }, candidates: [] }) });
  env.evaluate(`gSuggestTarget = { key:${JSON.stringify(key(['Alpha']))}, oldRef:${JSON.stringify(oldRef)} }`);
  await env.evaluate('requestAiSuggest()');
  env.evaluate('gLoading = true; applyAiRecommendation(); gLoading = false;');
  assert.equal(env.snapshot('gPendingOps').length, 0);
  env.evaluate("closeModal('modalSuggest'); applyAiRecommendation()");
  assert.equal(env.snapshot('gPendingOps').length, 0);
});

test('usage view renders report rows and derives status from the live table', async () => {
  const env = setup();
  env.evaluate("switchMainTab('usage')");
  const body = env.document.getElementById('usageTableBody').innerHTML;
  assert.equal(env.document.getElementById('statUsageAll').textContent, 2);
  assert.match(body, /Region\/Mission, Region\/Other/);
  assert.equal(env.document.getElementById('statUsageBroken').textContent, 2);
  assert.match(env.document.getElementById('usageNotice').textContent, /2026-10-13/);
  assert.match(env.document.getElementById('usageNotice').textContent, /C:\/Legacy/);

  // Filling the entry in the table must flip the derived status without any reload: the
  // report stores no status of its own, so nothing can go stale here.
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  const key = oldRef.toLowerCase();
  assert.equal(env.evaluate(`gUsageState.get(${JSON.stringify(key)}).status`), 'mapped');
  assert.equal(env.evaluate(`gUsageState.get(${JSON.stringify(key)}).targetRef`), targetRef);
  assert.equal(env.document.getElementById('btnSaveBatch').style.display, 'inline-flex');
});

test('usage view reports a stale sweep instead of hiding outdated mission data', () => {
  const env = setup();
  env.evaluate("gUsageReport.stale = true; switchMainTab('usage')");
  const notice = env.document.getElementById('usageNotice').textContent;
  assert.match(notice, /Таблица замен изменилась после скана/);
  // Stale data is still rendered; the operator decides what to do with it.
  assert.equal(env.document.getElementById('statUsageAll').textContent, 2);
});

test('usage view explains an absent report instead of showing an empty table', () => {
  const env = setup();
  env.evaluate(`gUsageReport = { exists:false, stale:false, sourceRoot:'', scannedAt:'', missionCount:0, refCount:0, refs:[] };
    switchMainTab('usage')`);
  assert.match(env.document.getElementById('usageTableBody').innerHTML, /Отчёта по старым миссиям ещё нет/);
  assert.equal(env.document.getElementById('usageNotice').style.display, 'none');
});

test('an explicit legacy sweep refreshes the table and report', async () => {
  const env = setup({ fetch: async (url, options) => {
    if (url === '/api/legacy/scan') return response({ ok: true, written: true, sourceRoot: 'C:/Legacy',
      missions: ['Region/Mission', 'Region/Other'], total: 4, resolved: 1, mapped: 0, ignore: 0, external: 1,
      broken: 2, added: 1, addedRefs: [otherRef], reportPath: 'C:/Tools/legacy_refs_report.json' });
    if (url === '/api/table') return response({ tree: { Alpha: { [oldRef]: targetRef } }, versionHash: 'hash2' });
    if (url === '/api/legacy/report') return response({ exists: true, stale: false, sourceRoot: 'C:/Legacy',
      scannedAt: '2026-10-14T00:00:00Z', missionCount: 2, refCount: 1,
      refs: [{ fullRef: otherRef, usageCount: 4, missions: ['Region/Mission'], status: 'broken' }] });
    throw new Error('Unexpected endpoint ' + url);
  } });
  await env.evaluate('scanLegacy()');
  // The sweep wrote to the table, so the server hash replaced the stale one.
  assert.equal(env.snapshot('gBaseline.versionHash'), 'hash2');
  assert.equal(env.snapshot('gModel.tree').Alpha[oldRef], targetRef);
  assert.equal(env.snapshot('gUsageReport.refs')[0].fullRef, otherRef);
  assert.equal(env.snapshot('gUsageReport.refs')[0].usageCount, 4);
  assert.match(env.alerts.at(-1), /Добавлено новых заглушек: 1/);
  assert.match(env.alerts.at(-1), /Миссий: 2/);
  assert.equal(env.requests[0].options.headers['X-Restore-Token'], 'synthetic-token');
});

test('a legacy sweep is refused while edits are unsaved', async () => {
  const env = setup({ fetch: async () => { throw new Error('Unexpected endpoint'); } });
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  await env.evaluate('scanLegacy()');
  assert.equal(env.requests.length, 0);
  assert.match(env.alerts.at(-1), /Сначала сохраните или отмените/);
});

test('a failed legacy sweep surfaces the server error instead of claiming success', async () => {
  const env = setup({ fetch: async url => {
    if (url === '/api/legacy/scan') return response({ ok: false, error: 'DefaultSourceRoot = не задан.' }, false);
    throw new Error('Unexpected endpoint ' + url);
  } });
  await env.evaluate('scanLegacy()');
  assert.match(env.alerts.at(-1), /DefaultSourceRoot/);
  // A failed sweep must not pretend to have produced a report.
  assert.equal(env.snapshot('gUsageReport.refs').length, 2);
  assert.equal(env.snapshot('gBaseline.versionHash'), 'hash1');
});

test('catalog refresh preserves dirty working state and never rescans the legacy missions', async () => {
  const env = setup({ fetch: async url => {
    if (url === '/api/catalog/rebuild') return response({ ok: true, newCount: 1 });
    if (url === '/api/modindex') return response({ '3333333333333333': "Prefabs/New's.et" });
    if (url === '/api/catalog/new') return response([{ fullRef: targetRef, guid: '3333333333333333', path: "Prefabs/New's.et", category: 'Props' }]);
    throw new Error('Unexpected endpoint ' + url);
  } });
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  const queued = env.snapshot('gPendingOps');
  await env.evaluate('rebuildCatalogs()');
  assert.deepEqual(env.snapshot('gPendingOps'), queued);
  assert.equal(env.snapshot('gBaseline.versionHash'), 'hash1');
  assert.equal(env.snapshot('gModel.tree')["Unit's"].Exact[oldRef], targetRef);
  // Refreshing the prefab catalog must leave the usage report alone: a sweep is explicit.
  assert.equal(env.requests.some(request => request.url === '/api/legacy/report'), false);
  assert.equal(env.requests.some(request => request.url === '/api/legacy/scan'), false);
  assert.equal(env.requests.some(request => request.url === '/api/table'), false);
  assert.equal(env.snapshot('gUsageReport.refs')[0].usageCount, 2);
  assert.match(env.alerts.at(-1), /Префабов в каталоге: 1/);
  assert.equal(env.requests[0].options.headers['X-Restore-Token'], 'synthetic-token');
});

test('the editor exposes no legacy catalog surface', () => {
  const env = setup();
  for (const id of ['tabLegacy', 'toolbarLegacy', 'viewLegacy', 'legacyTableBody', 'searchLegacy', 'badgeLegacyUnmapped']) {
    assert.equal(env.nodes.has(id), false, `${id} must not exist any more`);
  }
  assert.equal(env.snapshot('gUsageReport.refs').length, 2);
  assert.equal(typeof env.evaluate('renderUsage'), 'function');
  assert.equal(env.evaluate('typeof renderLegacy'), 'undefined');
  assert.equal(env.evaluate('typeof gOldCatalog'), 'undefined');
});

// A fresh page load must not pay for the prefab catalog: it was ~7s of derivation and
// ~7MB of JSON, and only two tabs ever read it. The mod index stays eager on purpose,
// because validateLocalRef would otherwise report every filled entry as target-missing.
function deferredSetup(fetch) {
  const env = setup({ fetch });
  env.evaluate('gExternalLoaded = false; gExternalPromise = null; gNewCatalog = []; gUsageReport = { exists:false, stale:false, sourceRoot:"", scannedAt:"", missionCount:0, refCount:0, refs:[] }');
  return env;
}

const deferredFetch = async url => {
  if (url === '/api/catalog/new') return response([
    { fullRef: targetRef, guid: '3333333333333333', path: "Prefabs/New's.et", category: 'Props' }
  ]);
  if (url === '/api/legacy/report') return response({ exists: true, stale: false, sourceRoot: 'C:/Legacy',
    scannedAt: '2026-10-13T00:00:00Z', missionCount: 2, refCount: 2,
    refs: [{ fullRef: otherRef, usageCount: 4, missions: ['Region/Mission'], status: 'broken' }] });
  throw new Error('Unexpected endpoint ' + url);
};

test('the remap tab renders before the prefab catalog is ever requested', async () => {
  const env = deferredSetup(deferredFetch);
  await env.evaluate('loadAllData()');
  const requested = env.requests.map(request => request.url);
  // The mod index is required for correct statuses and must stay eager.
  assert.ok(requested.includes('/api/modindex'));
  assert.ok(requested.includes('/api/table'));
  // The catalog and the usage report must not be requested at all on the default tab.
  assert.equal(requested.includes('/api/catalog/new'), false);
  assert.equal(requested.includes('/api/legacy/report'), false);
  assert.equal(env.snapshot('gNewCatalog').length, 0);
  // A pending edit must validate against the live mod index. Without it every filled
  // entry degrades to target-missing, which would be a false alarm on the main tab.
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  const statuses = env.snapshot(`gModel.entries.filter(entry => entry.newRef).map(entry => entry.status)`);
  assert.equal(statuses.includes('target-missing'), false);
  assert.equal(statuses.includes('path-mismatch'), false);
  // Unknown counts are shown as unknown, never as a misleading zero.
  assert.equal(String(env.document.getElementById('badgeTruthCount').textContent), '…');
  assert.equal(String(env.document.getElementById('badgeUsageCount').textContent), '…');
});

test('the catalog and the usage report load once, on first visit to either dependent tab', async () => {
  const env = deferredSetup(deferredFetch);
  await env.evaluate('switchMainTab("truth")');
  assert.equal(env.snapshot('gNewCatalog').length, 1);
  assert.equal(env.snapshot('gUsageReport.refs').length, 1);
  assert.deepEqual(env.requests.map(request => request.url), ['/api/catalog/new', '/api/legacy/report']);
  assert.equal(String(env.document.getElementById('badgeTruthCount').textContent), '1');

  // Already-loaded tabs must stay synchronous and must not refetch.
  env.requests.length = 0;
  env.evaluate('switchMainTab("usage"); switchMainTab("truth"); switchMainTab("usage")');
  assert.equal(env.requests.length, 0);
  assert.equal(env.snapshot('gNewCatalog').length, 1);
});

test('the deferred load preserves unsaved edits and rebases them onto the new snapshots', async () => {
  const env = deferredSetup(deferredFetch);
  enqueue(env, [{ op: 'set', groupPath: ["Unit's", 'Exact'], oldRef, newRef: targetRef }]);
  const queued = env.snapshot('gPendingOps');
  await env.evaluate('switchMainTab("truth")');
  assert.deepEqual(env.snapshot('gPendingOps'), queued);
  assert.equal(env.snapshot('gModel.tree')["Unit's"].Exact[oldRef], targetRef);
  // deriveCatalogs must recompute mappedCount for the catalog that just arrived.
  assert.equal(env.snapshot('gNewCatalog')[0].mappedCount, 1);
});

test('a failed deferred load reports the error and falls back to the remap tab', async () => {
  const env = deferredSetup(async url => {
    if (url === '/api/catalog/new') return response({ error: 'nope' }, false);
    return deferredFetch(url);
  });
  await env.evaluate('switchMainTab("truth")');
  assert.match(env.alerts.at(-1), /Не удалось загрузить данные каталога/);
  assert.equal(env.evaluate('gActiveMainTab'), 'remap');
  // A failed attempt must not be cached as loaded: a retry has to try again.
  assert.equal(env.evaluate('gExternalLoaded'), false);
  assert.equal(env.evaluate('gExternalPromise'), null);
});

test('the picker catalog panel triggers the deferred load when reached from the remap tab', async () => {
  const env = deferredSetup(deferredFetch);
  await env.evaluate('switchSuggestMode("truth")');
  await new Promise(resolve => setImmediate(resolve));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(env.snapshot('gNewCatalog').length, 1);
  assert.deepEqual(env.requests.map(request => request.url), ['/api/catalog/new', '/api/legacy/report']);
});
