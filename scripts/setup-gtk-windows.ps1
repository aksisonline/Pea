<#
.SYNOPSIS
  Installs the prebuilt GTK 4 for Windows (wingtk/gvsbuild, MSVC ABI) that PeaUI links against, and exports
  PKG_CONFIG / PKG_CONFIG_PATH / PATH for the rest of the CI job (and prints them for local use).
.NOTES
  The .pc files in that bundle hard-code the prefix C:/gtk-build/gtk/x64/release, so that is where it must live.
#>
param([string]$Tag = "2026.10.0")
$ErrorActionPreference = "Stop"
$root = "C:\gtk-build\gtk\x64\release"
if (-not (Test-Path "$root\bin\gtk-4-1.dll")) {
  $zip = Join-Path $env:TEMP "gtk4.zip"
  Write-Host "Downloading GTK4 $Tag ..."
  Invoke-WebRequest "https://github.com/wingtk/gvsbuild/releases/download/$Tag/GTK4_Gvsbuild_${Tag}_x64.zip" -OutFile $zip
  New-Item -ItemType Directory -Force $root | Out-Null
  Expand-Archive $zip -DestinationPath $root -Force
  Remove-Item $zip
}
$env:PKG_CONFIG = "$root\bin\pkgconf.exe"
$env:PKG_CONFIG_PATH = "$root\lib\pkgconfig"
$env:PATH = "$root\bin;$env:PATH"
if ($env:GITHUB_ENV) {
  "PKG_CONFIG=$root\bin\pkgconf.exe" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
  "PKG_CONFIG_PATH=$root\lib\pkgconfig" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
  "GTK_ROOT=$root" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
  "$root\bin" | Out-File -Append -Encoding utf8 $env:GITHUB_PATH
}
& $env:PKG_CONFIG --modversion gtk4
