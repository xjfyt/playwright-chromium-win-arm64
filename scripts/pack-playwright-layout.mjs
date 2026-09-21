#!/usr/bin/env node
/**
 * Pack a locally built Chromium out\Default into Playwright 1.62 layout:
 *   chromium-1234/chrome-win64/chrome.exe  (PE must be AA64)
 *
 * Pin (do not change): Playwright 1.62.0 / rev 1234 / CFT 151.0.7922.34
 * Nexora name: playwright-chromium-windows-aarch64-1.62.1234+cn.1
 *
 * Refuses Program Files Google Chrome / Edge.
 *
 * Usage:
 *   node scripts/pack-playwright-layout.mjs --from-dir <out\Default>
 *   node scripts/pack-playwright-layout.mjs --from-dir ... --format zip
 */
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

const PLAYWRIGHT_VERSION = '1.62.0';
const REVISION = '1234';
const BROWSER_VERSION = '151.0.7922.34';
const KEY = 'playwright-chromium';
const OS_NAME = 'windows';
const ARCH = 'aarch64';
const FOLDER = 'chrome-win64';
const VERSION = '1.62.1234+cn.1';

const SKIP_DIRS = new Set([
  'obj', 'gen', 'thinlto-cache', '.git', 'clang_newlib_x64', 'pyproto', 'rustc_sysroot',
]);
const SKIP_FILES = new Set([
  'build.ninja', '.ninja_deps', '.ninja_log', 'args.gn', 'toolchain.ninja',
  'mini_installer.exe', 'setup.exe',
]);
const SKIP_EXT = new Set(['.pdb', '.lib', '.obj', '.ilk', '.exp', '.iobj', '.ipdb', '.o']);

function parseArgs(argv) {
  const out = {
    fromDir: '',
    outDir: path.join(ROOT, 'work'),
    format: '7z', // 7z | zip
  };
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    if (t === '--from-dir') out.fromDir = path.resolve(String(argv[++i] || ''));
    else if (t === '--out-dir') out.outDir = path.resolve(argv[++i]);
    else if (t === '--format') out.format = String(argv[++i]).toLowerCase();
    else if (t === '--help' || t === '-h') out.help = true;
    else throw new Error(`Unknown arg: ${t}`);
  }
  return out;
}

function windowsPeMachine(filePath) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const dos = Buffer.alloc(64);
    fs.readSync(fd, dos, 0, 64, 0);
    if (dos[0] !== 0x4d || dos[1] !== 0x5a) return 0;
    const peOff = dos.readUInt32LE(60);
    const pe = Buffer.alloc(6);
    fs.readSync(fd, pe, 0, 6, peOff);
    if (pe[0] !== 0x50 || pe[1] !== 0x45) return 0;
    return pe.readUInt16LE(4);
  } finally {
    fs.closeSync(fd);
  }
}

function assertAa64(exeAbs) {
  const machine = windowsPeMachine(exeAbs);
  const label = machine === 0xaa64 ? 'arm64' : machine === 0x8664 ? 'x64' : `0x${machine.toString(16)}`;
  if (machine !== 0xaa64) {
    throw new Error(
      `${exeAbs} is ${label}; need ARM64 (AA64). Do not pack x64 chrome.exe or Program Files Chrome/Edge.`,
    );
  }
}

function looksLikeProgramFilesBrowser(dir) {
  const norm = path.resolve(dir).toLowerCase();
  return (
    norm.includes(`${path.sep}google${path.sep}chrome${path.sep}`)
    || norm.includes(`${path.sep}microsoft${path.sep}edge${path.sep}`)
    || norm.endsWith(`${path.sep}google${path.sep}chrome${path.sep}application`)
    || norm.endsWith(`${path.sep}microsoft${path.sep}edge${path.sep}application`)
  );
}

function shouldSkip(name, isDir) {
  const lower = name.toLowerCase();
  if (isDir) return SKIP_DIRS.has(lower);
  if (SKIP_FILES.has(lower)) return true;
  return SKIP_EXT.has(path.extname(lower));
}

function copyTree(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  for (const ent of fs.readdirSync(srcDir, { withFileTypes: true })) {
    if (shouldSkip(ent.name, ent.isDirectory())) continue;
    const from = path.join(srcDir, ent.name);
    const to = path.join(destDir, ent.name);
    if (ent.isSymbolicLink()) continue;
    if (ent.isDirectory()) copyTree(from, to);
    else if (ent.isFile()) fs.copyFileSync(from, to);
  }
}

function findChromeExe(root) {
  const direct = path.join(root, 'chrome.exe');
  if (fs.existsSync(direct) && fs.statSync(direct).isFile()) return direct;
  const stack = [{ dir: root, depth: 0 }];
  while (stack.length) {
    const { dir, depth } = stack.pop();
    if (depth > 3) continue;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ent of entries) {
      if (ent.isFile() && ent.name.toLowerCase() === 'chrome.exe') {
        return path.join(dir, ent.name);
      }
      if (ent.isDirectory() && !SKIP_DIRS.has(ent.name.toLowerCase())) {
        stack.push({ dir: path.join(dir, ent.name), depth: depth + 1 });
      }
    }
  }
  return '';
}

function resolve7z() {
  const candidates = [
    process.env.SEVEN_ZIP,
    '7z',
    path.join(process.env.ProgramFiles || '', '7-Zip', '7z.exe'),
    path.join(process.env.ProgramFiles || '', 'NanaZip', 'NanaZipC.exe'),
    path.join(process.env['ProgramFiles(x86)'] || '', '7-Zip', '7z.exe'),
  ].filter(Boolean);
  for (const c of candidates) {
    const look = spawnSync(c, [], { encoding: 'utf8' });
    const text = `${look.stdout || ''}\n${look.stderr || ''}`;
    if (look.error) continue;
    if (/7-Zip|NanaZip|7z/i.test(text) || look.status === 0) return c;
  }
  return '';
}

function sha256file(filePath) {
  return createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function packArchive(stageDir, archivePath, format) {
  fs.mkdirSync(path.dirname(archivePath), { recursive: true });
  if (fs.existsSync(archivePath)) fs.unlinkSync(archivePath);
  const folder = `chromium-${REVISION}`;
  if (format === '7z') {
    const seven = resolve7z();
    if (!seven) throw new Error('7z not found; pass --format zip or install 7-Zip/NanaZip');
    const args = ['a', '-t7z', '-mx=9', '-m0=lzma2', '-md=32m', '-mmt=on', archivePath, folder];
    console.log(`[INFO] ${seven} ${args.join(' ')}`);
    const packed = spawnSync(seven, args, { cwd: stageDir, stdio: 'inherit' });
    if (packed.status !== 0) throw new Error(`7z failed: ${packed.status}`);
    return;
  }
  // zip via tar (Windows 10+ / GitHub runners) or PowerShell Compress-Archive fallback
  const tar = spawnSync('tar', ['-a', '-cf', archivePath, folder], { cwd: stageDir, stdio: 'inherit' });
  if (tar.status === 0) return;
  if (process.platform === 'win32') {
    const ps = spawnSync(
      'powershell.exe',
      [
        '-NoProfile', '-Command',
        `Compress-Archive -Path (Join-Path '${stageDir}' '${folder}') -DestinationPath '${archivePath}' -Force`,
      ],
      { stdio: 'inherit' },
    );
    if (ps.status === 0) return;
  }
  throw new Error(`zip pack failed (tar=${tar.status})`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.fromDir) {
    console.log('node scripts/pack-playwright-layout.mjs --from-dir <chromium out\\Default> [--format 7z|zip] [--out-dir work]');
    if (!args.fromDir) process.exitCode = args.help ? 0 : 1;
    return;
  }
  if (!['7z', 'zip'].includes(args.format)) throw new Error('--format must be 7z or zip');
  if (!fs.existsSync(args.fromDir)) throw new Error(`--from-dir missing: ${args.fromDir}`);
  if (looksLikeProgramFilesBrowser(args.fromDir)) {
    throw new Error('Refusing Program Files Google Chrome / Edge. Only self-built Chromium out\\Default.');
  }

  const exe = findChromeExe(args.fromDir);
  if (!exe) throw new Error(`chrome.exe not found under ${args.fromDir}`);
  assertAa64(exe);
  const srcDir = path.dirname(exe);

  const stageDir = path.join(args.outDir, `stage-${OS_NAME}-${ARCH}`);
  fs.rmSync(stageDir, { recursive: true, force: true });
  const destFolder = path.join(stageDir, `chromium-${REVISION}`, FOLDER);
  console.log(`[INFO] stage ${srcDir} -> ${destFolder}`);
  copyTree(srcDir, destFolder);

  const exeRel = `chromium-${REVISION}/${FOLDER}/chrome.exe`;
  const exeAbs = path.join(stageDir, ...exeRel.split('/'));
  if (!fs.existsSync(exeAbs)) throw new Error(`staging missing ${exeRel}`);
  assertAa64(exeAbs);

  const ext = args.format === '7z' ? '7z' : 'zip';
  const archiveName = `${KEY}-${OS_NAME}-${ARCH}-${VERSION}.${ext}`;
  const archivePath = path.join(args.outDir, archiveName);
  const manifestPath = path.join(args.outDir, archiveName.replace(/\.(7z|zip)$/, '.json'));

  packArchive(stageDir, archivePath, args.format);

  const sizeBytes = fs.statSync(archivePath).size;
  const sha256 = sha256file(archivePath);
  const manifest = {
    key: KEY,
    name: 'Playwright Chromium',
    category: 'tool',
    version: VERSION,
    playwright_version: PLAYWRIGHT_VERSION,
    chromium_revision: REVISION,
    browser_version: BROWSER_VERSION,
    os: OS_NAME,
    arch: ARCH,
    format: args.format,
    exe_rel_path: exeRel,
    sha256,
    size_bytes: sizeBytes,
    variant: 'chromium',
    source_url: `local:${args.fromDir}`,
    layout: `PLAYWRIGHT_BROWSERS_PATH/${exeRel}`,
    pe_machine: 'AA64',
    notes:
      'Windows ARM64 Chromium staged as chrome-win64/chrome.exe for Playwright 1.62. Native ARM64 PE. Not Google Chrome / Edge from Program Files.',
    packed_at: new Date().toISOString(),
    packer: os.hostname(),
  };
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

  fs.rmSync(stageDir, { recursive: true, force: true });

  console.log(`[OK] archive ${archivePath}`);
  console.log(`[OK] sha256 ${sha256}`);
  console.log(`[OK] size_bytes ${sizeBytes}`);
  console.log(`[OK] exe_rel_path ${exeRel}`);
  console.log(`[OK] manifest ${manifestPath}`);
}

main();
