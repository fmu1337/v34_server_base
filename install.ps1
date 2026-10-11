<#
.SYNOPSIS
  CS:S v34 base installer (Windows).

.DESCRIPTION
  Same options as install.sh where they apply on Windows:
  the bufferfix / steamclient patches are Linux-only (glibc memcpy and
  steamclient_i486.so), healthfix works on both.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Dir C:\css34
  powershell -ExecutionPolicy Bypass -File install.ps1 -Dir C:\css34 -SM rom4s -Patch none
#>
[CmdletBinding()]
param(
  [string]$Dir = (Join-Path (Get-Location) 'css34'),
  [string]$Cache = '',
  [ValidateSet('auto', 'mirror', 'rom4s', 'skip')][string]$ServerSource = 'auto',
  [ValidateSet('', 'ours', 'rom4s', 'myarena', 'none')][string]$SM = '',
  [string]$SMLine = '',
  [string]$Patch = 'healthfix',
  [ValidateSet('auto', 'stock', 'debian9', 'minimal')][string]$ValveRc = 'auto',
  [string]$Plugins = 'smac',
  [ValidateSet('auto', 'compile', 'prebuilt')][string]$SmacMode = 'auto',
  [int]$Port = 27015,
  [string]$Hostname = 'CS:S v34 server',
  [string]$Rcon = '',
  [switch]$Smoke,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = $PSScriptRoot
$Manifest = Get-Content (Join-Path $Root 'manifest/sources.json') -Raw | ConvertFrom-Json

function Log($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Warning $m }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Split-List($v) {
  if ($v -eq 'none' -or [string]::IsNullOrEmpty($v)) { return @() }
  if ($v -eq 'all') { return @('steamclient', 'bufferfix', 'healthfix') }
  return $v.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Test-Sha($file, $sha) {
  if (-not $sha) { return $true }
  $got = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $sha.ToLower()) { Warn "sha256 mismatch for $(Split-Path $file -Leaf): $got"; return $false }
  return $true
}

function Get-File($out, $sha, [string[]]$urls) {
  if ((Test-Path $out) -and (Get-Item $out).Length -gt 0 -and (Test-Sha $out $sha)) {
    Write-Host "    cached $(Split-Path $out -Leaf)"; return
  }
  foreach ($u in $urls) {
    Write-Host "    $(Split-Path $out -Leaf) <- $u"
    $headers = @{}
    if ($env:GITHUB_TOKEN -and $u.StartsWith('https://github.com/')) { $headers.Authorization = "token $($env:GITHUB_TOKEN)" }
    try {
      Invoke-WebRequest -Uri $u -OutFile "$out.part" -UseBasicParsing -Headers $headers
      if (Test-Sha "$out.part" $sha) { Move-Item -Force "$out.part" $out; return }
    } catch { Warn "failed: $u ($($_.Exception.Message))" }
    Remove-Item -Force "$out.part" -ErrorAction SilentlyContinue
  }
  Die "could not download $(Split-Path $out -Leaf)"
}

function Expand-Any($archive, $dest) {
  New-Item -ItemType Directory -Force $dest | Out-Null
  if ($archive -match '\.zip$') {
    # Expand-Archive chokes on '\' separators in some community zips; use .NET directly.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
      foreach ($e in $zip.Entries) {
        $rel = $e.FullName -replace '\\', '/'
        $target = Join-Path $dest $rel
        if ($rel.EndsWith('/')) { New-Item -ItemType Directory -Force $target | Out-Null; continue }
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
      }
    } finally { $zip.Dispose() }
  } else {
    tar -xzf $archive -C $dest
    if ($LASTEXITCODE) { Die "tar failed on $archive" }
  }
}

# ---- options ------------------------------------------------------------------
if (-not $SM) { $SM = $Manifest.sourcemod.default }
if (-not $SMLine) { $SMLine = $Manifest.sourcemod.ours.default_line }
if ($SM -ne 'ours') { $SMLine = '' }
$PatchList = Split-List $Patch
$PluginList = Split-List $Plugins
foreach ($p in $PatchList) {
  if ($p -in 'bufferfix', 'steamclient') { Warn "$p is a Linux-only patch; skipped on Windows" }
  elseif ($p -ne 'healthfix') { Die "unknown patch: $p" }
}
foreach ($p in $PluginList) { if ($p -ne 'smac') { Die "unknown plugin: $p" } }

New-Item -ItemType Directory -Force $Dir | Out-Null
$Dir = (Resolve-Path $Dir).Path
if (-not $Cache) { $Cache = Join-Path $Dir '.cache' }
New-Item -ItemType Directory -Force $Cache | Out-Null
$CS = Join-Path $Dir 'cstrike'

Log "Install to $Dir"
Write-Host "    server=$ServerSource sm=$SM$(if ($SMLine) { "/$SMLine" }) patches=$($PatchList -join ',') valve.rc=$ValveRc plugins=$($PluginList -join ',')"

# ---- server -------------------------------------------------------------------
if ($ServerSource -eq 'skip') {
  if (-not (Test-Path (Join-Path $Dir 'srcds.exe'))) { Die "-ServerSource skip: no server in $Dir" }
} else {
  $existing = Get-ChildItem $Dir -Force | Where-Object { $_.Name -ne '.cache' }
  if ($existing) {
    if (-not $Force) { Die "$Dir is not empty (use -Force to wipe it, or -ServerSource skip)" }
    Log "Wiping $Dir"; $existing | Remove-Item -Recurse -Force
  }
  Log "Server files ($ServerSource)"
  foreach ($f in $Manifest.server.windows) {
    $urls = switch ($ServerSource) {
      'mirror' { @("$($Manifest.server.mirror_release)/$($f.name)") }
      'rom4s' { @("$($Manifest.server.rom4s)/$($f.name)") }
      default { @("$($Manifest.server.mirror_release)/$($f.name)", "$($Manifest.server.rom4s)/$($f.name)") }
    }
    $out = Join-Path $Cache $f.name
    Get-File $out $f.sha256 $urls
    Expand-Any $out $Dir
  }
  if (-not (Test-Path (Join-Path $Dir 'srcds.exe'))) { Die 'server tree looks incomplete (no srcds.exe)' }
}

# ---- valve.rc -----------------------------------------------------------------
$mode = if ($ValveRc -eq 'auto') { 'minimal' } else { $ValveRc }
if ($mode -ne 'stock') {
  Log "valve.rc: $mode"
  $rc = Join-Path $CS 'cfg/valve.rc'
  if ((Test-Path $rc) -and -not (Test-Path "$rc.orig")) { Copy-Item $rc "$rc.orig" }
  Copy-Item -Force (Join-Path $Root "configs/valve-$mode.rc") $rc
}

# ---- Metamod + SourceMod ------------------------------------------------------
$SMDir = Join-Path $CS 'addons/sourcemod'
if ($SM -ne 'none') {
  Log "Metamod + SourceMod: $SM$(if ($SMLine) { " ($SMLine)" })"
  Remove-Item -Recurse -Force (Join-Path $CS 'addons/metamod'), (Join-Path $CS 'addons/metamod.vdf'), $SMDir -ErrorAction SilentlyContinue
  switch ($SM) {
    'ours' {
      $line = $Manifest.sourcemod.ours.lines.$SMLine
      if (-not $line) { Die "unknown -SMLine $SMLine" }
      if ($line.linux_only) { Die "$SMLine has no working Windows build; pick another -SMLine" }
      $base = "$($Manifest.sourcemod.ours.release)/$($line.tag)"
      $mm = "$base/$($line.mm)-windows.zip"; $smUrl = "$base/$($line.sm)-windows.zip"
    }
    'rom4s' { $mm = $Manifest.sourcemod.rom4s.windows.mm; $smUrl = $Manifest.sourcemod.rom4s.windows.sm }
    'myarena' { Die 'the myarena bundle is Linux-only; use -SM ours or -SM rom4s' }
  }
  foreach ($u in $mm, $smUrl) {
    $out = Join-Path $Cache "$SM-$(Split-Path $u -Leaf)"
    Get-File $out $null @($u)
    Expand-Any $out $CS
  }
  if (-not (Test-Path (Join-Path $CS 'addons/metamod.vdf'))) { Die 'metamod.vdf missing after install' }
  $vdf = Join-Path $CS 'addons/metamod/sourcemod.vdf'
  if (-not (Test-Path $vdf)) {
    New-Item -ItemType Directory -Force (Split-Path $vdf) | Out-Null
    Set-Content -Encoding ASCII $vdf "`"Metamod Plugin`"`r`n{`r`n`t`"alias`"`t`t`"sourcemod`"`r`n`t`"file`"`t`t`"addons/sourcemod/bin/sourcemod_mm`"`r`n}"
  }
  $core = Join-Path $SMDir 'configs/core.cfg'
  if (Test-Path $core) { (Get-Content $core) -replace '"AutoUpdate"\s*"yes"', "`"AutoUpdate`"`t`t`"no`"" | Set-Content $core }

  $geo = Join-Path $SMDir 'configs/geoip'
  if ((Test-Path (Join-Path $SMDir 'extensions/geoip.ext.dll')) -and -not (Test-Path (Join-Path $geo 'GeoIP.dat')) -and
      -not (Get-ChildItem $geo -Filter *.mmdb -ErrorAction SilentlyContinue)) {
    New-Item -ItemType Directory -Force $geo | Out-Null
    $db = Join-Path $Cache 'GeoLite2-Country.mmdb'
    Get-File $db $null @($Manifest.geoip2)
    Copy-Item $db $geo
  }
}

# ---- healthfix ----------------------------------------------------------------
if ('healthfix' -in $PatchList) {
  if (Test-Path $SMDir) {
    Log 'HealthLimitFix'
    Copy-Item -Force (Join-Path $Root 'patches/healthfix/plugins/HealthLimitFix.smx') (Join-Path $SMDir 'plugins')
    Copy-Item -Force (Join-Path $Root 'patches/healthfix/gamedata/health-patch.txt') (Join-Path $SMDir 'gamedata')
    New-Item -ItemType Directory -Force (Join-Path $SMDir 'scripting') | Out-Null
    Copy-Item -Force (Join-Path $Root 'patches/healthfix/scripting/HealthLimitFix.sp') (Join-Path $SMDir 'scripting')
  } else { Warn 'healthfix needs SourceMod; skipped' }
}

# ---- SMAC ---------------------------------------------------------------------
if ('smac' -in $PluginList) {
  if (Test-Path $SMDir) {
    Log "SMAC ($SmacMode)"
    $zip = Join-Path $Cache 'smac_v34.zip'
    Get-File $zip $null @($Manifest.plugins.smac.zip)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("smac-" + [guid]::NewGuid())
    Expand-Any $zip $tmp
    $src = Join-Path $tmp $Manifest.plugins.smac.dir
    $compiled = $false
    $spcomp = Join-Path $SMDir 'scripting/spcomp.exe'
    if ($SmacMode -ne 'prebuilt' -and (Test-Path $spcomp)) {
      $scripting = Join-Path $src 'addons/sourcemod/scripting'
      $outDir = Join-Path $tmp 'out'
      New-Item -ItemType Directory -Force (Join-Path $outDir 'disabled') | Out-Null
      $failed = 0
      # Plugin list from smac_v34/scripts/compile-all.sh (OPTIONAL_PLUGINS go to plugins/disabled).
      $script = Get-Content (Join-Path $src 'scripts/compile-all.sh') -Raw
      $section = { param($name) ([regex]::Match($script, "(?s)$name=\((.*?)\)").Groups[1].Value -split '\s+') | Where-Object { $_ -like '*.sp' } }
      $optional = & $section 'OPTIONAL_PLUGINS'
      foreach ($sp in @(& $section 'PLUGINS') + @($optional)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($sp)
        $out = if ($sp -in $optional) { Join-Path $outDir "disabled/$name.smx" } else { Join-Path $outDir "$name.smx" }
        & $spcomp "-i$(Join-Path $scripting 'include')" "-i$(Join-Path $SMDir 'scripting/include')" "-o$out" (Join-Path $scripting $sp) | Out-Null
        if ($LASTEXITCODE) { $failed++ }
      }
      if ($failed -eq 0) {
        Copy-Item -Recurse -Force (Join-Path $outDir '*') (Join-Path $src 'addons/sourcemod/plugins')
        $compiled = $true
      } elseif ($SmacMode -eq 'compile') { Die "SMAC: $failed plugin(s) failed to compile" }
      else { Warn "SMAC: $failed plugin(s) failed to compile, using prebuilt .smx" }
    }
    Copy-Item -Recurse -Force (Join-Path $src 'addons/sourcemod/*') $SMDir
    Copy-Item -Recurse -Force (Join-Path $src 'cfg/*') (Join-Path $CS 'cfg')
    if (Test-Path (Join-Path $src 'materials')) { Copy-Item -Recurse -Force (Join-Path $src 'materials') $CS }
    Remove-Item -Recurse -Force $tmp
    Write-Host "    $((Get-ChildItem (Join-Path $SMDir 'plugins') -Filter 'smac*.smx').Count) SMAC plugins (compiled=$compiled)"
  } else { Warn 'SMAC needs SourceMod; skipped' }
}

# ---- configs ------------------------------------------------------------------
$cfg = Join-Path $CS 'cfg/server.cfg'
if (-not (Test-Path $cfg) -or -not (Test-Path (Join-Path $Dir '.installer'))) {
  Log 'server.cfg'
  if ((Test-Path $cfg) -and -not (Test-Path "$cfg.orig")) { Copy-Item $cfg "$cfg.orig" }
  $lines = @("hostname `"$Hostname`"")
  if ($Rcon) { $lines += "rcon_password `"$Rcon`"" }
  $lines += 'sv_lan 0', 'sv_cheats 0', 'sv_pure 0', 'mp_dynamicpricing 0'
  if ('healthfix' -in $PatchList) { $lines += 'sv_sendtables 1 // HealthLimitFix' }
  $lines += 'exec banned_user.cfg', 'exec banned_ip.cfg', 'writeid', 'writeip'
  Set-Content -Encoding ASCII $cfg $lines
}

Set-Content -Encoding ASCII (Join-Path $Dir 'start-server.bat') @"
@echo off
rem Generated by v34_server_base install.ps1
cd /d "%~dp0"
if "%PORT%"=="" set PORT=$Port
if "%MAXPLAYERS%"=="" set MAXPLAYERS=32
if "%MAP%"=="" set MAP=de_dust2
start "" srcds.exe -console -game cstrike -port %PORT% -tickrate 66 -maxplayers %MAXPLAYERS% -insecure -nomaster -localcser +map %MAP% %*
"@

Set-Content -Encoding ASCII (Join-Path $Dir '.installer') @(
  "date=$((Get-Date).ToUniversalTime().ToString('s'))Z",
  "server_source=$ServerSource", "sm=$SM", "sm_line=$SMLine",
  "patches=$($PatchList -join ',')", "valve_rc=$ValveRc", "plugins=$($PluginList -join ',')"
)

Log "Done: $Dir"
Write-Host "    start: $(Join-Path $Dir 'start-server.bat')   (PORT, MAXPLAYERS, MAP env vars)"

if ($Smoke) {
  Log 'Smoke test'
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
  if (-not $py) { Die 'smoke test needs python' }
  $smokeArgs = @((Join-Path $Root 'lib/smoke.py'), $Dir, '--sm', $SM)
  if ('smac' -in $PluginList) { $smokeArgs += '--expect-plugin', 'smac' }
  if ('healthfix' -in $PatchList) { $smokeArgs += '--expect-plugin', 'HealthLimitFix' }
  & $py.Source -I @smokeArgs
  exit $LASTEXITCODE
}
