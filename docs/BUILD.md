# Build Chromium for Windows ARM64 (Playwright 1.62 / rev 1234)

Pinned:

- Playwright Python **1.62.0**
- Chromium revision **1234**
- Chrome tag **151.0.7922.34**
- Output layout: `chromium-1234/chrome-win64/chrome.exe` (PE Machine = **AA64**)

Do **not** change these pins. Do **not** redistribute Google Chrome / Edge from Program Files.

CI: GitHub-hosted Windows ARM — default `windows-11-vs2026-arm` (AtlasGraph reference: `windows-11-arm`, see https://github.com/xjfyt/AtlasGraph/blob/master/.github/workflows/release.yml). Disk is tight; scripts reclaim aggressively. Do **not** silently switch runners on disk failure.


## CI multi-stage + cache (hosted)

GitHub-hosted jobs stop at **6 hours**. Do not set `timeout-minutes: 720` expecting a longer run.

- Workflow: `probe` → `sync` (SKIP_BUILD, warm `GCLIENT_CACHE_DIR`) → `build` (restore cache, compile, pack, release).
- Actions cache holds **depot_tools + gclient object cache** only. Full `src/` is too large for cache/artifacts.
- Env: `GCLIENT_CACHE_DIR` / `GIT_CACHE_PATH`; `DELETE_GIT_AFTER_SYNC=1` removes `.git` **without** `git gc --aggressive`.
- Before that delete (and again before `gn gen` if `src\.git` is already gone), the script sets `generate_location_tags = false` in `src/build/config/gclient_args.gni`. On tag 151.0.7922.34, `//tools/metrics:histograms_xml` exists only when `//.git` is present, but `metrics_metadata` still depends on it while the flag is true (gclient hooks). Leaving the flag true after the delete makes `gn gen` fail with unresolved dependencies (run 35953615443). `tests_have_location_tags` defaults to the same flag. After the delete, aggressive reclaim still removes `third_party/rust-toolchain/lib/rustlib/src`. It must **not** delete `third_party/llvm-build/Release+Asserts/lib`: `target_cpu = "arm64"` builds `win_clang_x64_for_rust_host_build_tools` against `lib/clang/*/lib/windows/clang_rt.builtins-x86_64.lib` (keep the other `clang_rt` libs in that `windows` folder, including `clang_rt.builtins-aarch64.lib`, for the chrome link). Deleting the whole `lib` tree made `autoninja` fail immediately after `gn gen` (run 35967597337).
- Optional workflow input `skip_sync_job` skips the warm job (build still syncs).

Automated: `scripts/build-chromium-win-arm64.ps1` (sections 2–4) then `scripts/pack-playwright-layout.mjs`.

---

## 0. Probe public zips first

```powershell
$urls = @(
  'https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/win-arm64/chrome-win-arm64.zip',
  'https://cdn.playwright.dev/builds/chromium/1234/chromium-win-arm64.zip',
  'https://cdn.playwright.dev/builds/chromium/1234/chromium-win32_arm64.zip'
)
foreach ($u in $urls) {
  try {
    $r = Invoke-WebRequest -Method Head -Uri $u -MaximumRedirection 5 -TimeoutSec 30
    "{0}  {1}" -f $r.StatusCode, $u
  } catch {
    "FAIL  $u  $($_.Exception.Message)"
  }
}
```

- All 404 → continue with this guide  
- Any 200 → prefer the official zip; stop self-building for that pin  

---

## 1. Machine requirements

| Item | Requirement |
|------|-------------|
| OS | Windows 11 **ARM64** (native) |
| Disk | **≥ 100 GB** free ideal; hosted ARM often less — use AGGRESSIVE_DISK |
| Visual Studio | Desktop C++ + **MSVC ARM64** + Windows 11 SDK (image `windows-11-vs2026-arm` helps) |
| Git | Git for Windows ARM64 |
| Node | 20+ (pack script) |
| 7-Zip / NanaZip | `7z` on PATH |
| Time | roughly 2–8 hours |

Env vars (optional):

| Variable | Default |
|----------|---------|
| `DEPOT_TOOLS` | `D:\depot_tools` (or `$env:RUNNER_TEMP\depot_tools` on CI) |
| `CHROMIUM_ROOT` | `D:\chromium` (or large scratch on CI) |

---

## 2. Install depot_tools

```powershell
$depot = $env:DEPOT_TOOLS; if (-not $depot) { $depot = 'D:\depot_tools' }
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $depot
$env:Path = "$depot;" + $env:Path
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
gclient
```

Follow [Chromium Windows build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/windows_build_instructions.md). Missing ARM64 MSVC will fail `gclient` / `gn`.

---

## 3. Fetch tag 151.0.7922.34

```powershell
$root = $env:CHROMIUM_ROOT; if (-not $root) { $root = 'D:\chromium' }
New-Item -ItemType Directory -Force -Path $root | Out-Null
Set-Location $root
fetch --nohooks chromium
Set-Location src
git fetch origin tag 151.0.7922.34
git checkout 151.0.7922.34
gclient sync --with_branch_heads --with_tags
```

If the tag is missing from the default remote:

```powershell
git fetch https://chromium.googlesource.com/chromium/src.git +refs/tags/151.0.7922.34:refs/tags/151.0.7922.34
git checkout 151.0.7922.34
gclient sync --with_branch_heads --with_tags
```

---

## 4. Configure and compile

```powershell
Set-Location (Join-Path $env:CHROMIUM_ROOT 'src')
gn gen out\Default --args="is_debug=false is_official_build=true symbol_level=0 blink_symbol_level=0 target_cpu=""arm64"""
autoninja -C out\Default chrome
```

Notes:

- Do not enable `proprietary_codecs` unless you understand codec licensing  
- This builds **open-source Chromium**, not Google-signed Chrome  
- Smoke test: `.\out\Default\chrome.exe --version`

### PE Machine check (must be AA64)

```powershell
$exe = Join-Path $env:CHROMIUM_ROOT 'src\out\Default\chrome.exe'
$bytes = [System.IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
# 0xAA64 = ARM64; 0x8664 = x64
"{0:X}" -f $machine
```

If you see `8664`, you built x64 — do not pack or upload.

---

## 5. Pack Playwright layout

```powershell
node scripts/pack-playwright-layout.mjs --from-dir <CHROMIUM_ROOT>\src\out\Default
```

Produces under `work/`:

- `playwright-chromium-windows-aarch64-1.62.1234+cn.1.7z`
- `playwright-chromium-windows-aarch64-1.62.1234+cn.1.json`

Inner tree: `chromium-1234/chrome-win64/chrome.exe`

The packer strips `pdb` / `obj` / `gen`, refuses Program Files Chrome/Edge, and verifies AA64.

---

## 6. Common failures

| Symptom | Fix |
|---------|-----|
| `gn` / `autoninja` missing ARM64 toolchain | MSVC ARM64 + `DEPOT_TOOLS_WIN_TOOLCHAIN=0` |
| Packer reports x64 | Wrong arch; do not rename x64 chrome-win64 |
| Packer refuses Program Files | Expected; compile Chromium |
| Disk full on hosted ARM | Keep `windows-11-arm` / `windows-11-vs2026-arm`; report logs; do not silently switch |
| `gn gen`: `metrics_metadata` needs `histograms_xml` | `DELETE_GIT_AFTER_SYNC` must set `generate_location_tags = false` in `build/config/gclient_args.gni` **before** removing `src\.git` |
| `autoninja`: missing `clang_rt.builtins-x86_64.lib` | Do not delete `third_party/llvm-build/Release+Asserts/lib` during disk reclaim. Rust host tools still link that x86_64 builtins archive when `target_cpu = "arm64"` |
| Playwright cannot find browser | Must be `chromium-1234/chrome-win64/`, not `chrome-win-arm64/` |
