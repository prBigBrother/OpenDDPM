import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Accessory, AccessoryInfo, Bridge, Service, Characteristic as C, Categories, HAPStatus, HapStatusError, HAPStorage, uuid } from '@homebridge/hap-nodejs';
import QRCode from 'qrcode';

export class OpenDDPMClient {
  constructor(connectionPath) { this.connectionPath = connectionPath; }
  async call(method, endpoint, body) {
    const connection = JSON.parse(await fs.readFile(this.connectionPath, 'utf8'));
    if (!Number.isInteger(connection.port) || connection.port < 1024 || connection.port > 65535 || typeof connection.token !== 'string') throw new Error('Invalid local-control configuration');
    const response = await fetch(`http://127.0.0.1:${connection.port}${endpoint}`, {
      method, headers: { Authorization: `Bearer ${connection.token}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(3000), redirect: 'error',
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'OpenDDPM unavailable');
    return result;
  }
  presets() { return this.call('GET', '/presets'); }
  status() { return this.call('GET', '/status'); }
  apply(preset) { return this.call('POST', '/apply', { preset }); }
  previous() { return this.call('POST', '/previous'); }
  refresh() { return this.call('POST', '/refresh', { quiet: true }); }
}

export function assignIdentifiers(identity, presets) {
  identity.inputs ??= {};
  let next = Math.max(0, ...Object.values(identity.inputs)) + 1;
  for (const preset of presets) if (!identity.inputs[preset.id]) identity.inputs[preset.id] = next++;
  return identity.inputs;
}

export function buildAccessories(presets, identity, client) {
  const identifiers = assignIdentifiers(identity, presets);
  const television = new Accessory('OpenDDPM Monitor', uuid.generate(`openddpm:tv:${identity.seed}`));
  television.category = Categories.TELEVISION;
  television.getService(Service.AccessoryInformation)
    .setCharacteristic(C.Manufacturer, 'OpenDDPM')
    .setCharacteristic(C.Model, 'Preset controller')
    .setCharacteristic(C.SerialNumber, identity.seed)
    .setCharacteristic(C.FirmwareRevision, '0.3.0');
  const tv = television.addService(Service.Television, 'Monitor');
  tv.setCharacteristic(C.ConfiguredName, 'Monitor')
    .setCharacteristic(C.SleepDiscoveryMode, C.SleepDiscoveryMode.ALWAYS_DISCOVERABLE);
  let latest = null;
  const available = () => latest && Date.now() - latest.received < 12000 && latest.value.configured;
  const confirmedID = () => {
    if (!available() || ['queued', 'applying'].includes(latest.value.state.phase) || !latest.value.state.observedAt || Date.now() - Date.parse(latest.value.state.observedAt) > 15000) throw new HapStatusError(HAPStatus.SERVICE_COMMUNICATION_FAILURE);
    return latest.value.state.verifiedPresetID;
  };
  tv.getCharacteristic(C.Active).onGet(() => {
    if (!available() || ['failed', 'unverified', 'unavailable'].includes(latest.value.state.phase)) throw new HapStatusError(HAPStatus.SERVICE_COMMUNICATION_FAILURE);
    return C.Active.ACTIVE;
  }).onSet(value => {
    // This accessory selects presets. Power commands are deliberately unsupported.
    if (value !== C.Active.ACTIVE) throw new HapStatusError(HAPStatus.NOT_ALLOWED_IN_CURRENT_STATE);
  });
  tv.getCharacteristic(C.ActiveIdentifier).onGet(() => identifiers[confirmedID()] || 0).onSet(async value => {
    const preset = presets.find(p => identifiers[p.id] === value && !p.blocked);
    if (!preset) throw new HapStatusError(HAPStatus.INVALID_VALUE_IN_REQUEST);
    try { await client.apply(preset.id); } catch { throw new HapStatusError(HAPStatus.SERVICE_COMMUNICATION_FAILURE); }
  });
  tv.getCharacteristic(C.RemoteKey).onSet(async value => {
    if (value !== C.RemoteKey.BACK) throw new HapStatusError(HAPStatus.NOT_ALLOWED_IN_CURRENT_STATE);
    try { await client.previous(); } catch { throw new HapStatusError(HAPStatus.SERVICE_COMMUNICATION_FAILURE); }
  });
  const sceneBridge = new Bridge('OpenDDPM Scenes', uuid.generate(`openddpm:scenes:${identity.seed}`));
  const switches = [];
  for (const preset of presets) {
    const input = television.addService(Service.InputSource, preset.name, preset.id);
    input.setCharacteristic(C.Identifier, identifiers[preset.id])
      .setCharacteristic(C.ConfiguredName, preset.name)
      .setCharacteristic(C.InputSourceType, C.InputSourceType.OTHER)
      .setCharacteristic(C.IsConfigured, preset.blocked ? C.IsConfigured.NOT_CONFIGURED : C.IsConfigured.CONFIGURED)
      .setCharacteristic(C.CurrentVisibilityState, preset.blocked ? C.CurrentVisibilityState.HIDDEN : C.CurrentVisibilityState.SHOWN);
    tv.addLinkedService(input);
    const accessory = new Accessory(preset.name, uuid.generate(`openddpm:preset:${preset.id}`));
    const service = accessory.addService(Service.Switch, preset.name);
    // Momentary switches trigger scenes without falsely claiming a monitor state.
    service.getCharacteristic(C.On).onGet(() => false).onSet(async value => {
      if (!value) return;
      if (preset.blocked) throw new HapStatusError(HAPStatus.NOT_ALLOWED_IN_CURRENT_STATE);
      try { await client.apply(preset.id); } catch { throw new HapStatusError(HAPStatus.SERVICE_COMMUNICATION_FAILURE); }
      setTimeout(() => service.updateCharacteristic(C.On, false), 400).unref();
    });
    switches.push(service);
    sceneBridge.addBridgedAccessory(accessory);
  }
  return {
    television, sceneBridge, tv, identifiers, switches,
    acceptStatus(value) {
      latest = { value, received: Date.now() };
      try { tv.updateCharacteristic(C.ActiveIdentifier, identifiers[confirmedID()] || 0); } catch { /* retain last observation, GET reports unavailable */ }
    },
    clearStatus() { latest = null; },
  };
}

function makePIN() {
  for (;;) {
    const digits = Array.from({ length: 8 }, () => crypto.randomInt(10)).join('');
    if (/^(\d)\1+$/.test(digits) || ['12345678', '87654321'].includes(digits)) continue;
    return `${digits.slice(0, 3)}-${digits.slice(3, 5)}-${digits.slice(5)}`;
  }
}
async function privateJSON(file, value) {
  await fs.writeFile(`${file}.new`, JSON.stringify(value, null, 2), { mode: 0o600 });
  await fs.rename(`${file}.new`, file);
}

export async function startBridge(directory = path.join(os.homedir(), 'Library/Application Support/OpenDDPM/homekit')) {
  process.umask(0o077);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  HAPStorage.setCustomStoragePath(path.join(directory, 'pairings'));
  const identityPath = path.join(directory, 'identity.json');
  let identity;
  try { identity = JSON.parse(await fs.readFile(identityPath, 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    identity = { seed: crypto.randomUUID(), pin: makePIN(), tv: `02:${crypto.randomBytes(5).toString('hex').match(/../g).join(':')}`.toUpperCase(), scenes: `02:${crypto.randomBytes(5).toString('hex').match(/../g).join(':')}`.toUpperCase(), inputs: {} };
  }
  const client = new OpenDDPMClient(path.join(directory, '..', 'control.json'));
  let controller = null, presetSignature = '', polling = false;
  const healthPath = path.join(directory, 'health.json');
  async function publish(presets) {
    if (controller) { await controller.television.unpublish(); await controller.sceneBridge.unpublish(); }
    controller = buildAccessories(presets, identity, client);
    await privateJSON(identityPath, identity);
    await controller.television.publish({ username: identity.tv, pincode: identity.pin, category: Categories.TELEVISION, port: 57572 });
    await controller.sceneBridge.publish({ username: identity.scenes, pincode: identity.pin, category: Categories.BRIDGE, port: 57573 });
    await QRCode.toFile(path.join(directory, 'television.png'), controller.television.setupURI(), { width: 240, margin: 2 });
    await QRCode.toFile(path.join(directory, 'scenes.png'), controller.sceneBridge.setupURI(), { width: 240, margin: 2 });
    await privateJSON(path.join(directory, 'pairing.json'), { pin: identity.pin, televisionPaired: (AccessoryInfo.load(identity.tv)?.paired() ?? false), scenesPaired: (AccessoryInfo.load(identity.scenes)?.paired() ?? false) });
    presetSignature = JSON.stringify(presets);
  }
  async function poll() {
    if (polling) return;
    polling = true;
    try {
      const presets = await client.presets();
      if (!Array.isArray(presets) || presets.length > 90) throw new Error('HomeKit supports up to 90 OpenDDPM presets');
      if (JSON.stringify(presets) !== presetSignature) await publish(presets);
      const status = await client.status();
      controller.acceptStatus(status);
      if (!status.busy) await client.refresh();
      await privateJSON(path.join(directory, 'pairing.json'), { pin: identity.pin, televisionPaired: (AccessoryInfo.load(identity.tv)?.paired() ?? false), scenesPaired: (AccessoryInfo.load(identity.scenes)?.paired() ?? false) });
      await privateJSON(healthPath, { running: true, connected: true, time: new Date().toISOString() });
    } catch (error) {
      controller?.clearStatus();
      await privateJSON(healthPath, { running: true, connected: false, error: error.message, time: new Date().toISOString() });
    } finally { polling = false; }
  }
  await poll();
  const timer = setInterval(poll, 4000);
  const stop = async () => {
    clearInterval(timer);
    if (controller) { await controller.television.unpublish(); await controller.sceneBridge.unpublish(); }
    await privateJSON(healthPath, { running: false, connected: false, time: new Date().toISOString() });
    process.exit(0);
  };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
  console.log('OpenDDPM HomeKit service started. Pairing details are available in OpenDDPM settings.');
  return { poll, stop };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  startBridge().catch(error => { console.error(`HomeKit service failed: ${error.message}`); process.exit(1); });
}
