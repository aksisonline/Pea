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
  [switch]$StaticStdlib      # try `-static-stdlib`: fewer DLLs to ship, bigger exe; needs the static libs in the SDK
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

$buildArgs = @("build", "-c", "release", "--product", $Product)
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
Copy-Item "assets/Pea.ico" $stage -ErrorAction SilentlyContinue

# Where the Swift runtime DLLs live: next to the compiler (toolchain) and in the installer's runtime folders.
$searchDirs = @($bin, (Split-Path (Get-Command swiftc).Source -Parent))
$searchDirs += Get-ChildItem "$env:SystemDrive\Program Files\Swift\runtime-*\usr\bin" -ErrorAction SilentlyContinue | ForEach-Object FullName
$searchDirs += Get-ChildItem "$env:SystemDrive\Library\Swift-*\*\usr\bin" -ErrorAction SilentlyContinue | ForEach-Object FullName
if ($env:SDKROOT) { $searchDirs += Join-Path $env:SDKROOT "usr\bin" }
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

Copy-Item "docs/WINDOWS.md" (Join-Path $stage "README.md") -ErrorAction SilentlyContinue
$zip = Join-Path "dist" "Pea-$Version-windows-x64.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Write-Host "Built $zip"
