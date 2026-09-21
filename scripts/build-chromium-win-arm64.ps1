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
    SKIP_FETCH    - "1" to skip fetch/sync when checkout exists
    SKIP_BUILD    - "1" to skip gn/autoninja
    AGGRESSIVE_DISK - "1" (default on CI) reclaim disk after sync / mid-build

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
$Aggressive = if ($null -ne $env:AGGRESSIVE_DISK -and $env:AGGRESSIVE_DISK -ne '') { $env:AGGRESSIVE_DISK } else { if ($env:GITHUB_ACTIONS) { '1' } else { '0' } }

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" }
function Write-Warn([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

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

function Ensure-DepotTools {
  Write-Info "DEPOT_TOOLS=$DepotTools"
  if (-not (Test-Path (Join-Path $DepotTools 'gclient.bat')) -and -not (Test-Path (Join-Path $DepotTools 'gclient'))) {
    Write-Info "Cloning depot_tools..."
    $parent = Split-Path $DepotTools -Parent
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotTools
  }
  $env:Path = "$DepotTools;" + $env:Path
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
  # Prefer local VS; shrink downloads
  $env:GCLIENT_PY3 = '1'
  Write-Info "DEPOT_TOOLS_WIN_TOOLCHAIN=0"
  & gclient --version 2>$null | Out-Host
}

function Reclaim-AfterSync {
  if ($Aggressive -ne '1') { return }
  Write-Info "Aggressive disk reclaim after sync"
  Push-Location $Src
  try {
    # Drop git object packing weight; keep working tree
    if (Test-Path '.git') {
      git reflog expire --expire=now --all 2>$null
      git gc --prune=now --aggressive 2>$null
      # Last resort on tiny runners: remove .git (cannot re-sync easily)
      if ($env:DELETE_GIT_AFTER_SYNC -eq '1') {
        Write-Warn "DELETE_GIT_AFTER_SYNC=1 — removing src\.git"
        Remove-Item -Recurse -Force '.git'
      }
    }
    # Common bulky caches not needed to link chrome
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
  Show-Disk
}

function Ensure-ChromiumCheckout {
  Write-Info "CHROMIUM_ROOT=$ChromiumRoot tag=$ChromeTag (Playwright $PlaywrightVersion / rev $PlaywrightRevision)"
  New-Item -ItemType Directory -Force -Path $ChromiumRoot | Out-Null
  Show-Disk

  if ($env:SKIP_FETCH -eq '1' -and (Test-Path $Src)) {
    Write-Warn "SKIP_FETCH=1 — using existing checkout"
  } elseif (-not (Test-Path (Join-Path $Src '.git'))) {
    Push-Location $ChromiumRoot
    try {
      Write-Info "fetch --nohooks chromium (long)..."
      & fetch --nohooks chromium
      if ($LASTEXITCODE -ne 0) { throw "fetch chromium failed: $LASTEXITCODE" }
    } finally {
      Pop-Location
    }
  } else {
    Write-Info "Chromium src already present"
  }

  Push-Location $Src
  try {
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
    if ($env:SKIP_FETCH -ne '1') {
      Write-Info "gclient sync --with_branch_heads --with_tags"
      & gclient sync --with_branch_heads --with_tags
      if ($LASTEXITCODE -ne 0) { throw "gclient sync failed: $LASTEXITCODE" }
    }
  } finally {
    Pop-Location
  }
  Reclaim-AfterSync
}

function Invoke-ChromiumBuild {
  Push-Location $Src
  try {
    # Disk-tight official-ish args: no symbols/pdb, arm64 native
    $argsGn = @(
      'is_debug=false',
      'is_official_build=true',
      'is_component_build=false',
      'symbol_level=0',
      'blink_symbol_level=0',
      'enable_nacl=false',
      'target_cpu="arm64"'
    ) -join ' '
    Write-Info "gn gen out\Default --args=$argsGn"
    & gn gen out\Default --args=$argsGn
    if ($LASTEXITCODE -ne 0) { throw "gn gen failed: $LASTEXITCODE" }

    Write-Info "autoninja -C out\Default chrome"
    & autoninja -C out\Default chrome
    if ($LASTEXITCODE -ne 0) { throw "autoninja failed: $LASTEXITCODE" }

    if ($Aggressive -eq '1') {
      Write-Info "Mid-build cleanup: obj/gen/pdb under out\Default"
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
