import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

process.umask(0o077);
const source = path.dirname(fileURLToPath(import.meta.url));
const runtime = path.join(os.homedir(), 'Library/Application Support/OpenDDPM/homekit');
const agentDirectory = path.join(os.homedir(), 'Library/LaunchAgents');
const plist = path.join(agentDirectory, 'io.github.prbigbrother.OpenDDPM.homekit.plist');
const domain = `gui/${process.getuid()}`;
const action = process.argv[2] || 'install';
if (![22, 24, 26].includes(Number(process.versions.node.split('.')[0]))) throw new Error('Use Node.js 22, 24 or 26');
const node = fs.realpathSync(process.execPath);
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure) throw new Error(`${path.basename(command)} exited ${result.status}`);
}
function stop() { run('/bin/launchctl', ['bootout', domain, plist], { allowFailure: true, stdio: 'ignore' }); }
const xml = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
try {
  if (!['install', 'start', 'stop'].includes(action)) throw new Error('Unknown HomeKit service action');
  if (action === 'stop') {
    stop();
    if (fs.existsSync(plist)) fs.unlinkSync(plist);
    fs.mkdirSync(runtime, { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(runtime, 'health.json'), JSON.stringify({ running: false, connected: false, time: new Date().toISOString() }), { mode: 0o600 });
  } else {
    stop();
    fs.mkdirSync(runtime, { recursive: true, mode: 0o700 });
    fs.mkdirSync(agentDirectory, { recursive: true });
    if (source !== runtime) for (const name of ['package.json', 'package-lock.json', 'bridge.mjs', 'install.mjs']) fs.copyFileSync(path.join(source, name), path.join(runtime, name));
    if (action === 'install' || !fs.existsSync(path.join(runtime, 'node_modules/@homebridge/hap-nodejs'))) {
      const npm = fs.realpathSync(path.join(path.dirname(node), 'npm'));
      run(node, [npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: runtime, env: { ...process.env, PATH: `${path.dirname(node)}:${process.env.PATH}` } });
    }
    const content = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.github.prbigbrother.OpenDDPM.homekit</string>
<key>ProgramArguments</key><array><string>${xml(node)}</string><string>${xml(path.join(runtime, 'bridge.mjs'))}</string></array>
<key>WorkingDirectory</key><string>${xml(runtime)}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>${xml(path.join(runtime, 'service.log'))}</string>
<key>StandardErrorPath</key><string>${xml(path.join(runtime, 'service-error.log'))}</string>
</dict></plist>`;
    fs.writeFileSync(plist, content, { mode: 0o600 });
    run('/bin/launchctl', ['bootstrap', domain, plist]);
    console.log('HomeKit service installed and started. Pair it from OpenDDPM settings.');
  }
} catch (error) { console.error(error.message); process.exit(1); }
