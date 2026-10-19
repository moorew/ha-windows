# CI preview: run the overlay against a scripted event stream and save screenshots.
# Everything is written to preview/out so the workflow can commit it back (run logs aren't reachable).
$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$overlay = Join-Path (Split-Path -Parent $here) 'jarvis-overlay.ps1'
$out     = Join-Path $here 'out'
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $out -Force | Out-Null
$summary = Join-Path $out 'summary.txt'
Start-Transcript -LiteralPath (Join-Path $out 'transcript.txt') | Out-Null
$ov = $null

try {
    Add-Type -AssemblyName System.Windows.Forms
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    "screen: $($b.Width)x$($b.Height)" | Set-Content $summary
    "powershell: $($PSVersionTable.PSVersion)" | Add-Content $summary
    "session: $([Diagnostics.Process]::GetCurrentProcess().SessionId)  interactive: $([Environment]::UserInteractive)" | Add-Content $summary

    $ov = Start-Process powershell -PassThru -NoNewWindow `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$overlay`"", '-Port', '6054') `
        -RedirectStandardOutput (Join-Path $out 'overlay-stdout.txt') -RedirectStandardError (Join-Path $out 'overlay-stderr.txt')
    "overlay pid: $($ov.Id)" | Add-Content $summary

    & (Join-Path $here 'fake-server.ps1') -Port 6054 -Out $out

    Start-Sleep -Seconds 3
    "overlay still running after the stream closed: $(-not $ov.HasExited)" | Add-Content $summary
} catch {
    ("ERROR: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) | Add-Content $summary
} finally {
    if ($ov -and -not $ov.HasExited) { try { Stop-Process -Id $ov.Id -Force } catch {} }
    $log = Join-Path $env:LOCALAPPDATA 'JarvisOverlay\overlay.log'
    if (Test-Path $log) { Copy-Item $log (Join-Path $out 'overlay-log.txt') } else { 'no overlay.log written' | Add-Content $summary }
    Stop-Transcript | Out-Null
}
Get-Content $summary
