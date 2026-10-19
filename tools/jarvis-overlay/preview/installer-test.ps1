# CI: run the real installer end to end on a Windows runner and collect what happened.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here 'install-out'
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $out -Force | Out-Null
$env:JARVIS_SETUP_ALLOW_ADMIN = '1'
$setup = Join-Path (Split-Path -Parent $here) 'jarvis-overlay-setup.ps1'

& powershell -NoProfile -ExecutionPolicy Bypass -File $setup *>&1 | Out-File -FilePath (Join-Path $out 'setup-run1.txt') -Encoding utf8
# second run: must be idempotent
& powershell -NoProfile -ExecutionPolicy Bypass -File $setup *>&1 | Out-File -FilePath (Join-Path $out 'setup-run2.txt') -Encoding utf8

Start-Sleep -Seconds 5
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
$b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
$bmp.Save((Join-Path $out 'desktop-after-install.png'), [Drawing.Imaging.ImageFormat]::Png)

$data = Join-Path $env:USERPROFILE 'AppData\Local\HomeAssistantWindows'
foreach ($f in 'ha_windows.log', 'preferences.json') { $p = Join-Path $data $f; if (Test-Path $p) { Copy-Item $p (Join-Path $out ($f + '.txt')) } }
$ov = Join-Path $env:LOCALAPPDATA 'JarvisOverlay\overlay.log'
if (Test-Path $ov) { Copy-Item $ov (Join-Path $out 'overlay-log.txt') }
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
Get-ChildItem $startup -Filter *.lnk | ForEach-Object { $s = $ws.CreateShortcut($_.FullName); "{0}`n  target: {1}`n  args: {2}" -f $_.Name, $s.TargetPath, $s.Arguments } | Out-File (Join-Path $out 'startup-shortcuts.txt') -Encoding utf8
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'HomeAssistantWindows.exe' -or $_.CommandLine -like '*jarvis-overlay*' } | ForEach-Object { "{0} {1}: {2}" -f $_.ProcessId, $_.Name, $_.CommandLine } | Out-File (Join-Path $out 'processes.txt') -Encoding utf8
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 6053, 6054 } | Format-Table LocalAddress, LocalPort, OwningProcess -AutoSize | Out-String | Out-File (Join-Path $out 'listeners.txt') -Encoding utf8
