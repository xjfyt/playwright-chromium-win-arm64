#Requires -Version 5.1
<#
.SYNOPSIS
  Automate Chromium fetch + ARM64 build for Playwright 1.62 / rev 1234 (guide sections 2–4).

.DESCRIPTION
  Pins (do not change):
    - Playwright Python 1.62.0 / Chromium revision 1234 / Chrome tag 151.0.7922.34

  Env:
    DEPOT_TOOLS   - path to depot_tools (default: $env:RUNNER_TEMP\depot_tools or D:\depot_tools)
    CHROMIUM_ROOT - parent of src/ (default: $env:RUNNER_TEMP\chromium or D:\chromium)
    GCLIENT_CACHE_DIR - optional git/gclient object cache (speeds re-sync across CI jobs)
    SKIP_FETCH    - "1" to skip fetch/sync when checkout exists
    SKIP_BUILD    - "1" to skip gn/autoninja
    AGGRESSIVE_DISK - "1" (default on CI) reclaim disk after sync / mid-build
    DELETE_GIT_AFTER_SYNC - "1" remove src\.git after sync (skip slow git gc).
                         Before the delete, set generate_location_tags=false in
                         src\build\config\gclient_args.gni so gn gen does not
                         depend on histograms_xml (defined only if // .git exists).

  Does NOT pack; run scripts/pack-playwright-layout.mjs afterwards.
#>
$ErrorActionPreference = 'Stop'

$ChromeTag = '151.0.7922.34'
$PlaywrightRevision = '1234'
$PlaywrightVersion = '1.62.0'

function Default-Scratch([string]$name) {
  if ($env:RUNNER_TEMP) { return (Join-Path $env:RUNNER_TEMP $name) }
  return "D:\$name"
}

$DepotTools = if ($env:DEPOT_TOOLS) { $env:DEPOT_TOOLS } else { Default-Scratch 'depot_tools' }
$ChromiumRoot = if ($env:CHROMIUM_ROOT) { $env:CHROMIUM_ROOT } else { Default-Scratch 'chromium' }
$Src = Join-Path $ChromiumRoot 'src'
$GclientCache = if ($env:GCLIENT_CACHE_DIR) { ($env:GCLIENT_CACHE_DIR -replace '\\', '/') } else { $null }
$Aggressive = if ($null -ne $env:AGGRESSIVE_DISK -and $env:AGGRESSIVE_DISK -ne '') { $env:AGGRESSIVE_DISK } else { if ($env:GITHUB_ACTIONS) { '1' } else { '0' } }

function Write-Info([string]$msg) { Write-Host ("[INFO] {0} {1}" -f (Get-Date -Format 'o'), $msg) }
function Write-Warn([string]$msg) { Write-Host ("[WARN] {0} {1}" -f (Get-Date -Format 'o'), $msg) -ForegroundColor Yellow }

function Show-Disk {
  Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    Write-Info ("Drive {0}: free={1:N1} GB used={2:N1} GB" -f $_.Name, ($_.Free/1GB), (($_.Used)/1GB))
  }
}

function Assert-Arm64Host {
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -ne 'ARM64') {
    throw "Host PROCESSOR_ARCHITECTURE=$arch; need native Windows ARM64."
  }
}

# GitHub Actions runner.temp is often C:\a\_temp. fetch.py writes cache_dir into
# .gclient via "%s" % path (no escape). Python exec then turns \a into BEL (\x07),
# so Windows treats "C:<BEL>\_temp\..." as a *drive-relative* path under cwd
# (ChromiumRoot) and makedirs fails with WinError 123 on ...\chromium\<BEL>.
# Forward slashes are accepted by Win32 and are safe inside Python string literals.
function ConvertTo-PySafeWinPath([string]$p) {
  if (-not $p) { return $p }
  return ($p -replace '\\', '/')
}

# GitHub-hosted runners reach gs://chromium-git-cache at ~1-2 KiB/s (run 35940687183
# burned ~2h51m on gsutil and never finished fetch). Only enable --git-cache /
# GIT_CACHE_PATH when Actions restore already left real pack files on disk.
function Test-GclientCacheWarm {
  if (-not $GclientCache) { return $false }
  if (-not (Test-Path $GclientCache)) { return $false }
  $packs = @(Get-ChildItem -Path $GclientCache -Recurse -Filter '*.pack' -ErrorAction SilentlyContinue | Select-Object -First 3)
  if ($packs.Count -ge 1) {
    Write-Info ("gclient-cache WARM: found {0} pack sample(s) under {1}" -f $packs.Count, $GclientCache)
    return $true
  }
  Write-Warn "gclient-cache COLD (no *.pack under $GclientCache) — will fetch WITHOUT --git-cache / GCS mirror"
  return $false
}

function Repair-GclientCacheDirSpec {
  # Belt-and-suspenders: rewrite cache_dir in .gclient to forward slashes if present.
  $gclientFile = Join-Path $ChromiumRoot '.gclient'
  if (-not (Test-Path $gclientFile)) { return }
  if (-not $GclientCache) { return }
  $safe = ConvertTo-PySafeWinPath $GclientCache
  $raw = Get-Content -Raw -Path $gclientFile
  $patched = [regex]::Replace(
    $raw,
    'cache_dir\s*=\s*"[^"]*"',
    ('cache_dir = "{0}"' -f $safe)
  )
  if ($patched -ne $raw) {
    Set-Content -Path $gclientFile -Value $patched -NoNewline
    Write-Info "Rewrote .gclient cache_dir to py-safe path: $safe"
  }
}

function Ensure-DepotTools {
  Write-Info "DEPOT_TOOLS=$DepotTools"
  # Keep UPDATE=0 for day-to-day gclient/fetch to avoid .git/index.lock races
  # (failed run 35921596181). But a fresh clone (or incomplete Actions cache) has no
  # python3_bin_reldir.txt until bootstrap — with UPDATE=0, fetch dies immediately
  # (failed run 35939021520: "python3_bin_reldir.txt not found").
  $env:DEPOT_TOOLS_UPDATE = '0'
  if (-not (Test-Path (Join-Path $DepotTools 'gclient.bat')) -and -not (Test-Path (Join-Path $DepotTools 'gclient'))) {
    Write-Info "Cloning depot_tools..."
    $parent = Split-Path $DepotTools -Parent
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotTools
    if ($LASTEXITCODE -ne 0) { throw "git clone depot_tools failed: $LASTEXITCODE" }
  }
  $lock = Join-Path $DepotTools '.git\index.lock'
  if (Test-Path $lock) {
    Write-Warn "Removing stale depot_tools .git/index.lock"
    Remove-Item -Force $lock -ErrorAction SilentlyContinue
  }
  $env:Path = "$DepotTools;" + $env:Path
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
  $env:GCLIENT_PY3 = '1'
  # Defer GIT_CACHE_PATH until Ensure-ChromiumCheckout decides warm vs cold.
  # Setting it here would make a cold fetch pull gs://chromium-git-cache via gsutil.
  if ($GclientCache) {
    $GclientCache = ConvertTo-PySafeWinPath $GclientCache
    New-Item -ItemType Directory -Force -Path $GclientCache | Out-Null
    Write-Info "GCLIENT_CACHE_DIR=$GclientCache (GIT_CACHE_PATH deferred until warm/cold check)"
  }

  $pyRel = Join-Path $DepotTools 'python3_bin_reldir.txt'
  if (-not (Test-Path $pyRel)) {
    Write-Info "Bootstrapping depot_tools once (python3_bin_reldir.txt missing; UPDATE briefly enabled)..."
    Remove-Item Env:\DEPOT_TOOLS_UPDATE -ErrorAction SilentlyContinue
    $updBat = Join-Path $DepotTools 'update_depot_tools.bat'
    if (Test-Path $updBat) {
      & cmd.exe /c "`"$updBat`""
      $bootExit = $LASTEXITCODE
      Write-Info "update_depot_tools.bat exit=$bootExit"
    } else {
      Write-Warn "update_depot_tools.bat missing; trying gclient --version to trigger bootstrap"
      & gclient --version
      $bootExit = $LASTEXITCODE
    }
    $env:DEPOT_TOOLS_UPDATE = '0'
    $lock2 = Join-Path $DepotTools '.git\index.lock'
    if (Test-Path $lock2) {
      Write-Warn "Removing depot_tools .git/index.lock after bootstrap"
      Remove-Item -Force $lock2 -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $pyRel)) {
      throw "depot_tools bootstrap failed: python3_bin_reldir.txt still missing (bootExit=$bootExit)"
    }
    $pyRelTxt = (Get-Content -Raw $pyRel).Trim()
    Write-Info "depot_tools bootstrap OK: $pyRelTxt"
  } else {
    Write-Info "depot_tools already bootstrapped (python3_bin_reldir.txt present)"
  }

  Write-Info "DEPOT_TOOLS_WIN_TOOLCHAIN=0 DEPOT_TOOLS_UPDATE=0"
  Write-Info "depot_tools ready (gclient on PATH)"
  & gclient --version 2>$null | Select-Object -First 3 | ForEach-Object { Write-Info $_ }
}

function Set-GclientArgsForNonGitCheckout {
  # Tag 151.0.7922.34 tools/metrics/BUILD.gn:
  #   histograms_xml is defined only inside path_exists("//.git")
  #   metrics_metadata depends on it when generate_location_tags is true
  # gclient hooks write generate_location_tags=true while .git still exists.
  # Deleting src\.git before gn gen then fails with unresolved histograms_xml
  # (run 35953615443). Non-git trees must use false (also clears the default
  # tests_have_location_tags = generate_location_tags in testing/test.gni).
  $gni = Join-Path $Src 'build\config\gclient_args.gni'
  if (-not (Test-Path -LiteralPath $gni)) {
    throw "Missing $gni — cannot set generate_location_tags=false for a non-git tree (gn gen would need histograms_xml)."
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $raw = [System.IO.File]::ReadAllText($gni)
  $truePattern = '(?im)^([ \t]*)generate_location_tags[ \t]*=[ \t]*true[ \t]*\r?$'
  $falsePattern = '(?im)^[ \t]*generate_location_tags[ \t]*=[ \t]*false[ \t]*\r?$'
  $patched = [regex]::Replace($raw, $truePattern, '${1}generate_location_tags = false')
  if ($patched -eq $raw) {
    if ([regex]::IsMatch($raw, $falsePattern)) {
      Write-Info "build/config/gclient_args.gni already has generate_location_tags = false"
      return
    }
    throw "build/config/gclient_args.gni has no generate_location_tags assignment. Refusing to gn-gen without src\.git (metrics_metadata -> histograms_xml)."
  }
  [System.IO.File]::WriteAllText($gni, $patched, $utf8NoBom)
  Write-Info "Patched build/config/gclient_args.gni: generate_location_tags = false (non-git checkout)"
}

function Reclaim-AfterSync {
  if ($Aggressive -ne '1') { return }
  Write-Info "Disk reclaim after sync (start)"
  Show-Disk
  Push-Location $Src
  try {
    if (Test-Path '.git') {
      if ($env:DELETE_GIT_AFTER_SYNC -eq '1') {
        # CRITICAL: do NOT run git gc --aggressive first — it can take many hours on
        # a full Chromium tree and burned the remaining wall clock on run 35622650851.
        # Patch gclient_args BEFORE removing .git so gn gen stays consistent.
        Write-Warn "DELETE_GIT_AFTER_SYNC=1 — generate_location_tags=false, then remove src\.git (skip git gc)"
        Set-GclientArgsForNonGitCheckout
        Remove-Item -Recurse -Force '.git'
        Write-Info "src\.git removed"
      } else {
        Write-Info "Running lightweight git prune (no --aggressive)"
        git reflog expire --expire=now --all 2>$null
        git gc --prune=now 2>$null
      }
    }
    @(
      'third_party\llvm-build\Release+Asserts\lib',
      'third_party\rust-toolchain\lib\rustlib\src'
    ) | ForEach-Object {
      if (Test-Path $_) {
        Write-Info "Removing $_"
        Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue
      }
    }
  } finally {
    Pop-Location
  }
  Write-Info "Disk reclaim after sync (done)"
  Show-Disk
}

function Ensure-ChromiumCheckout {
  Write-Info "CHROMIUM_ROOT=$ChromiumRoot tag=$ChromeTag (Playwright $PlaywrightVersion / rev $PlaywrightRevision)"
  New-Item -ItemType Directory -Force -Path $ChromiumRoot | Out-Null
  Show-Disk

  # fetch: --git-cache is boolean; path from GIT_CACHE_PATH. Do NOT pass --cache-dir
  # to fetch.py (35678800862) or gclient sync (35841948132). Forward-slash paths
  # avoid BEL from C:\a\_temp (35828856871).
  #
  # CRITICAL (35940687183): COLD --git-cache populates from gs://chromium-git-cache
  # via gsutil at ~1-2 KiB/s on GitHub-hosted Windows ARM and burns the 6h budget.
  # Only enable git-cache when Actions restore already left *.pack (warm).
  # Cold path: plain `fetch --nohooks chromium` from googlesource (no GCS mirror).
  $syncArgs = @('sync', '--with_branch_heads', '--with_tags')
  $cacheWarm = Test-GclientCacheWarm
  if ($cacheWarm) {
    $GclientCache = ConvertTo-PySafeWinPath $GclientCache
    $env:GIT_CACHE_PATH = $GclientCache
    $fetchArgs = @('--nohooks', '--git-cache', 'chromium')
    Write-Info "Using WARM git-cache: GIT_CACHE_PATH=$GclientCache"
  } else {
    Remove-Item Env:\GIT_CACHE_PATH -ErrorAction SilentlyContinue
    # Avoid writing cache_dir into .gclient on cold path (would re-trigger GCS populate).
    $script:GclientCache = $null
    $GclientCache = $null
    $fetchArgs = @('--nohooks', 'chromium')
    Write-Info 'Using COLD fetch (no --git-cache, no GIT_CACHE_PATH)'
  }

  if ($env:SKIP_FETCH -eq '1' -and (Test-Path $Src)) {
    Write-Warn "SKIP_FETCH=1 — using existing checkout"
  } elseif (-not (Test-Path (Join-Path $Src '.git')) -and -not (Test-Path (Join-Path $Src 'BUILD.gn'))) {
    Push-Location $ChromiumRoot
    try {
      Write-Info ("fetch {0} (long)..." -f ($fetchArgs -join ' '))
      & fetch @fetchArgs
      if ($LASTEXITCODE -ne 0) { throw "fetch chromium failed: $LASTEXITCODE" }
    } finally {
      Pop-Location
    }
  } elseif (-not (Test-Path (Join-Path $Src '.git')) -and (Test-Path (Join-Path $Src 'BUILD.gn'))) {
    Write-Warn "src exists without .git (prior DELETE_GIT_AFTER_SYNC); re-fetch required unless SKIP_FETCH=1"
    if ($env:SKIP_FETCH -eq '1') {
      Write-Warn "SKIP_FETCH=1 with no .git — continuing with working tree only"
    } else {
      Push-Location $ChromiumRoot
      try {
        if (Test-Path $Src) {
          Write-Info "Removing incomplete src for clean fetch"
          Remove-Item -Recurse -Force $Src
        }
        Write-Info ("fetch {0} (long)..." -f ($fetchArgs -join ' '))
        & fetch @fetchArgs
        if ($LASTEXITCODE -ne 0) { throw "fetch chromium failed: $LASTEXITCODE" }
      } finally {
        Pop-Location
      }
    }
  } else {
    Write-Info "Chromium src already present"
  }

  if ($env:SKIP_FETCH -eq '1') {
    Reclaim-AfterSync
    return
  }

  Repair-GclientCacheDirSpec

  Push-Location $Src
  try {
    if (Test-Path '.git') {
      $current = (git describe --tags --exact-match 2>$null)
      if ($current -ne $ChromeTag) {
        Write-Info "Checking out tag $ChromeTag"
        git fetch origin tag $ChromeTag 2>$null
        if ($LASTEXITCODE -ne 0) {
          git fetch https://chromium.googlesource.com/chromium/src.git "+refs/tags/${ChromeTag}:refs/tags/${ChromeTag}"
          if ($LASTEXITCODE -ne 0) { throw "git fetch tag $ChromeTag failed" }
        }
        git checkout $ChromeTag
        if ($LASTEXITCODE -ne 0) { throw "git checkout $ChromeTag failed" }
      } else {
        Write-Info "Already on $ChromeTag"
      }
    } else {
      Write-Warn "No .git — skipping tag checkout; assuming working tree matches $ChromeTag"
    }

    Write-Info ("gclient {0}" -f ($syncArgs -join ' '))
    & gclient @syncArgs
    if ($LASTEXITCODE -ne 0) { throw "gclient sync failed: $LASTEXITCODE" }
    Write-Info "gclient sync finished"
  } finally {
    Pop-Location
  }
  Reclaim-AfterSync
}

function Invoke-ChromiumBuild {
  Push-Location $Src
  try {
    # Safety net if .git was removed (DELETE_GIT_AFTER_SYNC, or a resumed tree)
    # and gclient_args.gni is still the post-hook true value. Also covers a
    # later `gn gen` from autoninja: the patched file stays false.
    if (-not (Test-Path -LiteralPath '.git')) {
      Write-Info "src\.git absent — ensuring generate_location_tags=false before gn gen"
      Set-GclientArgsForNonGitCheckout
    }

    # Do NOT pass --args=... via PowerShell Call operator: it strips the quotes
    # around target_cpu="arm64", so gn sees bare arm64 (Undefined identifier).
    # Failed run 35866577988 after ~3h sync. Write out/Default/args.gn instead
    # (matches docs/BUILD.md intent; immune to PS quoting).
    $outDir = 'out\Default'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $argsGnLines = @(
      'is_debug = false',
      'is_official_build = true',
      'is_component_build = false',
      'symbol_level = 0',
      'blink_symbol_level = 0',
      'enable_nacl = false',
      'target_cpu = "arm64"',
      # Hosted CI has no Chrome PGO profiles; official builds need this or link fails later.
      'chrome_pgo_phase = 0'
    )
    $argsFile = Join-Path $outDir 'args.gn'
    Set-Content -Path $argsFile -Value ($argsGnLines -join "`n") -Encoding ascii
    Write-Info "Wrote $argsFile for gn gen:"
    Get-Content $argsFile | ForEach-Object { Write-Info ("  {0}" -f $_) }
    Show-Disk
    & gn gen $outDir
    if ($LASTEXITCODE -ne 0) { throw "gn gen failed: $LASTEXITCODE" }
    Write-Info "gn gen finished"

    Write-Info "autoninja -C out\Default chrome (long; heartbeat every 10m)"
    $heartbeat = Start-Job -ScriptBlock {
      while ($true) {
        Start-Sleep -Seconds 600
        Write-Output ("[HEARTBEAT] {0} autoninja still running" -f (Get-Date -Format 'o'))
      }
    }
    try {
      & autoninja -C out\Default chrome
      $ninjaExit = $LASTEXITCODE
    } finally {
      Stop-Job $heartbeat -ErrorAction SilentlyContinue
      Receive-Job $heartbeat -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
      Remove-Job $heartbeat -Force -ErrorAction SilentlyContinue
    }
    if ($ninjaExit -ne 0) { throw "autoninja failed: $ninjaExit" }
    Write-Info "autoninja finished"

    if ($Aggressive -eq '1') {
      Write-Info "Post-link cleanup: obj/gen/pdb under out\Default"
      @(
        'out\Default\obj',
        'out\Default\gen',
        'out\Default\thinlto-cache'
      ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue }
      }
      Get-ChildItem -Path 'out\Default' -Filter '*.pdb' -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
      Show-Disk
    }

    $exe = Join-Path $Src 'out\Default\chrome.exe'
    if (-not (Test-Path $exe)) { throw "Missing $exe" }
    & $exe --version | Out-Host

    $bytes = [System.IO.File]::ReadAllBytes($exe)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $hex = ('{0:X}' -f $machine)
    Write-Info "PE Machine=$hex"
    if ($machine -ne 0xAA64) {
      throw "chrome.exe PE Machine=$hex (want AA64). Do not pack x64 builds."
    }
    Write-Info "Build OK: $exe"
  } finally {
    Pop-Location
  }
}

Assert-Arm64Host
Ensure-DepotTools
Ensure-ChromiumCheckout
if ($env:SKIP_BUILD -eq '1') {
  Write-Warn 'SKIP_BUILD=1 — skipping gn/autoninja'
  exit 0
}
Invoke-ChromiumBuild