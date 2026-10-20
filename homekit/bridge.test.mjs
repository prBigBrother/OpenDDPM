import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Characteristic as C } from '@homebridge/hap-nodejs';
import { assignIdentifiers, buildAccessories, OpenDDPMClient } from './bridge.mjs';

test('HomeKit identifiers survive reordering, deletion and new presets', () => {
  const identity = {};
  assignIdentifiers(identity, [{ id: 'a' }, { id: 'b' }]);
  const a = identity.inputs.a, b = identity.inputs.b;
  assignIdentifiers(identity, [{ id: 'b' }, { id: 'c' }, { id: 'a' }]);
  assert.equal(identity.inputs.a, a); assert.equal(identity.inputs.b, b); assert.ok(identity.inputs.c > b);
});

test('TV inputs and scene switches dispatch complete presets through the shared API', async () => {
  const calls = [];
  const presets = [{ id: 'safe', name: 'Personal', blocked: false }, { id: 'blocked', name: 'Hidden', blocked: true }];
  const controller = buildAccessories(presets, { seed: 'test', inputs: {} }, { apply: async id => calls.push(id), previous: async () => calls.push('previous') });
  await controller.tv.getCharacteristic(C.ActiveIdentifier).handleSetRequest(controller.identifiers.safe);
  assert.deepEqual(calls, ['safe']);
  await assert.rejects(controller.tv.getCharacteristic(C.ActiveIdentifier).handleSetRequest(controller.identifiers.blocked));
  await controller.switches[0].getCharacteristic(C.On).handleSetRequest(true);
  assert.deepEqual(calls, ['safe', 'safe']);
  await assert.rejects(controller.switches[1].getCharacteristic(C.On).handleSetRequest(true));
  controller.acceptStatus({ configured: true, busy: false, state: { observedAt: new Date().toISOString(), verifiedPresetID: 'safe', phase: 'verified' } });
  assert.equal(await controller.tv.getCharacteristic(C.ActiveIdentifier).handleGetRequest(), controller.identifiers.safe);
  controller.acceptStatus({ configured: true, busy: true, state: { observedAt: null, verifiedPresetID: 'safe' } });
  await assert.rejects(controller.tv.getCharacteristic(C.ActiveIdentifier).handleGetRequest());
  controller.clearStatus();
  await assert.rejects(controller.tv.getCharacteristic(C.Active).handleGetRequest());
});

test('API client authenticates locally and preserves request IDs', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'openddpm-hap-'));
  const server = http.createServer(async (req, res) => {
    assert.equal(req.headers.authorization, 'Bearer test-token');
    assert.equal(req.url, '/apply');
    let body = ''; for await (const chunk of req) body += chunk;
    assert.deepEqual(JSON.parse(body), { preset: 'safe' });
    res.writeHead(202, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ requestID: 'request-1' }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const file = path.join(directory, 'control.json');
    await fs.writeFile(file, JSON.stringify({ port: server.address().port, token: 'test-token' }));
    assert.deepEqual(await new OpenDDPMClient(file).apply('safe'), { requestID: 'request-1' });
  } finally { await new Promise(resolve => server.close(resolve)); await fs.rm(directory, { recursive: true }); }
});
