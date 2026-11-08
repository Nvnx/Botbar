# BotBar - a notch at the top of the screen showing the status of every Claude Code session.
# Reads the per-session status files Claude Code keeps in ~/.claude/sessions (no hooks needed).
# Hover to expand, click a session to open it (desktop app) or focus its terminal (CLI), drag to move, right-click for settings.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace BotBar {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    }

    public static class Synth {
        // A soft bell chime as an in-memory WAV: each note starts at its own time and rings out.
        public static MemoryStream Chime(double[] notes, double[] starts, double ring, double seconds, double volume) {
            const int rate = 44100;
            int n = (int)(rate * seconds);
            var mix = new double[n];
            for (int k = 0; k < notes.Length; k++) {
                int first = (int)(starts[k] * rate);
                for (int i = first; i < n; i++) {
                    double t = (i - first) / (double)rate;
                    double attack = Math.Min(1.0, t / 0.006);
                    double w = 2 * Math.PI * notes[k] * t;
                    mix[i] += attack * (Math.Exp(-t / ring) * Math.Sin(w)
                                      + 0.30 * Math.Exp(-t / (ring * 0.45)) * Math.Sin(2 * w)
                                      + 0.10 * Math.Exp(-t / (ring * 0.25)) * Math.Sin(3.01 * w));
                }
            }
            var ms = new MemoryStream();
            var bw = new BinaryWriter(ms);
            bw.Write(Encoding.ASCII.GetBytes("RIFF")); bw.Write(36 + n * 2); bw.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            bw.Write(16); bw.Write((short)1); bw.Write((short)1); bw.Write(rate); bw.Write(rate * 2); bw.Write((short)2); bw.Write((short)16);
            bw.Write(Encoding.ASCII.GetBytes("data")); bw.Write(n * 2);
            int tail = rate / 20;
            for (int i = 0; i < n; i++) {
                double fade = i > n - tail ? (n - i) / (double)tail : 1.0;
                double v = Math.Max(-1.0, Math.Min(1.0, mix[i] * volume * fade));
                bw.Write((short)(v * 32767));
            }
            bw.Flush();
            ms.Position = 0;
            return ms;
        }
    }
}
'@

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'BotBar.SingleInstance', [ref]$createdNew)
if (-not $createdNew) { exit }

# BOTBAR_SESSIONS points the bar at a different folder, for testing with fake session files.
$sessionDir = if ($env:BOTBAR_SESSIONS) { $env:BOTBAR_SESSIONS } else { Join-Path $env:USERPROFILE '.claude\sessions' }
$order  = 'waiting', 'busy', 'done'
$colors = @{ waiting = '#FFB020'; busy = '#4DA3FF'; done = '#3DDC84'; seen = '#5E9C7A' }
$alertSeconds = 6
$maxDots = 8          # above this many sessions the notch shows counts instead of one dot each
$windowWidth = 520

# Finished: three rising notes. Needs you: a two-note doorbell.
$players = @{
    done    = New-Object System.Media.SoundPlayer ([BotBar.Synth]::Chime([double[]](880, 1108.73, 1318.51), [double[]](0, 0.09, 0.18), 0.30, 1.2, 0.20))
    waiting = New-Object System.Media.SoundPlayer ([BotBar.Synth]::Chime([double[]](1318.51, 1046.50), [double[]](0, 0.24), 0.42, 1.4, 0.22))
}
foreach ($p in $players.Values) { try { $p.Load() } catch {} }

# --- Settings (changed from the right-click menu, saved next to the script) ---
$settingsPath = Join-Path $PSScriptRoot 'BotBar.settings.json'
$startupLink  = Join-Path ([Environment]::GetFolderPath('Startup')) 'BotBar.lnk'
$settings = @{
    Monitor = ''; Position = 'Center'; Offset = 0.5; Locked = $false
    ShowDone = $true; Sound = $true; FadeIdle = $true; HideFullscreen = $true; TwoLine = $true
    HideAfterMinutes = 5    # slide away after this long with no session activity; 0 = never
}
if (Test-Path $settingsPath) {
    try {
        $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json
        foreach ($k in @($settings.Keys)) { if ($null -ne $saved.$k) { $settings[$k] = $saved.$k } }
    } catch {}
}
function Save-Settings { $settings | ConvertTo-Json | Set-Content $settingsPath -Encoding utf8 }

# The window is a fixed, fully transparent strip; only the pill inside it is drawn and clickable.
# The two star columns either side of the pill decide where it sits and which way it grows.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="BotBar" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        Width="520" Height="900" Top="0" FontFamily="Segoe UI" FontSize="12">
  <Grid VerticalAlignment="Top">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Name="PadLeft" Width="*"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Name="PadRight" Width="*"/>
    </Grid.ColumnDefinitions>
    <Border Name="Slot" Grid.Column="1" VerticalAlignment="Top">
      <Border Name="Pill" Background="#F2000000" CornerRadius="0,0,24,24" Padding="18,5,18,7">
        <Border.ContextMenu>
          <ContextMenu Name="Menu"/>
        </Border.ContextMenu>
        <StackPanel>
          <StackPanel Name="Summary" Orientation="Horizontal" HorizontalAlignment="Center"/>
          <Border ClipToBounds="True" Width="0" Height="0" Margin="-8,0,-8,0">
            <Canvas Width="0" Height="0" HorizontalAlignment="Center" VerticalAlignment="Top">
              <StackPanel Name="Alerts" Margin="0,6,0,0"/>
            </Canvas>
          </Border>
          <Border ClipToBounds="True" Width="0" Height="0" Margin="-8,0,-8,0">
            <Canvas Width="0" Height="0" HorizontalAlignment="Center" VerticalAlignment="Top">
              <StackPanel Name="Details" Margin="0,8,0,2"/>
            </Canvas>
          </Border>
        </StackPanel>
      </Border>
    </Border>
  </Grid>
</Window>
'@
$window  = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$padLeft  = $window.FindName('PadLeft')
$padRight = $window.FindName('PadRight')
$slot    = $window.FindName('Slot')
$pill    = $window.FindName('Pill')
$summary = $window.FindName('Summary')
$alertsPanel = $window.FindName('Alerts')
$details = $window.FindName('Details')
$detailsBox = $details.Parent.Parent
$menu    = $window.FindName('Menu')
$brushes = New-Object Windows.Media.BrushConverter

function Format-Span($ms) {
    $secs = [math]::Max(0, [math]::Floor($ms / 1000))
    if ($secs -lt 60) { "${secs}s" }
    elseif ($secs -lt 3600) { '{0}m' -f [math]::Floor($secs / 60) }
    else { '{0}h {1}m' -f [math]::Floor($secs / 3600), [math]::Floor(($secs % 3600) / 60) }
}

function Get-Sessions {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($f in Get-ChildItem $sessionDir -Filter *.json -ErrorAction SilentlyContinue) {
        try { $j = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if (-not $j.pid) { continue }
        $proc = Get-Process -Id $j.pid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        # A crashed session can leave its file behind, and Windows may hand its PID to another
        # program later. procStart is the process start time (UTC FILETIME), so a mismatch means
        # the PID now belongs to someone else. If the start time can't be read (an elevated
        # process), trust the PID.
        if ($j.procStart) {
            $started = try { $proc.StartTime.ToFileTimeUtc() } catch { $null }
            if ($null -ne $started -and "$started" -ne "$($j.procStart)") { continue }
        }

        # Claude Code writes busy / shell while working, waiting (with a waitingFor reason)
        # when it is blocked on the user, and idle once the turn is over.
        $state = switch ("$($j.status)") {
            'busy'    { 'busy' }
            'shell'   { 'busy' }
            'waiting' { 'waiting' }
            default   { 'done' }
        }

        $since = if ($j.statusUpdatedAt) { $j.statusUpdatedAt } else { $j.startedAt }
        $mins  = [math]::Max(0, [math]::Floor(($now - $since) / 60000))
        $age   = if ($mins -lt 1) { 'now' } elseif ($mins -lt 60) { "${mins}m" }
                 elseif ($mins -lt 1440) { '{0}h' -f [math]::Floor($mins / 60) }
                 else { '{0}d' -f [math]::Floor($mins / 1440) }

        $folder = if ($j.cwd) { Split-Path $j.cwd -Leaf } else { '' }
        [pscustomobject]@{
            Id     = if ($j.sessionId) { $j.sessionId } else { "$($j.pid)" }
            State  = $state
            Reason = $j.waitingFor
            Name   = if ($j.name) { $j.name } else { $folder }
            Folder = $folder
            Age    = $age
            Since  = $since
            Unseen = $false    # finished since you last looked at it
            Took   = $null     # how long the turn that just finished ran
            # Desktop-app sessions can be opened with a deep link; terminal sessions cannot.
            Url    = if ($j.hostSessionId -match '^local_[A-Za-z0-9-]+$') { "claude://claude.ai/epitaxy/$($j.hostSessionId)" } else { $null }
            Pid    = [int]$j.pid
        }
    }
}

# Colour for a session: finished-and-already-seen sessions are dimmed.
function Get-Tone($s) { if ($s.State -eq 'done' -and -not $s.Unseen) { 'seen' } else { $s.State } }

function Get-Status($s) {
    switch ($s.State) {
        'busy'    { "In progress $([char]0xB7) $($s.Age)" }
        'waiting' {
            $why = if ($s.Reason) { $s.Reason.Substring(0, 1).ToUpper() + $s.Reason.Substring(1) } else { 'Waiting for you' }
            "$why $([char]0xB7) $($s.Age)"
        }
        default   { "$(if ($s.Unseen) { 'Finished' } else { 'Done' }) $([char]0xB7) $($s.Age)" }
    }
}

function Get-AlertStatus($s) {
    if ($s.State -eq 'waiting') { 'Needs you' + $(if ($s.Reason) { " $([char]0xB7) $($s.Reason)" }) }
    else { 'Finished' + $(if ($s.Took) { " in $($s.Took)" }) }
}

function New-Dot($tone) {
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 8; $dot.Height = 8
    $dot.VerticalAlignment = 'Center'
    $dot.Fill = $brushes.ConvertFromString($(if ($colors[$tone]) { $colors[$tone] } else { '#555555' }))
    if ($tone -eq 'seen') { $dot.Fill = $brushes.ConvertFromString($colors.done); $dot.Opacity = 0.35 }
    if ($tone -in 'waiting', 'busy') {
        $pulse = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.25, [TimeSpan]::FromMilliseconds(700))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $pulse)
    }
    $dot
}

function New-Text($text, $color, $margin) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text
    $t.Foreground = $brushes.ConvertFromString($color)
    $t.Margin = $margin
    $t.VerticalAlignment = 'Center'
    $t
}

# One session entry. Two-line: name, then project and status underneath. One-line: all in a row.
# Clicking it marks the session as seen and opens it in the Claude desktop app.
function New-Row($s, $status) {
    $tone = Get-Tone $s
    $dot  = New-Dot $tone
    $name = New-Text $s.Name $(if ($tone -eq 'seen') { '#B8B8B8' } else { '#FFFFFF' }) '0'
    $name.TextTrimming = 'CharacterEllipsis'
    $row = New-Object Windows.Controls.DockPanel
    [Windows.Controls.DockPanel]::SetDock($dot, 'Left')

    if ($settings.TwoLine) {
        $row.Width = 340
        $dot.VerticalAlignment = 'Top'
        $dot.Margin = '0,5,0,0'
        [void]$row.Children.Add($dot)

        $sub = New-Object Windows.Controls.TextBlock
        $sub.FontSize = 11
        $sub.Margin = '0,1,0,0'
        $sub.TextTrimming = 'CharacterEllipsis'
        $project = New-Object Windows.Documents.Run "$($s.Folder)  $([char]0xB7)  "
        $project.Foreground = $brushes.ConvertFromString('#8A8A8A')
        $state = New-Object Windows.Documents.Run $status
        $state.Foreground = $brushes.ConvertFromString($colors[$tone])
        [void]$sub.Inlines.Add($project)
        [void]$sub.Inlines.Add($state)

        $text = New-Object Windows.Controls.StackPanel
        $text.Margin = '10,0,0,0'
        [void]$text.Children.Add($name)
        [void]$text.Children.Add($sub)
        [void]$row.Children.Add($text)
    } else {
        $row.Width = 420
        $right = New-Text $status $colors[$tone] '12,0,0,0'
        [Windows.Controls.DockPanel]::SetDock($right, 'Right')
        [void]$row.Children.Add($right)
        [void]$row.Children.Add($dot)
        $project = New-Text $s.Folder '#8A8A8A' '10,0,0,0'
        $project.MaxWidth = 120
        $project.TextTrimming = 'CharacterEllipsis'
        [Windows.Controls.DockPanel]::SetDock($project, 'Right')
        [void]$row.Children.Add($project)
        $name.Margin = '8,0,0,0'
        [void]$row.Children.Add($name)
    }

    $item = New-Object Windows.Controls.Border
    $item.Child = $row
    $item.Padding = '8,4,8,4'
    $item.CornerRadius = 10
    $item.Background = [Windows.Media.Brushes]::Transparent
    $item.ToolTip = "$($s.Name)  ($($s.Folder))"
    $item.Tag = $s
    $item.Cursor = [Windows.Input.Cursors]::Hand
    $item.Add_MouseEnter({ $this.Background = $brushes.ConvertFromString('#2A2A2A') })
    $item.Add_MouseLeave({ $this.Background = [Windows.Media.Brushes]::Transparent })
    $item.Add_MouseLeftButtonUp({
        $seen = $script:info[$this.Tag.Id]
        if ($seen) { $seen.Unseen = $false }
        $script:lastSignature = $null
        if ($this.Tag.Url) { Start-Process $this.Tag.Url } else { Show-Terminal $this.Tag.Pid }
    })
    $item
}

# Brings a CLI session's terminal to the front: walks up from the claude process to the first
# ancestor that owns a window (Windows Terminal, the console host, VS Code, ...). It can't pick
# the right tab inside that window.
function Show-Terminal($procId) {
    $procs = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue) { $procs[[int]$p.ProcessId] = $p }
    $id = $procId
    for ($hop = 0; $hop -lt 8 -and $id -and $procs[$id]; $hop++) {
        $hwnd = try { (Get-Process -Id $id -ErrorAction Stop).MainWindowHandle } catch { [IntPtr]::Zero }
        if ($hwnd -ne [IntPtr]::Zero) {
            if ([BotBar.Native]::IsIconic($hwnd)) { [void][BotBar.Native]::ShowWindow($hwnd, 9) }   # SW_RESTORE
            [void][BotBar.Native]::SetForegroundWindow($hwnd)
            return
        }
        $id = [int]$procs[$id].ParentProcessId
    }
}

function Play-Sound($state) {
    if (-not $settings.Sound) { return }
    try { $players[$state].Play() } catch {}
}

# --- Animation ---
$easeOut = New-Object Windows.Media.Animation.ExponentialEase
$easeOut.Exponent = 5
function Move-To($target, $property, $to, $ms) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation ([double]$to), ([TimeSpan]::FromMilliseconds($ms))
    $a.EasingFunction = $easeOut
    $target.BeginAnimation($property, $a)
}

# Each panel sits at full size inside a clipped box. Opening grows the box to fit while the
# content fades in, so the notch widens smoothly and the text never stretches or reflows.
# -Refit resizes an already-open box after its rows changed.
function Set-Open($panel, $open, [switch]$Refit) {
    $box = $panel.Parent.Parent
    $open = [bool]$open
    $changed = [bool]$box.Tag -ne $open
    if (-not $changed -and -not ($Refit -and $open)) { return }
    $box.Tag = $open
    $w = 0; $h = 0
    if ($open) {
        $panel.Measure((New-Object Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
        $w = $panel.DesiredSize.Width; $h = $panel.DesiredSize.Height
        [Windows.Controls.Canvas]::SetLeft($panel, -$w / 2)
    }
    $ms = if ($open) { 420 } else { 300 }
    Move-To $box ([Windows.FrameworkElement]::WidthProperty) $w $ms
    Move-To $box ([Windows.FrameworkElement]::HeightProperty) $h $ms
    if ($changed) { Move-To $panel ([Windows.UIElement]::OpacityProperty) ([int]$open) $(if ($open) { 380 } else { 160 }) }
}
$alertsPanel.Opacity = 0
$details.Opacity = 0

$script:lastSignature = $null
$script:info   = @{}    # session id -> @{ State; TurnStart; Unseen }, remembered between refreshes
$script:alerts = @()    # sessions that just finished or started waiting, shown for a few seconds
$script:active = 0      # sessions in progress or waiting
$script:unseen = 0      # sessions that finished and have not been looked at
$script:lastActivity = Get-Date
function Update-Bar {
    $all = @(Get-Sessions)
    $now = Get-Date

    $present = @{}
    foreach ($s in $all) {
        $present[$s.Id] = $true
        $i = $script:info[$s.Id]
        if (-not $i) {
            $i = @{ State = $s.State; TurnStart = $(if ($s.State -ne 'done') { $s.Since }); Unseen = $false }
            $script:info[$s.Id] = $i
        } else {
            if ($s.State -eq 'busy') {
                if ($i.State -eq 'done') { $i.TurnStart = $s.Since }
                $i.Unseen = $false
            }
            if ($i.State -ne $s.State -and $s.State -ne 'busy') {
                if ($s.State -eq 'done') {
                    $i.Unseen = $true
                    if ($i.TurnStart) { $s.Took = Format-Span ($s.Since - $i.TurnStart) }
                }
                $s.Unseen = $i.Unseen
                $script:alerts = @($script:alerts | Where-Object { $_.Session.Id -ne $s.Id }) + @{ Session = $s; Until = $now.AddSeconds($alertSeconds) }
                Play-Sound $s.State
            }
            $i.State = $s.State
        }
        $s.Unseen = $i.Unseen
    }
    foreach ($id in @($script:info.Keys)) { if (-not $present[$id]) { $script:info.Remove($id) } }

    $script:alerts = @($script:alerts | Where-Object { $_.Until -gt $now })
    $script:active = @($all | Where-Object State -ne 'done').Count
    $script:unseen = @($all | Where-Object Unseen).Count

    # Activity = something running or waiting right now, or the most recent status change.
    if ($script:active -gt 0 -or $script:alerts) { $script:lastActivity = $now }
    else {
        $latest = ($all | Measure-Object Since -Maximum).Maximum
        if ($latest) {
            $changed = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$latest).LocalDateTime
            if ($changed -gt $script:lastActivity) { $script:lastActivity = $changed }
        }
    }

    $sessions = @($all | Where-Object { $settings.ShowDone -or $_.State -ne 'done' } |
        Sort-Object @{ Expression = { $order.IndexOf($_.State) } }, @{ Expression = 'Since'; Descending = $true })
    $signature = (@($sessions | ForEach-Object { "$($_.State)|$($_.Unseen)|$($_.Name)|$($_.Age)|$($_.Reason)" }) +
                  @($script:alerts | ForEach-Object { "alert|$($_.Session.Id)|$($_.Session.State)" })) -join "`n"
    if ($signature -eq $script:lastSignature) { return }
    $script:lastSignature = $signature

    # Alert rows are left in place while the panel closes, so it can animate shut.
    if ($script:alerts) {
        $alertsPanel.Children.Clear()
        foreach ($a in $script:alerts) { [void]$alertsPanel.Children.Add((New-Row $a.Session (Get-AlertStatus $a.Session))) }
    }

    $summary.Children.Clear()
    $details.Children.Clear()

    if (-not $sessions) {
        [void]$summary.Children.Add((New-Dot 'none'))
        $text = if ($settings.ShowDone) { 'No Claude sessions' } else { 'Nothing in progress' }
        [void]$details.Children.Add((New-Text $text '#888888' '8,0,8,6'))
    } elseif ($sessions.Count -le $maxDots) {
        # One dot per session, in the same order as the list.
        foreach ($s in $sessions) {
            $dot = New-Dot (Get-Tone $s)
            $dot.Margin = '4,4,4,4'
            [void]$summary.Children.Add($dot)
        }
    } else {
        foreach ($state in $order) {
            $count = @($sessions | Where-Object State -eq $state).Count
            if (-not $count) { continue }
            $chip = New-Object Windows.Controls.StackPanel
            $chip.Orientation = 'Horizontal'
            $chip.Margin = '6,0,6,0'
            [void]$chip.Children.Add((New-Dot $state))
            [void]$chip.Children.Add((New-Text $count '#FFFFFF' '6,0,0,0'))
            [void]$summary.Children.Add($chip)
        }
    }

    foreach ($s in $sessions) { [void]$details.Children.Add((New-Row $s (Get-Status $s))) }

    Set-Open $alertsPanel $script:alerts -Refit
    Set-Open $details $detailsBox.Tag -Refit
}

# --- Placement ---
function Get-Screen {
    $all = [System.Windows.Forms.Screen]::AllScreens
    $match = $all | Where-Object DeviceName -eq $settings.Monitor | Select-Object -First 1
    if ($match) { $match } else { [System.Windows.Forms.Screen]::PrimaryScreen }
}

function Get-Scale {   # screen pixels per WPF unit
    $source = [Windows.PresentationSource]::FromVisual($window)
    if ($source) { $source.CompositionTarget.TransformToDevice.M11 } else { 1 }
}

# Put the window at $winLeft with the pill anchored $anchor units from the window's left edge.
# Anchor in the middle = grows evenly both ways; at an edge = grows away from that edge.
function Set-Anchor($winLeft, $anchor) {
    $anchor = [math]::Max(0, [math]::Min($windowWidth, $anchor))
    $window.Left = $winLeft
    $padLeft.Width  = New-Object Windows.GridLength $anchor, ([Windows.GridUnitType]::Star)
    $padRight.Width = New-Object Windows.GridLength ($windowWidth - $anchor), ([Windows.GridUnitType]::Star)
}

# Centre the pill on $centre, keeping the whole window on the monitor that spans $left..$left+$width.
function Set-Centre($centre, $left, $width) {
    $winLeft = [math]::Max($left, [math]::Min($left + $width - $windowWidth, $centre - $windowWidth / 2))
    Set-Anchor $winLeft ($centre - $winLeft)
}

# Position is Left / Center / Right, or Custom with Offset = where the notch's centre sits
# across the monitor (0 to 1).
function Set-Position {
    if ($script:dragging) { return }
    $scale = Get-Scale
    $b = (Get-Screen).Bounds
    $left = $b.X / $scale; $width = $b.Width / $scale; $edge = 48
    $window.Top = $b.Y / $scale
    switch ($settings.Position) {
        'Left'   { Set-Anchor ($left + $edge) 0 }
        'Right'  { Set-Anchor ($left + $width - $edge - $windowWidth) $windowWidth }
        'Custom' { Set-Centre ($left + $width * $settings.Offset) $left $width }
        default  { Set-Centre ($left + $width / 2) $left $width }
    }
}

# True when the foreground window covers the notch's whole monitor (a game, a fullscreen video).
# A maximised window does not count: it stops at the taskbar.
function Test-Fullscreen {
    $hwnd = [BotBar.Native]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $class = New-Object System.Text.StringBuilder 64
    [void][BotBar.Native]::GetClassName($hwnd, $class, 64)
    if ("$class" -in 'Progman', 'WorkerW', 'Shell_TrayWnd') { return $false }   # the desktop itself
    $r = New-Object BotBar.Native+RECT
    if (-not [BotBar.Native]::GetWindowRect($hwnd, [ref]$r)) { return $false }
    $b = (Get-Screen).Bounds
    $r.Left -le $b.Left -and $r.Top -le $b.Top -and $r.Right -ge $b.Right -and $r.Bottom -ge $b.Bottom
}

# Tucking: the notch narrows and slides up off the top edge of the screen (and back down).
$squeeze = New-Object Windows.Media.ScaleTransform
$slide   = New-Object Windows.Media.TranslateTransform
$tuck    = New-Object Windows.Media.TransformGroup
$tuck.Children.Add($squeeze); $tuck.Children.Add($slide)
$pill.RenderTransform = $tuck
$pill.RenderTransformOrigin = '0.5,0'
$script:tucked = $false
function Set-Tucked($away) {
    if ($script:tucked -eq $away) { return }
    $script:tucked = $away
    $time = [TimeSpan]::FromMilliseconds($(if ($away) { 450 } else { 220 }))
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = if ($away) { 'EaseIn' } else { 'EaseOut' }
    $y = New-Object Windows.Media.Animation.DoubleAnimation ($(if ($away) { -($pill.ActualHeight + 4) } else { 0 })), $time
    $x = New-Object Windows.Media.Animation.DoubleAnimation ($(if ($away) { 0.3 } else { 1 })), $time
    $y.EasingFunction = $ease; $x.EasingFunction = $ease
    $slide.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $y)
    $squeeze.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $x)
}

# Hidden under fullscreen apps; small and dim while nothing is in progress, waiting or unseen;
# tucked away entirely once nothing has happened for a while. Hovering always brings it back.
$script:hidden = $false
$script:faded = $false
function Update-Look {
    $fullscreen = -not $menu.IsOpen -and (Test-Fullscreen)
    $script:hidden = $settings.HideFullscreen -and $fullscreen
    $window.Opacity = if ($script:hidden) { 0 } else { 1 }
    # A fullscreen app that takes the foreground can end up above us even though we are topmost
    # (setting Topmost again is a no-op in WPF), so push back to the top of the topmost band.
    if ($fullscreen -and -not $script:hidden) {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        # HWND_TOPMOST; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
        [void][BotBar.Native]::SetWindowPos($hwnd, [IntPtr]::new(-1), 0, 0, 0, 0, 0x13)
    }
    $resting = $script:active -eq 0 -and $script:unseen -eq 0 -and -not $script:alerts -and
               -not $detailsBox.Tag -and -not $menu.IsOpen -and -not $script:dragging
    $faded = [bool]($settings.FadeIdle -and $resting)
    if ($faded -ne $script:faded) {
        $script:faded = $faded
        Move-To $pill ([Windows.UIElement]::OpacityProperty) $(if ($faded) { 0.45 } else { 1 }) 300
        $to = if ($faded) { New-Object Windows.Thickness 10, 2, 10, 3 } else { New-Object Windows.Thickness 18, 5, 18, 7 }
        $pad = New-Object Windows.Media.Animation.ThicknessAnimation $to, ([TimeSpan]::FromMilliseconds(300))
        $pad.EasingFunction = $easeOut
        $pill.BeginAnimation([Windows.Controls.Border]::PaddingProperty, $pad)
    }

    # BOTBAR_TUCK_SECONDS shortens the wait, for testing.
    $limit = if ($env:BOTBAR_TUCK_SECONDS) { [double]$env:BOTBAR_TUCK_SECONDS } else { 60 * $settings.HideAfterMinutes }
    Set-Tucked ($resting -and $limit -gt 0 -and ((Get-Date) - $script:lastActivity).TotalSeconds -ge $limit)
}

# --- Dragging: slide along the top edge of any monitor ---
$script:dragStart = $null
$script:dragging = $false
$pill.Add_MouseLeftButtonDown({ if (-not $settings.Locked) { $script:dragStart = [System.Windows.Forms.Cursor]::Position } })
$pill.Add_MouseMove({
    if (-not $script:dragStart) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    if (-not $script:dragging) {
        if ($_.LeftButton -ne 'Pressed') { $script:dragStart = $null; return }
        if ([math]::Abs($c.X - $script:dragStart.X) + [math]::Abs($c.Y - $script:dragStart.Y) -lt 6) { return }
        # Capturing the mouse also keeps the release from counting as a click on a session row.
        $script:dragging = $true
        Set-Open $details $false
        [void]$pill.CaptureMouse()
    }
    $scale = Get-Scale
    $b = [System.Windows.Forms.Screen]::FromPoint($c).Bounds
    $window.Top = $b.Y / $scale
    Set-Centre ($c.X / $scale) ($b.X / $scale) ($b.Width / $scale)
})
$pill.Add_MouseLeftButtonUp({
    $script:dragStart = $null
    if (-not $script:dragging) { return }
    $script:dragging = $false
    $pill.ReleaseMouseCapture()
    $c = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($c)
    $b = $screen.Bounds
    $settings.Monitor = $screen.DeviceName
    $settings.Position = 'Custom'
    $settings.Offset = [math]::Round([math]::Max(0, [math]::Min(1, ($c.X - $b.X) / $b.Width)), 4)
    Save-Settings
    Set-Position
})

# --- Right-click menu ---
function Add-MenuItem($parent, $header, $checked, $action) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $header
    $item.IsChecked = [bool]$checked
    if ($action) { $item.Add_Click($action) }
    [void]$parent.Items.Add($item)
    $item
}

# A ticked menu entry that flips one on/off setting.
function Add-Toggle($header, $key) {
    $item = Add-MenuItem $menu $header $settings[$key] {
        $settings[$this.Tag] = -not $settings[$this.Tag]
        Save-Settings
        $script:lastSignature = $null
        Update-Bar
    }
    $item.Tag = $key
}

$preview = New-Object Windows.Threading.DispatcherTimer
$preview.Interval = [TimeSpan]::FromMilliseconds(1500)
$preview.Add_Tick({ $preview.Stop(); try { $players.waiting.Play() } catch {} })

function Build-Menu {
    $menu.Items.Clear()

    if ($script:unseen) {
        [void](Add-MenuItem $menu 'Mark all as seen' $false {
            foreach ($i in $script:info.Values) { $i.Unseen = $false }
            $script:lastSignature = $null
            Update-Bar
        })
        [void]$menu.Items.Add((New-Object Windows.Controls.Separator))
    }

    $snap = Add-MenuItem $menu 'Snap to'
    foreach ($p in 'Left', 'Center', 'Right') {
        $item = Add-MenuItem $snap $p ($settings.Position -eq $p) { $settings.Position = $this.Tag; Save-Settings; Set-Position }
        $item.Tag = $p
    }
    Add-Toggle 'Lock position' 'Locked'
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))

    Add-Toggle 'Show completed sessions' 'ShowDone'
    Add-Toggle 'Two-line rows' 'TwoLine'
    Add-Toggle 'Shrink and dim when idle' 'FadeIdle'
    $full = Add-MenuItem $menu 'Fullscreen apps'
    foreach ($hide in $true, $false) {
        $label = if ($hide) { 'Hide under them' } else { 'Show on top of them' }
        $item = Add-MenuItem $full $label ($settings.HideFullscreen -eq $hide) { $settings.HideFullscreen = $this.Tag; Save-Settings; Update-Look }
        $item.Tag = $hide
    }
    $away = Add-MenuItem $menu 'Slide away when idle'
    foreach ($m in 0, 5, 10) {
        $label = if ($m) { "After $m minutes" } else { 'Never' }
        $item = Add-MenuItem $away $label ($settings.HideAfterMinutes -eq $m) { $settings.HideAfterMinutes = $this.Tag; Save-Settings }
        $item.Tag = $m
    }
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))

    Add-Toggle 'Play a sound on alerts' 'Sound'
    [void](Add-MenuItem $menu 'Preview sounds' $false { try { $players.done.Play() } catch {}; $preview.Start() })
    [void](Add-MenuItem $menu 'Start with Windows' (Test-Path $startupLink) {
        if (Test-Path $startupLink) { Remove-Item $startupLink }
        else {
            $link = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLink)
            $link.TargetPath = 'wscript.exe'
            $link.Arguments = '"{0}"' -f (Join-Path $PSScriptRoot 'BotBar.vbs')
            $link.Save()
        }
    })
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))
    [void](Add-MenuItem $menu 'Exit BotBar' $false { $window.Close() })
}

# Activating the window lets the menu notice clicks elsewhere and close itself.
$menu.Add_Opened({ Build-Menu; [void]$window.Activate() })

# Expand while the cursor is over the notch. Polled rather than MouseEnter/Leave, which
# fire spuriously while the notch resizes under the cursor and make it flicker.
$hover = New-Object Windows.Threading.DispatcherTimer
$hover.Interval = [TimeSpan]::FromMilliseconds(40)
$hover.Add_Tick({
    if ($menu.IsOpen -or $script:dragging) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    $p = $slot.PointFromScreen((New-Object Windows.Point $c.X, $c.Y))
    # A little slack around the notch so the small idle version is still easy to hit.
    $slack = 12
    $over = -not $script:hidden -and $p.X -ge -$slack -and $p.Y -ge 0 -and
            $p.X -le $slot.ActualWidth + $slack -and $p.Y -le $slot.ActualHeight + $slack
    if ([bool]$detailsBox.Tag -ne $over) { Set-Open $details $over; Update-Look }
})
$window.Add_ContentRendered({ Set-Position; $hover.Start() })

# Tool window: stays out of Alt-Tab.
$window.Add_SourceInitialized({
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    $style = [BotBar.Native]::GetWindowLong($hwnd, -20)
    [void][BotBar.Native]::SetWindowLong($hwnd, -20, $style -bor 0x80)
    Set-Position
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Update-Bar; Update-Look; if (-not $menu.IsOpen) { $window.Topmost = $true } })
$timer.Start()

Update-Bar
Update-Look
[void]$window.ShowDialog()
$timer.Stop()
$hover.Stop()
$mutex.ReleaseMutex()
