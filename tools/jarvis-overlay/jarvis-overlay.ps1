<#
  Jarvis overlay: a HUD for ha-windows conversations
  ---------------------------------------------------
  Listens to ha-windows' local event stream (start ha-windows with --event-port 6054)
  and shows a transparent, click-through HUD in the bottom-right corner:
  an animated core for listening / thinking / speaking, what you said, and the reply.

  Run:   powershell -NoProfile -ExecutionPolicy Bypass -File jarvis-overlay.ps1
  Demo:  powershell -NoProfile -ExecutionPolicy Bypass -File jarvis-overlay.ps1 -Demo
         (plays a scripted exchange without ha-windows, then exits; use it to tweak the look)

  Everything you might want to change is in the "Look and feel" block below.
  Needs nothing beyond Windows PowerShell 5.1 and WPF, which ship with Windows 10 and 11.
#>
[CmdletBinding()]
param(
    [int]$Port = 6054,
    [switch]$Demo
)

# ------------------------------------------------------------------ Look and feel
$Look = @{
    Ice        = '#7FE9FF'   # core and accents in listening / speaking
    Filament   = '#FFB547'   # core while thinking
    Fault      = '#FF6B6B'   # core on errors
    Glass      = '#0A1A22'   # smoked-glass backing behind text and core
    GlassAlpha = 0.80        # 0..1
    Reply      = '#EAFBFF'   # reply text
    Spoken     = '#8FB3C2'   # your words
    Font       = 'Bahnschrift'
    ReplySize  = 19
    SpokenSize = 14
    StatusSize = 12
    TextWidth  = 440         # max width of the text column, in DIPs
    Margin     = 22          # gap from the screen edge / taskbar
    CoreSize   = 104
}
$Timing = @{
    LingerBaseSec    = 4.0    # how long the last exchange stays after Jarvis finishes...
    LingerPerCharSec = 0.055  # ...plus this much per character of reply
    LingerMaxSec     = 14.0
    NoSpeechSec      = 3.0
    ErrorSec         = 6.0
    FadeInMs         = 180
    FadeOutMs        = 700
}
$Words = @{
    listening = 'Listening'
    thinking  = 'Thinking'
    replying  = 'Speaking'
    announce  = 'Announcement'
    nospeech  = "Didn't catch that"
    error     = 'Something went wrong'
}

# ------------------------------------------------------------------ setup
$ErrorActionPreference = 'Stop'
$LogDir  = Join-Path $env:LOCALAPPDATA 'JarvisOverlay'
$LogPath = Join-Path $LogDir 'overlay.log'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-OverlayLog([string]$msg) {
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) { Remove-Item -LiteralPath $LogPath -Force }
        Add-Content -LiteralPath $LogPath -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\JarvisOverlay', [ref]$mutexCreated)
if (-not $mutexCreated -and -not $Demo) { Write-OverlayLog 'Already running; exiting'; exit 0 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class JarvisNative {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
'@
# Per-monitor DPI awareness before any window exists, so text stays sharp at any scaling.
# (Fails harmlessly if the host already declared its awareness.)
try { [void][JarvisNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function ConvertTo-Color([string]$hex, [double]$alpha = 1.0) {
    $c = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($hex)
    return [Windows.Media.Color]::FromArgb([byte][Math]::Round(255 * $alpha), $c.R, $c.G, $c.B)
}

# ------------------------------------------------------------------ window
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Jarvis overlay" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Ideal" TextOptions.TextRenderingMode="Grayscale">
  <Grid x:Name="Root" Opacity="0" Margin="24">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>

    <Border x:Name="TextPanel" Grid.Column="0" VerticalAlignment="Center" Margin="0,0,-10,0"
            Padding="26,14,30,15" CornerRadius="16,2,2,16" MaxWidth="$($Look.TextWidth + 56)">
      <StackPanel>
        <TextBlock x:Name="StatusText" FontFamily="$($Look.Font)" FontStretch="SemiCondensed" FontWeight="Normal"
                   FontSize="$($Look.StatusSize)" Margin="0,0,0,4"/>
        <TextBlock x:Name="SpokenText" FontFamily="$($Look.Font)" FontStretch="SemiCondensed" FontWeight="Light"
                   FontSize="$($Look.SpokenSize)" TextWrapping="Wrap" MaxWidth="$($Look.TextWidth)"
                   TextTrimming="CharacterEllipsis" MaxHeight="60" Margin="0,0,0,6"/>
        <TextBlock x:Name="ReplyText" FontFamily="$($Look.Font)" FontWeight="Normal"
                   FontSize="$($Look.ReplySize)" TextWrapping="Wrap" MaxWidth="$($Look.TextWidth)"
                   TextTrimming="CharacterEllipsis" MaxHeight="190" LineHeight="25"/>
      </StackPanel>
    </Border>

    <Grid x:Name="Core" Grid.Column="1" Width="$($Look.CoreSize)" Height="$($Look.CoreSize)" VerticalAlignment="Center">
      <Ellipse x:Name="Backing" Width="98" Height="98"/>
      <Ellipse x:Name="Dial" Width="88" Height="88" StrokeThickness="4" Opacity="0.45" RenderTransformOrigin="0.5,0.5"/>
      <Ellipse x:Name="OuterArc" Width="100" Height="100" StrokeThickness="2" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5"/>
      <Ellipse x:Name="InnerArc" Width="66" Height="66" StrokeThickness="3" StrokeDashCap="Flat" Opacity="0.85" RenderTransformOrigin="0.5,0.5"/>
      <Ellipse x:Name="Heart" Width="30" Height="30" RenderTransformOrigin="0.5,0.5"/>
    </Grid>
  </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'Root','TextPanel','StatusText','SpokenText','ReplyText','Core','Backing','Dial','OuterArc','InnerArc','Heart') {
    $ui[$n] = $window.FindName($n)
}

# Transforms, brushes and effects are built here rather than in XAML so they stay animatable.
$ui.DialTurn   = New-Object Windows.Media.RotateTransform;  $ui.Dial.RenderTransform     = $ui.DialTurn
$ui.OuterTurn  = New-Object Windows.Media.RotateTransform;  $ui.OuterArc.RenderTransform = $ui.OuterTurn
$ui.InnerTurn  = New-Object Windows.Media.RotateTransform;  $ui.InnerArc.RenderTransform = $ui.InnerTurn
$ui.HeartScale = New-Object Windows.Media.ScaleTransform(0.75, 0.75); $ui.Heart.RenderTransform = $ui.HeartScale
$ui.Glow = New-Object Windows.Media.Effects.DropShadowEffect
$ui.Glow.BlurRadius = 20; $ui.Glow.ShadowDepth = 0; $ui.Glow.Opacity = 0.9
$ui.Core.Effect = $ui.Glow

# Colours live in mutable brushes so state changes can animate them.
$accent = New-Object Windows.Media.SolidColorBrush (ConvertTo-Color $Look.Ice)
$heartBrush = New-Object Windows.Media.RadialGradientBrush
$heartBrush.GradientStops.Add((New-Object Windows.Media.GradientStop((ConvertTo-Color '#FFFFFF' 0.95), 0.0)))
$heartStop = New-Object Windows.Media.GradientStop((ConvertTo-Color $Look.Ice 0.85), 0.45)
$heartBrush.GradientStops.Add($heartStop)
$heartEdge = New-Object Windows.Media.GradientStop((ConvertTo-Color $Look.Ice 0.0), 1.0)
$heartBrush.GradientStops.Add($heartEdge)

# The text backing feathers out on the left so it reads as light from the core, not a box.
$panel = New-Object Windows.Media.LinearGradientBrush
$panel.StartPoint = New-Object Windows.Point(0, 0.5); $panel.EndPoint = New-Object Windows.Point(1, 0.5)
$panel.GradientStops.Add((New-Object Windows.Media.GradientStop((ConvertTo-Color $Look.Glass 0.0), 0.0)))
$panel.GradientStops.Add((New-Object Windows.Media.GradientStop((ConvertTo-Color $Look.Glass ($Look.GlassAlpha * 0.85)), 0.08)))
$panel.GradientStops.Add((New-Object Windows.Media.GradientStop((ConvertTo-Color $Look.Glass $Look.GlassAlpha), 1.0)))
$ui.TextPanel.Background = $panel
$ui.Backing.Fill     = New-Object Windows.Media.SolidColorBrush (ConvertTo-Color $Look.Glass $Look.GlassAlpha)
$ui.Dial.Stroke      = $accent
$ui.OuterArc.Stroke  = $accent
$ui.InnerArc.Stroke  = $accent
$ui.Heart.Fill       = $heartBrush
$ui.Glow.Color       = ConvertTo-Color $Look.Ice
$ui.StatusText.Foreground = $accent
$ui.SpokenText.Foreground = New-Object Windows.Media.SolidColorBrush (ConvertTo-Color $Look.Spoken)
$ui.ReplyText.Foreground  = New-Object Windows.Media.SolidColorBrush (ConvertTo-Color $Look.Reply)

# Legibility over any wallpaper: a soft dark halo under the text.
foreach ($tb in $ui.SpokenText, $ui.ReplyText, $ui.StatusText) {
    $fx = New-Object Windows.Media.Effects.DropShadowEffect
    $fx.Color = [Windows.Media.Colors]::Black; $fx.ShadowDepth = 0; $fx.BlurRadius = 6; $fx.Opacity = 0.65
    $tb.Effect = $fx
}

# Dash patterns are in multiples of stroke thickness, so derive them from each circle's circumference.
function Set-Dashes($ellipse, [double[]]$degrees) {
    $units = [Math]::PI * $ellipse.Width / $ellipse.StrokeThickness
    $dc = New-Object Windows.Media.DoubleCollection
    foreach ($d in $degrees) { $dc.Add($units * $d / 360.0) }
    $ellipse.StrokeDashArray = $dc
}
$tick = 360.0 / 72
Set-Dashes $ui.Dial     @(($tick * 0.18), ($tick * 0.82))   # 72 fine ticks
Set-Dashes $ui.OuterArc @(84, 36)                           # three long sweeps
Set-Dashes $ui.InnerArc @(150, 30)                          # two heavy arcs

$motion = [Windows.SystemParameters]::ClientAreaAnimation   # false when "Animation effects" is off

# ------------------------------------------------------------------ animation helpers
function Start-Spin($rotate, [double]$seconds, [bool]$reverse = $false) {
    if (-not $motion -or $seconds -le 0) { $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null); return }
    $from = $rotate.Angle % 360
    $to = if ($reverse) { $from - 360 } else { $from + 360 }
    $a = New-Object Windows.Media.Animation.DoubleAnimation($from, $to, [Windows.Duration]::new([TimeSpan]::FromSeconds($seconds)))
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $a)
}

function Set-Accent([string]$hex) {
    $target = ConvertTo-Color $hex
    $d = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
    $accent.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, (New-Object Windows.Media.Animation.ColorAnimation($target, $d)))
    $heartStop.BeginAnimation([Windows.Media.GradientStop]::ColorProperty, (New-Object Windows.Media.Animation.ColorAnimation((ConvertTo-Color $hex 0.85), $d)))
    $heartEdge.Color = ConvertTo-Color $hex 0.0
    $ui.Glow.BeginAnimation([Windows.Media.Effects.DropShadowEffect]::ColorProperty, (New-Object Windows.Media.Animation.ColorAnimation($target, $d)))
}

function Set-Opacity($element, [double]$to, [int]$ms) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation($to, [Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)))
    $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

function Set-HeartScale([double]$to, [int]$ms) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation($to, [Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)))
    $a.EasingFunction = New-Object Windows.Media.Animation.QuadraticEase
    $ui.HeartScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $ui.HeartScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
}

# ------------------------------------------------------------------ state
$S = @{ Visible = $false; Mode = 'idle'; HideAt = $null; HasReply = $false }
$rand = New-Object Random

function Set-Mode([string]$mode) {
    $S.Mode = $mode
    switch ($mode) {
        'listening' { Set-Accent $Look.Ice;      Start-Spin $ui.OuterTurn 7;   Start-Spin $ui.InnerTurn 11 $true; Start-Spin $ui.DialTurn 40; Set-HeartScale 0.85 300 }
        'thinking'  { Set-Accent $Look.Filament; Start-Spin $ui.OuterTurn 1.3; Start-Spin $ui.InnerTurn 2.1 $true; Start-Spin $ui.DialTurn 9;  Set-HeartScale 0.7 300 }
        'replying'  { Set-Accent $Look.Ice;      Start-Spin $ui.OuterTurn 5;   Start-Spin $ui.InnerTurn 8 $true;  Start-Spin $ui.DialTurn 30 }
        'error'     { Set-Accent $Look.Fault;    Start-Spin $ui.OuterTurn 0;   Start-Spin $ui.InnerTurn 0;        Start-Spin $ui.DialTurn 0;  Set-HeartScale 0.6 300 }
        default     { Start-Spin $ui.OuterTurn 16; Start-Spin $ui.InnerTurn 24 $true; Start-Spin $ui.DialTurn 0; Set-HeartScale 0.75 500 }
    }
}

function Update-Panel {
    $any = $ui.StatusText.Text -or $ui.SpokenText.Text -or $ui.ReplyText.Text
    $ui.TextPanel.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
}

function Set-Status([string]$text) {
    $ui.StatusText.Text = $text
    $ui.StatusText.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    Update-Panel
}

function Set-Spoken([string]$text) {
    $ui.SpokenText.Text = $text
    $ui.SpokenText.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    Update-Panel
}

function Set-Reply([string]$text) {
    $ui.ReplyText.Text = $text
    $ui.ReplyText.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    $S.HasReply = [bool]$text
    Update-Panel
    if ($text) {
        $ui.ReplyText.Opacity = 0
        Set-Opacity $ui.ReplyText 1 320
    }
}

function Clear-Exchange { Set-Spoken ''; Set-Reply ''; Set-Status '' }

function Show-Overlay {
    $S.HideAt = $null
    if (-not $S.Visible) {
        $S.Visible = $true
        $window.Topmost = $false; $window.Topmost = $true   # re-assert above other topmost windows
        Set-Opacity $ui.Root 1 $Timing.FadeInMs
    }
}

function Hide-Later([double]$seconds) {
    if (-not $S.Visible) { return }
    $at = (Get-Date).AddSeconds($seconds)
    # never cut short a longer hold that is already scheduled (e.g. "Didn't catch that")
    if (-not $S.HideAt -or $at -gt $S.HideAt) { $S.HideAt = $at }
}

function Get-Linger {
    $chars = $ui.ReplyText.Text.Length
    return [Math]::Min($Timing.LingerMaxSec, $Timing.LingerBaseSec + $chars * $Timing.LingerPerCharSec)
}

function Handle-Event($e) {
    switch ([string]$e.type) {
        'hello' {
            Write-OverlayLog ("Connected to {0} (ha-windows {1}, protocol {2})" -f $e.device, $e.version, $e.protocol)
        }
        'wake_word' {
            Clear-Exchange; Set-Status $Words.listening; Set-Mode 'listening'; Show-Overlay
        }
        'phase' {
            switch ([string]$e.phase) {
                'listening' { if ($S.HasReply) { Clear-Exchange }; Set-Status $Words.listening; Set-Mode 'listening'; Show-Overlay }
                'thinking'  { Set-Status $Words.thinking; Set-Mode 'thinking'; Show-Overlay }
                'replying'  { if ($ui.StatusText.Text -ne $Words.announce) { Set-Status $Words.replying }; Set-Mode 'replying'; Show-Overlay }
                'error'     { Set-Status $Words.error; Set-Mode 'error'; Show-Overlay; Hide-Later $Timing.ErrorSec }
                'idle'      {
                    if ($S.Mode -ne 'error') { Set-Mode 'idle' }
                    if ($S.HasReply) { Set-Status ''; Hide-Later (Get-Linger) }
                    elseif ($S.Mode -ne 'error') { Hide-Later 1.5 }
                }
                'not_ready' { Set-Mode 'idle'; Hide-Later 1.0 }
            }
        }
        'stt'      { Set-Spoken ([string]$e.text); Show-Overlay }
        'tts'      { Set-Reply ([string]$e.text); Show-Overlay }
        'announce' { Clear-Exchange; Set-Status $Words.announce; Set-Reply ([string]$e.text); Set-Mode 'replying'; Show-Overlay; Hide-Later ([Math]::Max(6, (Get-Linger))) }
        'info'     { Set-Status $Words.nospeech; Set-Mode 'idle'; Show-Overlay; Hide-Later $Timing.NoSpeechSec }
        'error'    {
            Set-Status $Words.error
            if ($e.message) { Set-Reply ([string]$e.message) }
            Set-Mode 'error'; Show-Overlay; Hide-Later $Timing.ErrorSec
        }
    }
}

# ------------------------------------------------------------------ placement and window styles
function Update-Position {
    $wa = [Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right - $window.ActualWidth - ($Look.Margin - 24)
    $window.Top  = $wa.Bottom - $window.ActualHeight - ($Look.Margin - 24)
}
$window.Add_SizeChanged({ Update-Position })
$script:lastWorkArea = $null

$window.Add_SourceInitialized({
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
    # click-through (TRANSPARENT), no taskbar / Alt+Tab entry (TOOLWINDOW), never takes focus (NOACTIVATE)
    $ex = [JarvisNative]::GetWindowLong($hwnd, -20)
    [void][JarvisNative]::SetWindowLong($hwnd, -20, ($ex -bor 0x20 -bor 0x80 -bor 0x08000000))
})

Clear-Exchange
Set-Mode 'idle'

# ------------------------------------------------------------------ event stream client
$Net = @{
    Client = $null; Stream = $null; Connect = $null; Connected = $false
    NextTry = [datetime]::MinValue
    Decoder = [Text.Encoding]::UTF8.GetDecoder()
    Bytes = New-Object byte[] 16384
    Chars = New-Object char[] 16384
    Pending = New-Object Text.StringBuilder
}

function Reset-Connection([string]$why) {
    if ($Net.Connected) { Write-OverlayLog "Disconnected: $why" }
    try { if ($Net.Client) { $Net.Client.Close() } } catch {}
    $Net.Client = $null; $Net.Stream = $null; $Net.Connect = $null; $Net.Connected = $false
    $Net.Decoder = [Text.Encoding]::UTF8.GetDecoder()
    [void]$Net.Pending.Clear()
    $Net.NextTry = (Get-Date).AddSeconds(3)
    if ($S.Visible) { Set-Mode 'idle'; Hide-Later 0.5 }
}

function Read-Stream {
    if (-not $Net.Connected) {
        if ($Net.Connect) {
            if (-not $Net.Connect.IsCompleted) { return }
            if ($Net.Connect.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion -and $Net.Client.Connected) {
                $Net.Stream = $Net.Client.GetStream()
                $Net.Connected = $true
                $Net.Connect = $null
                return
            }
            Reset-Connection 'connect failed'
            return
        }
        if ((Get-Date) -ge $Net.NextTry) {
            $Net.Client = New-Object Net.Sockets.TcpClient
            $Net.Connect = $Net.Client.ConnectAsync('127.0.0.1', $Port)
        }
        return
    }
    $sock = $Net.Client.Client
    if ($sock.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $sock.Available -eq 0) { Reset-Connection 'closed by ha-windows'; return }
    while ($Net.Stream.DataAvailable) {
        $n = $Net.Stream.Read($Net.Bytes, 0, $Net.Bytes.Length)
        if ($n -le 0) { Reset-Connection 'closed'; return }
        $c = $Net.Decoder.GetChars($Net.Bytes, 0, $n, $Net.Chars, 0)
        [void]$Net.Pending.Append($Net.Chars, 0, $c)
    }
    $buffered = $Net.Pending.ToString()
    $cut = $buffered.LastIndexOf("`n")
    if ($cut -lt 0) { return }
    [void]$Net.Pending.Clear()
    [void]$Net.Pending.Append($buffered.Substring($cut + 1))
    foreach ($line in $buffered.Substring(0, $cut).Split("`n")) {
        if (-not $line.Trim()) { continue }
        try { Handle-Event ($line | ConvertFrom-Json) } catch { Write-OverlayLog "Bad event: $line ($($_.Exception.Message))" }
    }
}

# ------------------------------------------------------------------ demo script
$DemoSteps = New-Object System.Collections.Queue
if ($Demo) {
    foreach ($step in @(
        @(0.6, @{ type = 'wake_word'; phrase = 'Jarvis' }),
        @(0.1, @{ type = 'phase'; phase = 'listening' }),
        @(2.2, @{ type = 'stt'; text = 'Turn on the office lights and set them to eighty percent' }),
        @(0.1, @{ type = 'phase'; phase = 'thinking' }),
        @(1.6, @{ type = 'tts'; text = 'Done. The office lights are on at 80 percent. Anything else?' }),
        @(0.1, @{ type = 'phase'; phase = 'replying' }),
        @(3.4, @{ type = 'phase'; phase = 'idle' }),
        @(7.5, @{ type = 'wake_word'; phrase = 'Jarvis' }),
        @(0.1, @{ type = 'phase'; phase = 'listening' }),
        @(2.0, @{ type = 'info'; code = 'stt-no-text-recognized'; text = 'No speech recognized' }),
        @(0.1, @{ type = 'phase'; phase = 'idle' }),
        @(4.5, @{ type = 'quit' })
    )) { $DemoSteps.Enqueue($step) }
    $DemoNext = (Get-Date).AddSeconds(1)
}

function Step-Demo {
    while ($DemoSteps.Count -gt 0 -and (Get-Date) -ge $script:DemoNext) {
        $step = $DemoSteps.Dequeue()
        $evt = [pscustomobject]($step[1])
        if ($evt.type -eq 'quit') { $window.Close(); return }
        Handle-Event $evt
        if ($DemoSteps.Count -gt 0) { $script:DemoNext = (Get-Date).AddSeconds($DemoSteps.Peek()[0]) }
    }
}

# ------------------------------------------------------------------ main loop
$pulseAt = Get-Date
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    try {
        if ($Demo) { Step-Demo } else { Read-Stream }

        # follow taskbar / resolution changes
        $wa = [Windows.SystemParameters]::WorkArea
        if ($wa -ne $script:lastWorkArea) { $script:lastWorkArea = $wa; Update-Position }

        # a voice-like flicker of the heart while speaking
        if ($S.Mode -eq 'replying' -and $motion -and (Get-Date) -ge $script:pulseAt) {
            Set-HeartScale (0.8 + $rand.NextDouble() * 0.45) 110
            $script:pulseAt = (Get-Date).AddMilliseconds(120 + $rand.Next(60))
        }

        if ($S.HideAt -and (Get-Date) -ge $S.HideAt) {
            $S.HideAt = $null
            $S.Visible = $false
            Set-Opacity $ui.Root 0 $Timing.FadeOutMs
        }
    } catch {
        Write-OverlayLog "Tick error: $($_.Exception.Message)"
        if (-not $Demo) { Reset-Connection 'error' }
    }
})

$window.Add_Loaded({ Update-Position; $timer.Start() })
$window.Add_Closed({ $timer.Stop(); try { if ($Net.Client) { $Net.Client.Close() } } catch {} })

Write-OverlayLog ("Starting (port {0}{1})" -f $Port, $(if ($Demo) { ', demo' } else { '' }))
$app = New-Object Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'
[void]$app.Run($window)
if ($mutexCreated) { $mutex.ReleaseMutex() }
