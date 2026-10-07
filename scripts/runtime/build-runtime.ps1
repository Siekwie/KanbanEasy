<#
.SYNOPSIS
  Build the Windows runtime for KanbanEasy: LOVE with every library linked in, so the app is one .exe.

.DESCRIPTION
  The official LOVE download is love.exe plus seven DLLs, and love.exe carries the LOVE icon. This
  builds LOVE from source instead (https://github.com/love2d/megasource) as a single statically
  linked executable with the icon and version info from app.rc:

    .build-cache\runtime-<version>\KanbanEasy-runtime-win64.exe
    .build-cache\runtime-<version>\LOVE-license.txt

  scripts\build.ps1 appends the game to that exe. You rarely need to run this yourself: CI builds the
  runtime and publishes it as the release "runtime-<version>", and the build scripts download it from
  there. Run it when you change LOVE's version, the patches or the icon, and bump version.txt.

  Needs Visual Studio with the C++ workload, CMake and git. The first build takes about ten minutes.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\runtime\build-runtime.ps1
#>
param(
  # Resource script with the icon and version info to compile in.
  [string]$Rc = (Join-Path $PSScriptRoot 'app.rc'),
  # Where to put the finished executable (default: the build cache, where build.ps1 looks for it).
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

# LOVE and its dependencies, pinned to the commits behind the 11.5 tags.
$LoveTag = '11.5'
$Megasource = @{ Url = 'https://github.com/love2d/megasource'; Commit = '48811d08a8edecea05c117022a38a91dd10f46f6' }
$Love = @{ Url = 'https://github.com/love2d/love'; Commit = '6eb8d546736d5915a8b5af30b2cf33456dfdcb1a' }

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Version = (Get-Content (Join-Path $PSScriptRoot 'version.txt') -TotalCount 1).Trim()
$Work = Join-Path $Root '.build-cache\runtime'
$Source = Join-Path $Work 'megasource'
$LoveSource = Join-Path $Source 'libs\love'
$Build = Join-Path $Work 'build'
$OutDir = Join-Path $Root ".build-cache\runtime-$Version"
if (-not $Out) { $Out = Join-Path $OutDir 'KanbanEasy-runtime-win64.exe' }

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Run([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# Check out one pinned commit and put our patch on top of it.
function Get-Source([string]$Dir, [hashtable]$Repo, [string]$Patch) {
  if (-not (Test-Path (Join-Path $Dir '.git'))) {
    Step "Cloning $($Repo.Url)"
    Run git @('clone', '--quiet', '--depth', '1', '--branch', $LoveTag, '-c', 'advice.detachedHead=false', $Repo.Url, $Dir)
  }
  $head = (& git -C $Dir rev-parse HEAD).Trim()
  if ($head -ne $Repo.Commit) { throw "$Dir is at $head, expected $($Repo.Commit)" }
  Run git @('-C', $Dir, 'checkout', '--quiet', '--', '.')
  Run git @('-C', $Dir, 'apply', '--whitespace=nowarn', (Join-Path $PSScriptRoot $Patch))
}

# The DLL names in an executable's import table.
function Get-Imports([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
  $optional = $pe + 24
  if ([BitConverter]::ToUInt16($bytes, $optional) -ne 0x20B) { throw "$Path is not a 64-bit executable" }
  $sections = $optional + [BitConverter]::ToUInt16($bytes, $pe + 20)
  $toOffset = {
    param([uint32]$rva)
    for ($i = 0; $i -lt $sectionCount; $i++) {
      $s = $sections + 40 * $i
      $start = [BitConverter]::ToUInt32($bytes, $s + 12)
      if ($rva -ge $start -and $rva -lt $start + [BitConverter]::ToUInt32($bytes, $s + 8)) {
        return [int]($rva - $start + [BitConverter]::ToUInt32($bytes, $s + 20))
      }
    }
    throw "bad address in $Path"
  }
  $names = @()
  # Data directory 1 is the import table: 20-byte entries, the DLL name's address at +12.
  $entry = & $toOffset ([BitConverter]::ToUInt32($bytes, $optional + 112 + 8))
  while ($true) {
    $nameRva = [BitConverter]::ToUInt32($bytes, $entry + 12)
    if ($nameRva -eq 0) { break }
    $start = & $toOffset $nameRva
    $end = [Array]::IndexOf($bytes, [byte]0, $start)
    $names += [Text.Encoding]::ASCII.GetString($bytes, $start, $end - $start)
    $entry += 20
  }
  return $names
}

foreach ($tool in 'git', 'cmake') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH" }
}

New-Item -ItemType Directory -Force $Work | Out-Null
Get-Source $Source $Megasource 'megasource.patch'
Get-Source $LoveSource $Love 'love.patch'

# Some of the bundled libraries still ask for CMake 2.8, which CMake 4 refuses without this. It is
# an environment variable so the nested CMake run inside OpenAL Soft's build sees it too.
$env:CMAKE_POLICY_VERSION_MINIMUM = '3.5'

# /MT links the C runtime statically. AL_LIBTYPE_STATIC makes LOVE use OpenAL as a static library.
$flags = '/MT /O2 /Ob2 /DNDEBUG /DAL_LIBTYPE_STATIC'
Step 'Configuring'
Run cmake @(
  '-S', $Source, '-B', $Build, '-A', 'x64', '-Wno-dev',
  '-DMEGA_STATIC=ON',
  "-DLOVE_APP_RC=$((Resolve-Path $Rc).Path -replace '\\', '/')",
  '-DSDL_SHARED=OFF', '-DSDL_STATIC=ON', '-DSDL_LIBC=ON',
  '-DLIBTYPE=STATIC',
  '-DMPG123_BUILD_SHARED=OFF', '-DMPG123_BUILD_STATIC=ON',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
  "-DCMAKE_C_FLAGS_RELEASE=$flags", "-DCMAKE_CXX_FLAGS_RELEASE=$flags"
)
# LuaJIT's build runs its own freshly built tools (minilua, buildvm) by bare name from their folder.
# cmd refuses to do that where NoDefaultCurrentDirectoryInExePath is set, so name the folder.
$env:Path = "$(Join-Path $Build 'libs\LuaJIT\src');$env:Path"

Step 'Building (about ten minutes the first time)'
Run cmake @('--build', $Build, '--target', 'love', '--config', 'Release', '--', '/m', '/v:m', '/nologo')

$exe = Join-Path $Build 'love\Release\love.exe'
$foreign = @(Get-Imports $exe | Where-Object {
    $_ -match '^(love|lua5|sdl2|openal|mpg123|msvc[pr]\d|vcruntime|ucrtbase|api-ms-win-crt)'
  })
if ($foreign.Count) { throw "the runtime still depends on: $($foreign -join ', ')" }

New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
Copy-Item $exe $Out -Force
Copy-Item (Join-Path $LoveSource 'license.txt') (Join-Path (Split-Path $Out) 'LOVE-license.txt') -Force
Step ('Built {0} ({1:n1} MB)' -f $Out, ((Get-Item $Out).Length / 1MB))
