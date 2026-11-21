<#
.SYNOPSIS
  Builds Pea for Windows and produces a portable zip (exe + the Swift runtime DLLs it needs).
.EXAMPLE
  ./scripts/package-windows.ps1 -Version 1.0.0
  # -> dist/Pea-1.0.0-windows-x64.zip   (unzip anywhere, run PeaWindows.exe)
.NOTES
  Needs the Swift toolchain on PATH (swift, swiftc, llvm-readobj). Not tested on a real Windows machine by its author:
  if the DLL scan misses something, the app fails to start with "swiftCore.dll was not found"; add -ExtraDll names.
#>
param(
  [string]$Version = "0.0.0",
  [string]$Product = "PeaWindows",
  [string[]]$ExtraDll = @(),
  [switch]$StaticStdlib,     # try `-static-stdlib`: fewer DLLs to ship, bigger exe; needs the static libs in the SDK
  [switch]$Installer,        # also build the Inno Setup installer (dist/Pea-<Version>-windows-x64-setup.exe)
  [string]$GtkRoot = $(if ($env:GTK_ROOT) { $env:GTK_ROOT } else { "C:\gtk-build\gtk\x64\release" })
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not (Test-Path "$GtkRoot\bin\gtk-4-1.dll")) { throw "GTK 4 not found at $GtkRoot - run scripts/setup-gtk-windows.ps1 first" }
$env:GTK_ROOT = $GtkRoot
$env:PATH = "$GtkRoot\bin;$env:PATH"

# GUI subsystem: no console window behind the app.
$buildArgs = @("build", "-c", "release", "--product", $Product, "-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup")
if ($StaticStdlib) { $buildArgs += @("-Xswiftc", "-static-stdlib") }
& swift @buildArgs
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (& swift build -c release --show-bin-path).Trim()
$exe = Join-Path $bin "$Product.exe"
if (-not (Test-Path $exe)) { throw "missing $exe" }

$stage = Join-Path "dist" "Pea-$Version-windows-x64"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe $stage
Copy-Item "assets/Pea.ico","NOTICE.md","LICENSE" $stage -ErrorAction SilentlyContinue

# yt-dlp and ffmpeg ship next to the exe (in .\tools) so nothing has to be installed.
$toolsDir = Join-Path $stage "tools"
New-Item -ItemType Directory -Force $toolsDir | Out-Null
$bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
if (-not $bash) { throw "bash (Git for Windows) is needed to run scripts/fetch-tools.sh" }
& $bash scripts/fetch-tools.sh windows ($toolsDir -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw "fetching yt-dlp / ffmpeg failed" }

# Where the Swift runtime DLLs live: next to the compiler (toolchain) and in the installer's runtime folders.
$searchDirs = @($bin, "$GtkRoot\bin", (Split-Path (Get-Command swiftc).Source -Parent))
$searchDirs += Get-ChildItem "$env:SystemDrive\Program Files\Swift\runtime-*\usr\bin" -ErrorAction SilentlyContinue | ForEach-Object FullName
$searchDirs += Get-ChildItem "$env:SystemDrive\Library\Swift-*\*\usr\bin" -ErrorAction SilentlyContinue | ForEach-Object FullName
if ($env:SDKROOT) { $searchDirs += Join-Path $env:SDKROOT "usr\bin" }
# setup-swift and the swift.org installer put the runtime DLLs in version-specific folders: find them by content.
foreach ($root in @("$env:SystemDrive\Program Files\Swift", "$env:SystemDrive\Library", "$env:LOCALAPPDATA\Programs\Swift")) {
  if (Test-Path $root) {
    $searchDirs += Get-ChildItem $root -Recurse -Filter "swiftCore.dll" -ErrorAction SilentlyContinue | ForEach-Object { $_.Directory.FullName }
    $searchDirs += Get-ChildItem $root -Recurse -Filter "Foundation.dll" -ErrorAction SilentlyContinue | ForEach-Object { $_.Directory.FullName }
  }
}
$searchDirs = $searchDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

# Transitive closure of imported DLLs that we can find in those folders (Windows' own DLLs aren't there, so they're skipped).
$readobj = (Get-Command llvm-readobj -ErrorAction SilentlyContinue).Source
if (-not $readobj) { $readobj = Join-Path (Split-Path (Get-Command swiftc).Source -Parent) "llvm-readobj.exe" }
function Get-Imports([string]$file) {
  & $readobj --coff-imports $file 2>$null | ForEach-Object { if ($_ -match '^\s*Name:\s+(\S+\.dll)\s*$') { $Matches[1] } }
}
$queue = New-Object System.Collections.Queue
$queue.Enqueue($exe)
foreach ($d in $ExtraDll) { $queue.Enqueue($d) }
$done = @{}
while ($queue.Count -gt 0) {
  $item = $queue.Dequeue()
  $file = $null
  if (Test-Path $item) { $file = $item }
  else {
    foreach ($dir in $searchDirs) { $p = Join-Path $dir $item; if (Test-Path $p) { $file = $p; break } }
  }
  if (-not $file) { continue }
  $leaf = Split-Path $file -Leaf
  if ($done.ContainsKey($leaf.ToLower())) { continue }
  $done[$leaf.ToLower()] = $true
  if ($file -ne $exe) { Copy-Item $file $stage -Force; Write-Host "runtime: $leaf" }
  foreach ($dep in Get-Imports $file) { $queue.Enqueue($dep) }
}

# GTK data the runtime looks up next to the exe: GSettings schemas, gdk-pixbuf loaders, the icon theme index.
foreach ($rel in @("share\glib-2.0\schemas", "lib\gdk-pixbuf-2.0", "share\icons\hicolor\index.theme")) {
  $src = Join-Path $GtkRoot $rel
  if (Test-Path $src) {
    $dst = Join-Path $stage $rel
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    Copy-Item $src $dst -Recurse -Force
  }
}

Copy-Item "docs/WINDOWS.md" (Join-Path $stage "README.md") -ErrorAction SilentlyContinue
$zip = Join-Path "dist" "Pea-$Version-windows-x64.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip
foreach ($must in @("swiftCore.dll", "Foundation.dll", "gtk-4-1.dll")) {
  if (-not (Test-Path (Join-Path $stage $must))) { throw "$must was not bundled (searched: $($searchDirs -join '; '))" }
}
Write-Host "Built $zip"

if ($Installer) {
  $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
  if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
  if (-not (Test-Path $iscc)) { throw "Inno Setup 6 (ISCC.exe) not found: choco install innosetup" }
  & $iscc "/DAppVersion=$Version" "/DStageDir=$((Resolve-Path $stage).Path)" "/DOutDir=$((Resolve-Path dist).Path)" "packaging\windows\pea.iss"
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
}
