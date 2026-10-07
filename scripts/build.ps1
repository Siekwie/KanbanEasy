<#
.SYNOPSIS
  Build (and optionally install) KanbanEasy on Windows.

.DESCRIPTION
  windows  (default) dist\KanbanEasy.exe: one self-contained file, no DLLs
  love     dist\KanbanEasy.love (run it with an installed LOVE 11.5)
  install  build, copy to %LOCALAPPDATA%\Programs\KanbanEasy and add a Start Menu shortcut
  run      run from source with an installed LOVE (love.exe on PATH or in Program Files)
  runtime  build the Windows runtime from source instead of downloading it (scripts\runtime)
  clean    remove dist\ and .build-cache\

  macOS / Linux packages: use scripts/build.sh (or push a v* tag and let CI build them).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build.ps1
  powershell -ExecutionPolicy Bypass -File scripts\build.ps1 install
#>
param(
  [ValidateSet('windows', 'love', 'install', 'run', 'runtime', 'clean')]
  [string]$Target = 'windows'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is painfully slow with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$App = 'KanbanEasy'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dist = Join-Path $Root 'dist'
$Cache = Join-Path $Root '.build-cache'
$GameFiles = @('main.lua', 'conf.lua', 'src', 'assets')
$RuntimeVersion = (Get-Content (Join-Path $PSScriptRoot 'runtime\version.txt') -TotalCount 1).Trim()
$RuntimeUrl = "https://github.com/Siekwie/KanbanEasy/releases/download/runtime-$RuntimeVersion"

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# Zip entries must use forward slashes or LOVE can't read them
# (Compress-Archive in Windows PowerShell 5.1 writes backslashes).
function New-Zip([string]$Destination, [string]$BaseDir, [string[]]$Items) {
  if (Test-Path $Destination) { Remove-Item $Destination -Force }
  $zip = [IO.Compression.ZipFile]::Open($Destination, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($item in $Items) {
      $full = Join-Path $BaseDir $item
      if (Test-Path $full -PathType Container) {
        $files = Get-ChildItem $full -Recurse -File | Where-Object { $_.Name -ne '.DS_Store' }
      } else {
        $files = @(Get-Item $full)
      }
      foreach ($f in $files) {
        $rel = $f.FullName.Substring($BaseDir.Length).TrimStart('\', '/') -replace '\\', '/'
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
          $zip, $f.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal)
      }
    }
  } finally {
    $zip.Dispose()
  }
}

# The runtime is LOVE built as one statically linked exe with our icon (see scripts\runtime).
# CI publishes it as a release. One you built yourself is already in the cache and wins.
function Get-RuntimeFile([string]$Name) {
  $path = Join-Path $Cache "runtime-$RuntimeVersion\$Name"
  if (-not (Test-Path $path)) {
    Step "Downloading $Name (runtime $RuntimeVersion)"
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    Invoke-WebRequest -Uri "$RuntimeUrl/$Name" -OutFile "$path.part" -UseBasicParsing
    Move-Item "$path.part" $path -Force
  }
  return $path
}

function Build-Love {
  New-Item -ItemType Directory -Force $Dist | Out-Null
  $out = Join-Path $Dist "$App.love"
  New-Zip -Destination $out -BaseDir $Root -Items $GameFiles
  Step "Built dist\$App.love"
  return $out
}

function Build-Windows {
  $lovePath = Build-Love
  $runtime = Get-RuntimeFile "$App-runtime-win64.exe"

  # A fused game is just the runtime with the .love archive appended.
  $exe = Join-Path $Dist "$App.exe"
  $stream = [IO.File]::Create($exe)
  try {
    foreach ($part in @($runtime, $lovePath)) {
      $bytes = [IO.File]::ReadAllBytes($part)
      $stream.Write($bytes, 0, $bytes.Length)
    }
  } finally {
    $stream.Dispose()
  }
  Copy-Item (Get-RuntimeFile 'LOVE-license.txt') $Dist -Force
  Step "Built dist\$App.exe"
  return $exe
}

function Install-App {
  $built = Build-Windows
  $dest = Join-Path $env:LOCALAPPDATA "Programs\$App"
  $running = Get-Process -Name $App -ErrorAction SilentlyContinue
  if ($running) {
    Step 'Closing the running KanbanEasy (your board is saved)'
    $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 2
    Get-Process -Name $App -ErrorAction SilentlyContinue | Stop-Process -Force
  }
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Force $dest | Out-Null
  $exe = Join-Path $dest "$App.exe"
  Copy-Item $built $exe

  $programs = [Environment]::GetFolderPath('Programs')
  $lnk = Join-Path $programs "$App.lnk"
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($lnk)
  $shortcut.TargetPath = $exe
  $shortcut.WorkingDirectory = $dest
  $shortcut.IconLocation = "$exe,0"
  $shortcut.Description = 'Kanban board for agentic work'
  $shortcut.Save()
  Step "Installed to $dest"
  Step "Start Menu shortcut: $lnk"
}

function Find-Love {
  $cmd = Get-Command love -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($dir in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($dir) {
      $candidate = Join-Path $dir 'LOVE\love.exe'
      if (Test-Path $candidate) { return $candidate }
    }
  }
  throw 'LOVE not found. Install LOVE 11.5 from https://love2d.org or use: scripts\build.ps1 windows'
}

switch ($Target) {
  'love' { Build-Love | Out-Null }
  'windows' { Build-Windows | Out-Null }
  'install' { Install-App }
  'run' { & (Find-Love) $Root }
  'runtime' { & (Join-Path $PSScriptRoot 'runtime\build-runtime.ps1') }
  'clean' {
    foreach ($dir in @($Dist, $Cache)) {
      if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    }
    Step 'Cleaned'
  }
}
