# Plays a scripted conversation over the ha-windows event stream protocol and screenshots the overlay.
param([int]$Port = 6054, [string]$Out)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Path $Out -Force | Out-Null

function Snap([string]$name) {
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w = [Math]::Min(1100, $b.Width); $h = [Math]::Min(600, $b.Height)
    $bmp = New-Object Drawing.Bitmap $w, $h
    $g = [Drawing.Graphics]::FromImage($bmp)
    $op = [Drawing.CopyPixelOperation]([int][Drawing.CopyPixelOperation]::SourceCopy -bor [int][Drawing.CopyPixelOperation]::CaptureBlt)
    $g.CopyFromScreen($b.Right - $w, $b.Bottom - $h, 0, 0, (New-Object Drawing.Size $w, $h), $op)
    $bmp.Save((Join-Path $Out "$name.png"), [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "snap $name"
}

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "listening on $Port"
$client = $listener.AcceptTcpClient()
Write-Host 'overlay connected'
$stream = $client.GetStream()
$enc = New-Object Text.UTF8Encoding($false)

function Send($obj) {
    $obj['v'] = 1
    $obj['ts'] = [Math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0), 3)
    $bytes = $enc.GetBytes((($obj | ConvertTo-Json -Compress) + "`n"))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}
function Wait([double]$s) { Start-Sleep -Milliseconds ([int]($s * 1000)) }

Send ([ordered]@{ type = 'hello'; device = 'preview'; version = '1.4.3'; protocol = 1; phase = 'idle' })
Wait 1.5
Snap '00-idle-nothing-shown'

Send ([ordered]@{ type = 'wake_word'; phrase = 'Jarvis' })
Send ([ordered]@{ type = 'phase'; phase = 'listening' })
Wait 1.0; Snap '01-listening'

Send ([ordered]@{ type = 'stt'; text = 'Turn on the office lights and set them to eighty percent' })
Send ([ordered]@{ type = 'phase'; phase = 'thinking' })
Wait 0.9; Snap '02-thinking'

Send ([ordered]@{ type = 'phase'; phase = 'replying' })
Send ([ordered]@{ type = 'tts'; text = 'Done. The office lights are on at 80 percent. Anything else?' })
Wait 1.0; Snap '03-speaking'

Send ([ordered]@{ type = 'phase'; phase = 'idle' })
Wait 2.0; Snap '04-lingering-after-reply'
Wait 9.0; Snap '05-faded-out'

Send ([ordered]@{ type = 'wake_word'; phrase = 'Jarvis' })
Send ([ordered]@{ type = 'phase'; phase = 'listening' })
Wait 1.2
Send ([ordered]@{ type = 'info'; code = 'stt-no-text-recognized'; text = 'No speech recognized' })
Send ([ordered]@{ type = 'phase'; phase = 'idle' })
Wait 0.8; Snap '06-no-speech'
Wait 4.0

$light = Start-Process notepad -WindowStyle Maximized -PassThru
Wait 2.5
Send ([ordered]@{ type = 'announce'; text = ('Reminder: the dentist is at 3:30 today, and it is 21' + [char]176 + 'C outside.') })
Send ([ordered]@{ type = 'phase'; phase = 'replying' })
Wait 1.0; Snap '07-announcement-on-light-window'
Send ([ordered]@{ type = 'phase'; phase = 'idle' })
Wait 1.0

Send ([ordered]@{ type = 'wake_word'; phrase = 'Jarvis' })
Send ([ordered]@{ type = 'phase'; phase = 'listening' })
Send ([ordered]@{ type = 'stt'; text = "What's the weather tomorrow?" })
Send ([ordered]@{ type = 'phase'; phase = 'thinking' })
Wait 0.6
Send ([ordered]@{ type = 'error'; code = 'intent-failed'; message = 'The conversation agent did not respond.' })
Send ([ordered]@{ type = 'phase'; phase = 'error' })
Wait 1.0; Snap '08-error'
Wait 1.0

$long = 'Tomorrow looks mixed. Expect a cool, cloudy morning around 6 degrees with a chance of light rain before noon, ' +
        'clearing in the afternoon to a high of 14. Winds pick up from the west in the evening, gusting to 40 kilometres an hour, ' +
        'so it might be worth bringing the patio cushions in tonight. The weekend is looking drier and a little warmer, with sun ' +
        'on Saturday and a high of 17, before more rain moves in on Sunday night and lingers into Monday morning.'
Send ([ordered]@{ type = 'wake_word'; phrase = 'Jarvis' })
Send ([ordered]@{ type = 'phase'; phase = 'listening' })
Send ([ordered]@{ type = 'stt'; text = 'What does the rest of the week look like, and should I worry about the wind tonight or is it fine to leave things outside?' })
Send ([ordered]@{ type = 'phase'; phase = 'thinking' })
Wait 0.5
Send ([ordered]@{ type = 'phase'; phase = 'replying' })
Send ([ordered]@{ type = 'tts'; text = $long })
Wait 1.0; Snap '09-long-reply'

try { $light | Stop-Process -Force } catch {}
$client.Close()
$listener.Stop()
Write-Host 'done'
