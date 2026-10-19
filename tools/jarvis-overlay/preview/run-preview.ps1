# CI preview: run the overlay against a scripted event stream and save screenshots.
$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$overlay = Join-Path (Split-Path -Parent $here) 'jarvis-overlay.ps1'
$out     = Join-Path $here 'out'
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $out -Force | Out-Null

Add-Type -AssemblyName System.Windows.Forms
$b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
"screen: $($b.Width)x$($b.Height)" | Set-Content (Join-Path $out 'summary.txt')
"powershell: $($PSVersionTable.PSVersion)" | Add-Content (Join-Path $out 'summary.txt')

$ov = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$overlay`"", '-Port', '6054') -PassThru -WindowStyle Hidden
Write-Host "overlay pid $($ov.Id)"

& (Join-Path $here 'fake-server.ps1') -Port 6054 -Out $out

Start-Sleep -Seconds 3
"overlay still running after stream closed: $(-not $ov.HasExited)" | Add-Content (Join-Path $out 'summary.txt')
try { Stop-Process -Id $ov.Id -Force } catch {}

$log = Join-Path $env:LOCALAPPDATA 'JarvisOverlay\overlay.log'
if (Test-Path $log) { Copy-Item $log (Join-Path $out 'overlay.log') } else { 'no overlay log' | Add-Content (Join-Path $out 'summary.txt') }
Get-Content (Join-Path $out 'summary.txt')
if (Test-Path (Join-Path $out 'overlay.log')) { Get-Content (Join-Path $out 'overlay.log') }
