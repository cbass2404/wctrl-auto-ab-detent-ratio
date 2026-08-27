<#
    config-manager-gui.ps1 - the ratio editor window.

    Not the file to run: double-click launch-config-manager.cmd instead.
    Windows does not execute .ps1 on double-click, and this needs to be
    started with the right execution policy and on an STA thread.

    Launched by launch-config-manager.cmd. A small WinForms window: the table,
    add / edit / delete, and Activate to push a ratio to the throttle right now.

    config.json in this folder is the source of truth for ratios. SimAppPro is
    needed exactly once, to calibrate the afterburner detent, and is never read
    or written here - it is an Electron app that rewrites its whole config from
    memory, so anything written behind its back is silently discarded.

    Only the "ratios" array is rewritten on save; the comments and every other
    setting in config.json are left byte-for-byte alone.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$configPath = Join-Path $scriptDir 'config.json'
$statePath  = Join-Path $scriptDir 'state.json'
$baseName   = 'wctrl-auto-ab-detent-ratio'
$repoSlug   = 'cbass2404/wctrl-auto-ab-detent-ratio'

# This script lives in <install>\lib, so the version-stamped name is on the
# parent. A repo checkout has the same shape with an unversioned parent, which
# correctly reports 'dev'.
$installDir = Split-Path -Parent $scriptDir
$version = $(
    $leaf = Split-Path -Leaf $installDir
    if ($leaf -like "$baseName-*") { $leaf.Substring($baseName.Length + 1) } else { 'dev' }
)

# ------------------------------------------------------------------ config --

function Read-Config {
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "config.json not found next to this script:`n$configPath"
    }
    try { return (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) }
    catch { throw "config.json is not valid JSON:`n$($_.Exception.Message)" }
}

function Write-ConfigRatios {
    <#
        Replace only the "ratios" array, by locating its span and splicing. A
        ConvertTo-Json round-trip would reflow the file and throw away the
        _comment_ keys that document every setting.
    #>
    param([Parameter(Mandatory)][array]$Ratios)

    $raw = [IO.File]::ReadAllText($configPath)
    $m = [regex]::Match($raw, '"ratios"\s*:\s*\[')
    if (-not $m.Success) { throw 'config.json has no "ratios" array.' }

    $open = $m.Index + $m.Length - 1
    $depth = 0; $inStr = $false; $esc = $false; $end = -1
    for ($i = $open; $i -lt $raw.Length; $i++) {
        $c = $raw[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '[') { $depth++; continue }
        if ($c -eq ']') { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { throw 'config.json: the "ratios" array is not terminated.' }

    if ($Ratios.Count -eq 0) {
        $body = '[]'
    } else {
        $rows = $Ratios | ForEach-Object {
            '        {{ "name": {0,-9} "ratio": {1} }}' -f ('"' + $_.name + '",'), [int]$_.ratio
        }
        $body = "[" + [Environment]::NewLine + ($rows -join ("," + [Environment]::NewLine)) + [Environment]::NewLine + "    ]"
    }

    $updated = $raw.Substring(0, $open) + $body + $raw.Substring($end + 1)
    [void]($updated | ConvertFrom-Json)   # never write something we cannot read back

    $tmp = "$configPath.tmp"
    [IO.File]::WriteAllText($tmp, $updated, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $configPath -Force
}

# ------------------------------------------------------------------- state --

function Read-State {
    <#
        What DCS last reported, written by helper.ps1. Absent, unreadable or
        null all mean the same thing - nothing is detected - because the helper
        may simply not be running, which is the normal case when someone opens
        this to edit their table.

        Note that 'at' does not come back as the string on disk: ConvertFrom-Json
        hydrates an ISO-8601 value into a [DateTime], with Kind = Utc because the
        helper writes a trailing Z. That is the useful form, so a staleness check
        can subtract it from [DateTime]::UtcNow directly. Nothing reads it today.
    #>
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try {
        $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $d = $s.lastDetectedAircraft
        if (-not $d -or [string]::IsNullOrWhiteSpace([string]$d.name)) { return $null }
        return $d
    } catch { return $null }
}

function Clear-DetectedAircraft {
    <#
        Activate forces a ratio by hand, so the throttle stops reflecting a
        detected module and nothing should look live. Same reasoning as
        helper.ps1 -Apply.

        Written whole rather than spliced: state.json is machine-owned, so there
        is no formatting to preserve. Silent on failure - the helper rewrites it
        on the next detection either way.
    #>
    try {
        $tmp = "$statePath.tmp"
        [IO.File]::WriteAllText($tmp, '{' + [Environment]::NewLine +
            '    "lastDetectedAircraft": null' + [Environment]::NewLine + '}',
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $statePath -Force
    } catch { }
}

# ------------------------------------------------------------------ device --

. (Join-Path $scriptDir 'WinctrlHid.ps1')

function Use-Throttle {
    <# Open the throttle, run a scriptblock, always close. $null if not found. #>
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)]$Config)

    $filters = @($Config.deviceNameIncludes | Where-Object { $_ })
    foreach ($dev in @(Get-WinctrlDevice -ProductId ([int]$Config.throttlePid))) {
        if ($filters.Count -gt 0) {
            $upper = ([string]$dev.Product).ToUpperInvariant()
            $ok = $false
            foreach ($f in $filters) { if ($upper.Contains(([string]$f).ToUpperInvariant())) { $ok = $true; break } }
            if (-not $ok) { continue }
        }
        $hid = $null
        try { $hid = Open-WinctrlDevice -Device $dev } catch { continue }
        try {
            $part = Get-WinctrlParts -Hid $hid | Where-Object HasAfterburner | Select-Object -First 1
            if ($part) { return (& $Action $hid $part $dev) }
        } finally { if ($hid) { $hid.Dispose() } }
    }
    return $null
}

function Get-CurrentRatio {
    param($Config)
    return Use-Throttle -Config $Config -Action {
        param($hid, $part, $dev)
        [pscustomobject]@{
            Percent = Get-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId
            Device  = $dev.Product
        }
    }
}

function Clear-CurrentRatio {
    <# Writes FF FF FF FF - the device's "Inactivated" state, no afterburner
       mapping at all. Does not disturb the detent calibration. #>
    param($Config)
    return Use-Throttle -Config $Config -Action {
        param($hid, $part, $dev)
        # Return a marker, not the read-back ratio. A cleared device reports
        # Inactivated, which reads back as $null - the same value Use-Throttle
        # uses for "no throttle found", so returning it made every successful
        # clear look like a failure.
        [void](Set-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId -Clear)
        return [pscustomobject]@{ Cleared = $true }
    }
}

function Set-CurrentRatio {
    param($Config, [int]$Percent)
    return Use-Throttle -Config $Config -Action {
        param($hid, $part, $dev)
        Set-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId -Percent $Percent
    }
}

# ------------------------------------------------------------ update check --

function Get-LatestRelease {
    <#
        Ask GitHub for the newest release. /releases/latest deliberately skips
        pre-releases, and this project ships alphas, so take the newest
        non-draft from the full list instead. Never throws: an offline user
        should see nothing at all.
    #>
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/releases?per_page=10" `
                               -Headers @{ 'User-Agent' = $baseName; 'Accept' = 'application/vnd.github+json' } `
                               -TimeoutSec 6
        $newest = @($r | Where-Object { -not $_.draft }) | Select-Object -First 1
        if (-not $newest) { return $null }
        return [pscustomobject]@{ Tag = [string]$newest.tag_name; Url = [string]$newest.html_url }
    } catch { return $null }
}

function ConvertTo-VersionParts {
    # "v1.2.3-alpha" -> @{ Nums=@(1,2,3); Pre='alpha' }
    param([string]$Text)
    $t = ([string]$Text).Trim() -replace '^[vV](?=\d)', ''
    $pre = ''
    if ($t -match '^([0-9.]+)-(.+)$') { $nums = $Matches[1]; $pre = $Matches[2] }
    elseif ($t -match '^([0-9.]+)$')  { $nums = $Matches[1] }
    else { return $null }
    return @{ Nums = @($nums.Split('.') | ForEach-Object { [int]$_ }); Pre = $pre }
}

function Test-IsNewer {
    <# Semver-ish: compare numbers, then treat a pre-release as older than the
       same numbers without one. Returns $false if either side is unparseable. #>
    param([string]$Candidate, [string]$Current)
    $a = ConvertTo-VersionParts $Candidate
    $b = ConvertTo-VersionParts $Current
    if (-not $a -or -not $b) { return $false }

    $len = [Math]::Max($a.Nums.Count, $b.Nums.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $a.Nums.Count) { $a.Nums[$i] } else { 0 }
        $y = if ($i -lt $b.Nums.Count) { $b.Nums[$i] } else { 0 }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    if ($a.Pre -eq '' -and $b.Pre -ne '') { return $true }    # 1.0.0 beats 1.0.0-alpha
    if ($a.Pre -ne '' -and $b.Pre -eq '') { return $false }
    if ($a.Pre -eq $b.Pre) { return $false }

    # Pre-release identifiers compare dot by dot, not as one string: comparing
    # "alpha.10" against "alpha.2" as text puts 10 before 2, so an update past
    # .9 would never be offered. Numeric parts compare numerically, a numeric
    # part ranks below an alphanumeric one, and if all shared parts match the
    # longer identifier list wins.
    $ap = $a.Pre.Split('.')
    $bp = $b.Pre.Split('.')
    for ($i = 0; $i -lt [Math]::Max($ap.Count, $bp.Count); $i++) {
        if ($i -ge $ap.Count) { return $false }   # b has more parts, so b is newer
        if ($i -ge $bp.Count) { return $true }
        $x = $ap[$i]; $y = $bp[$i]
        $xn = 0; $yn = 0
        $xIsNum = [int]::TryParse($x, [ref]$xn)
        $yIsNum = [int]::TryParse($y, [ref]$yn)
        if ($xIsNum -and $yIsNum) {
            if ($xn -ne $yn) { return ($xn -gt $yn) }
        } elseif ($xIsNum -ne $yIsNum) {
            return (-not $xIsNum)                 # numeric ranks below alphanumeric
        } else {
            $c = [string]::Compare($x, $y, $true)
            if ($c -ne 0) { return ($c -gt 0) }
        }
    }
    return $false
}

# --------------------------------------------------------------------- UI ---

$cfg     = Read-Config
$ratios  = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList
foreach ($r in @($cfg.ratios)) {
    if (-not $r.name) { continue }
    # A hand-edited ratio outside a whole 0..100 is left out of the table rather
    # than shown: the throttle refuses it, so a row you can see and select but
    # cannot apply would be worse than one that is plainly not there.
    $n = 0
    if ([int]::TryParse([string]$r.ratio, [ref]$n) -and $n -ge 0 -and $n -le 100) {
        [void]$ratios.Add([pscustomobject]@{ name = [string]$r.name; ratio = $n })
    } else {
        [void]$skipped.Add("$($r.name) = $($r.ratio)")
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Afterburner detent ratios  -  v$version"
# Same file the Start Menu shortcut points at, so the window and the entry that
# opened it match in the taskbar. A missing icon is not worth failing over.
$iconPath = Join-Path $scriptDir 'app.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon $iconPath } catch { }
}
$form.Size = New-Object System.Drawing.Size(560, 560)
$form.StartPosition = 'CenterScreen'
# Raised by the same 16px the list and the button column moved down for the
# "Last detected" label, so shrinking to the minimum leaves exactly the gap
# between Refresh and Save that it always had.
$form.MinimumSize = New-Object System.Drawing.Size(480, 476)

$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Location = New-Object System.Drawing.Point(12, 12)
$lblDevice.Size = New-Object System.Drawing.Size(520, 34)
$lblDevice.Text = 'Looking for your throttle...'
$lblDevice.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblDevice)

$lblDetected = New-Object System.Windows.Forms.Label
$lblDetected.Location = New-Object System.Drawing.Point(12, 48)
$lblDetected.Size = New-Object System.Drawing.Size(520, 18)
$lblDetected.Text = 'Last detected: none'
$lblDetected.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblDetected)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(12, 70)
$list.Size = New-Object System.Drawing.Size(400, 364)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.MultiSelect = $false
# No grid lines: the Win32 header draws its column divider on the last pixel of
# the column while the item area draws its line one pixel further right, in a
# lighter shade, so the two never line up. Only owner-drawing the whole control
# would fix that, which is not worth reimplementing selection and the active-row
# highlight for. The header dividers alone read fine.
$list.GridLines = $false
$list.HideSelection = $false
$list.Anchor = 'Top,Left,Bottom,Right'
[void]$list.Columns.Add('Aircraft', 250)
[void]$list.Columns.Add('Ratio %', 110)

# Owner-drawn, for two reasons the stock painter cannot cover:
#
#   * GridLines draws its vertical lines one pixel right of the header's own
#     column dividers, and in a lighter shade, so the two never line up.
#     Painting the rows here means horizontal separators without that mismatch.
#   * The header has no bottom edge - the first row butts straight up against
#     it - so it needs one drawn.
#
# DrawDefault is no use for either: the system paints after the handler returns
# and would cover anything drawn here, so the row is painted in full.
$script:ruleColor   = [System.Drawing.Color]::FromArgb(229, 229, 229)
$script:headerColor = [System.Drawing.Color]::FromArgb(190, 190, 190)

$list.OwnerDraw = $true

$list.Add_DrawColumnHeader({
    param($sender, $e)
    $e.DrawBackground()
    $e.DrawText()
    $pen = New-Object System.Drawing.Pen $script:headerColor
    $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1)
    $pen.Dispose()
})

# Deliberately empty. The control repaints a single cell on mouse-over, raising
# DrawItem without raising DrawSubItem for every subitem in the same pass, so a
# row-wide fill here wipes out the text of cells that are not being redrawn -
# hovering a row made its ratio vanish. Each cell paints itself below instead.
$list.Add_DrawItem({ param($sender, $e) })

# One cell: its own background, its own text, its own slice of the separator.
$list.Add_DrawSubItem({
    param($sender, $e)
    $back = if ($e.Item.Selected) { [System.Drawing.SystemColors]::Highlight } else { $e.Item.BackColor }
    $fore = if ($e.Item.Selected) { [System.Drawing.SystemColors]::HighlightText } else { $e.Item.ForeColor }
    $brush = New-Object System.Drawing.SolidBrush $back
    $e.Graphics.FillRectangle($brush, $e.Bounds)
    $brush.Dispose()
    $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor
             [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $r = New-Object System.Drawing.Rectangle (
            ($e.Bounds.Left + 6), $e.Bounds.Top, ($e.Bounds.Width - 8), ($e.Bounds.Height - 1))
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $e.Item.Font, $r, $fore, $flags)
    $pen = New-Object System.Drawing.Pen $script:ruleColor
    $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1)
    $pen.Dispose()
})

function Update-ColumnFit {
    <#
        Give the leftover width to the name column so the two columns fill the
        list exactly - the fixed widths otherwise leave a headerless strip on
        the right. Re-entrant guard because setting a width raises Resize again.
    #>
    if ($script:fitting) { return }
    $script:fitting = $true
    try {
        $avail = $list.ClientSize.Width
        # A scrollbar eats into the client width; the last row hanging past the
        # bottom is the plainest way to know one is there.
        if ($list.Items.Count -gt 0 -and
            $list.Items[$list.Items.Count - 1].Bounds.Bottom -gt $list.ClientSize.Height) {
            $avail -= [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        }
        $w = $avail - $list.Columns[1].Width
        if ($w -ge 120) { $list.Columns[0].Width = $w }
    } finally { $script:fitting = $false }
}
$list.Add_Resize({ Update-ColumnFit })

$form.Controls.Add($list)

# What the throttle currently reports, and what DCS last told the helper it was
# flying. Both are needed: the device stores a percentage and not which aircraft
# produced it, so the percentage alone lit up every row sharing that number.
$script:currentPercent = $null
$script:detected       = $null

$script:activeBack = [System.Drawing.Color]::FromArgb(198, 239, 206)
$script:activeFore = [System.Drawing.Color]::FromArgb(0, 97, 0)

function Test-NameMatch {
    <#
        Case-insensitive containment in EITHER direction.

        Detected names come from DCS and are specific, so a broad "FA-18" entry
        has to light up for an "FA-18C_hornet" - the detected name contains the
        entry. The other direction covers a table split into precise variants: a
        detected "FA-18" should light up both "FA-18C" and "FA-18E", where the
        entry contains the detected name. "FA-18E" and "FA-18C" never match each
        other, because neither contains the other.
    #>
    param([string]$EntryUpper, [string]$DetectedUpper)
    if (-not $EntryUpper -or -not $DetectedUpper) { return $false }
    return $DetectedUpper.Contains($EntryUpper) -or $EntryUpper.Contains($DetectedUpper)
}

function Update-Highlight {
    <#
        Green means "this row is the one DCS is driving right now", and needs
        both halves to be true.

        The NAME must match what the helper recorded. The RATIO must be what is
        actually on the throttle. The ratio half is what picks a single row out
        of several that match the name: with FA-18 at 82 and FA-18C at 79 and an
        FA-18C_hornet detected, the helper applies 79 on longest-match, so only
        FA-18C goes green. Two name-matching rows at the SAME ratio both light
        up, which is honest - they are indistinguishable in outcome.

        With nothing detected, nothing is green. The device line above still
        reports the raw percentage, so what is physically on the throttle is
        never hidden.
    #>
    $detectedUp = if ($script:detected) { ([string]$script:detected.name).ToUpperInvariant() } else { '' }

    # NONE never matches by name, exactly as in Resolve-Ratio, so whether it is
    # live depends on nothing else having matched. That has to be known before
    # any row can be coloured.
    $anyNamed = $false
    foreach ($item in $list.Items) {
        $entryUp = ([string]$item.Text).ToUpperInvariant()
        if ($entryUp -ne 'NONE' -and (Test-NameMatch -EntryUpper $entryUp -DetectedUpper $detectedUp)) {
            $anyNamed = $true
            break
        }
    }

    foreach ($item in $list.Items) {
        $entryUp = ([string]$item.Text).ToUpperInvariant()
        $nameOk = if ($entryUp -eq 'NONE') {
            # The fallback is live only when a name was detected and nothing
            # else matched it, which is precisely when the helper used it.
            [bool]$detectedUp -and -not $anyNamed
        } else {
            Test-NameMatch -EntryUpper $entryUp -DetectedUpper $detectedUp
        }

        $isActive = $nameOk -and
                    ($null -ne $script:currentPercent) -and
                    ([string]$item.SubItems[1].Text -eq [string]$script:currentPercent)

        if ($isActive) {
            $item.BackColor = $script:activeBack
            $item.ForeColor = $script:activeFore
        } else {
            $item.BackColor = $list.BackColor
            $item.ForeColor = $list.ForeColor
        }
    }
}

function Update-DetectedLabel {
    if (-not $script:detected) {
        $lblDetected.ForeColor = [System.Drawing.Color]::DimGray
        $lblDetected.Text = 'Last detected: none (DCS not running)'
        return
    }
    $lblDetected.ForeColor = $script:activeFore
    $text = "Last detected: $($script:detected.name)"
    # A plain name hit is already obvious from the green row, so it adds nothing.
    # Anything else - the NONE fallback, or no NONE entry at all - is worth
    # spelling out, because then which row is green is not self-explanatory.
    $via = [string]$script:detected.via
    if ($via -and $via -notlike 'matched *') { $text += "   ($via)" }
    $lblDetected.Text = $text
}

function Update-List {
    <#
        -SelectIndex re-selects by position, -SelectName by name. Moves and the
        A-Z sort must use the index: they care about where a row landed, and a
        name lookup would pick the wrong row if two ever shared a name.
    #>
    param([string]$SelectName, [int]$SelectIndex = -1)
    $list.BeginUpdate()
    $list.Items.Clear()
    for ($i = 0; $i -lt $ratios.Count; $i++) {
        $r = $ratios[$i]
        $item = New-Object System.Windows.Forms.ListViewItem($r.name)
        [void]$item.SubItems.Add([string]$r.ratio)
        [void]$list.Items.Add($item)
        $hit = if ($SelectIndex -ge 0) { $i -eq $SelectIndex } else { $SelectName -and $r.name -eq $SelectName }
        if ($hit) { $item.Selected = $true; $item.EnsureVisible() }
    }
    Update-Highlight
    $list.EndUpdate()
    Update-ColumnFit
    Update-ButtonState
}

function New-Button {
    param([string]$Text, [int]$Y, [scriptblock]$OnClick, [string]$Tip)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point(424, $Y)
    $b.Size = New-Object System.Drawing.Size(108, 32)
    $b.Anchor = 'Top,Right'
    $b.Add_Click($OnClick)
    if ($Tip) { (New-Object System.Windows.Forms.ToolTip).SetToolTip($b, $Tip) }
    $form.Controls.Add($b)
    return $b
}

function Show-EntryDialog {
    <# Add/edit prompt. Returns a hashtable or $null if cancelled. #>
    param([string]$Name = '', [int]$Ratio = 75, [string]$Title = 'Add aircraft', [switch]$LockName)

    $d = New-Object System.Windows.Forms.Form
    $d.Text = $Title
    $d.Size = New-Object System.Drawing.Size(400, 268)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MinimizeBox = $false; $d.MaximizeBox = $false

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Aircraft name (matched inside the DCS name):'
    $l1.Location = New-Object System.Drawing.Point(12, 14)
    $l1.Size = New-Object System.Drawing.Size(360, 18)
    $d.Controls.Add($l1)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Name
    $tb.Location = New-Object System.Drawing.Point(12, 34)
    $tb.Size = New-Object System.Drawing.Size(360, 24)
    $d.Controls.Add($tb)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'e.g. FA-18 matches FA-18C_hornet.   NONE = fallback for anything unmatched.'
    $l2.Location = New-Object System.Drawing.Point(12, 62)
    $l2.Size = New-Object System.Drawing.Size(360, 34)
    $l2.ForeColor = [System.Drawing.Color]::DimGray
    $d.Controls.Add($l2)

    if ($LockName) {
        $tb.ReadOnly  = $true
        $tb.TabStop   = $false
        $tb.BackColor = [System.Drawing.SystemColors]::Control
        $l2.Text = 'NONE is the fallback for anything unmatched, so its name is fixed. Its ratio is yours to set.'
        $d.Add_Shown({ $num.Select() })
    }

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Ratio %'
    $l3.Location = New-Object System.Drawing.Point(12, 108)
    $l3.Size = New-Object System.Drawing.Size(60, 18)
    $d.Controls.Add($l3)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum = 0; $num.Maximum = 100
    $num.Value = [Math]::Min([Math]::Max($Ratio, 0), 100)
    $num.Location = New-Object System.Drawing.Point(78, 106)
    $num.Size = New-Object System.Drawing.Size(70, 24)
    $d.Controls.Add($num)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point(196, 176)
    $ok.Size = New-Object System.Drawing.Size(84, 30)
    $d.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(288, 176)
    $cancel.Size = New-Object System.Drawing.Size(84, 30)
    $d.Controls.Add($cancel)

    $d.AcceptButton = $ok; $d.CancelButton = $cancel

    if ($d.ShowDialog($form) -ne 'OK') { return $null }
    $n = $tb.Text.Trim()
    if (-not $n) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'The aircraft name cannot be blank.', 'Nothing entered', 'OK', 'Warning')
        return $null
    }
    return @{ name = $n; ratio = [int]$num.Value }
}

function Get-Selected {
    if ($list.SelectedItems.Count -eq 0) { return $null }
    $name = $list.SelectedItems[0].Text
    return ($ratios | Where-Object { $_.name -eq $name } | Select-Object -First 1)
}

function Get-MoveFloor {
    <#
        NONE is the fallback rather than an aircraft, so it is pinned to the top
        and never moves. Everything else reorders within the rows beneath it.
        A table with no NONE entry has no pinned row and starts at 0.
    #>
    if ($ratios.Count -gt 0 -and $ratios[0].name -ieq 'NONE') { return 1 }
    return 0
}

function Move-Selected {
    <# Shift the selected row one position, keeping the selection on it. #>
    param([Parameter(Mandatory)][int]$Delta)

    if ($list.SelectedIndices.Count -eq 0) { return }
    $from = $list.SelectedIndices[0]
    $to   = $from + $Delta
    $floor = Get-MoveFloor
    if ($from -lt $floor -or $to -lt $floor -or $to -ge $ratios.Count) { return }

    $row = $ratios[$from]
    $ratios.RemoveAt($from)
    $ratios.Insert($to, $row)
    Update-List -SelectIndex $to
}

[void](New-Button 'Add' 70 {
    $r = Show-EntryDialog
    if (-not $r) { return }
    $clash = $ratios | Where-Object { $_.name -ieq $r.name } | Select-Object -First 1
    if ($clash) {
        [void][System.Windows.Forms.MessageBox]::Show($form, "'$($r.name)' is already in the list.", 'Already there', 'OK', 'Warning')
        return
    }
    [void]$ratios.Add([pscustomobject]@{ name = $r.name; ratio = $r.ratio })
    Update-List -SelectName $r.name
} 'Add an aircraft to the table')

$editAction = {
    $sel = Get-Selected
    if (-not $sel) { return }
    $isNone = $sel.name -ieq 'NONE'
    $r = Show-EntryDialog -Name $sel.name -Ratio $sel.ratio -Title 'Edit aircraft' -LockName:$isNone
    if (-not $r) { return }
    # The fallback's name is fixed - renaming it away would remove it as surely
    # as deleting it - so only the ratio comes back from the dialog.
    if ($isNone) { $r.name = $sel.name }
    # Same clash rule as Add. The entry being edited is skipped by reference, so
    # renaming something to itself - or just changing its case - is not a clash.
    $clash = $ratios | Where-Object { -not [object]::ReferenceEquals($_, $sel) -and $_.name -ieq $r.name } | Select-Object -First 1
    if ($clash) {
        [void][System.Windows.Forms.MessageBox]::Show($form, "'$($r.name)' is already in the list.", 'Already there', 'OK', 'Warning')
        return
    }
    $sel.name = $r.name; $sel.ratio = $r.ratio
    Update-List -SelectName $r.name
}
$btnEdit = New-Button 'Edit' 108 $editAction 'Change the selected entry'

$btnDelete = New-Button 'Delete' 146 {
    $sel = Get-Selected
    if (-not $sel) { return }
    if ($sel.name -ieq 'NONE') { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, "Remove '$($sel.name)' from the table?", 'Remove entry', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $ratios.Remove($sel)
    Update-List
} 'Remove the selected entry'

$btnUp = New-Button 'Move Up' 184 { Move-Selected -Delta -1 } 'Move the selected entry one row up'

$btnDown = New-Button 'Move Down' 222 { Move-Selected -Delta 1 } 'Move the selected entry one row down'

[void](New-Button 'A-Z' 260 {
    if ($ratios.Count -lt 2) { return }
    # NONE sorts to the top rather than under N, and this is also the only way
    # to get it back there if an older config has it somewhere in the middle.
    $none = @($ratios | Where-Object { $_.name -ieq 'NONE' })
    $rest = @($ratios | Where-Object { $_.name -ine 'NONE' } | Sort-Object { $_.name })
    $keep = if ($list.SelectedIndices.Count -gt 0) { $ratios[$list.SelectedIndices[0]] } else { $null }
    $ratios.Clear()
    foreach ($r in $none) { [void]$ratios.Add($r) }
    foreach ($r in $rest) { [void]$ratios.Add($r) }
    if ($keep) { Update-List -SelectIndex $ratios.IndexOf($keep) } else { Update-List }
} 'Sort the table A-Z, keeping NONE at the top')

$btnActivate = New-Button 'Activate' 310 {
    $sel = Get-Selected
    if (-not $sel) { return }
    $form.Cursor = 'WaitCursor'
    try {
        $applied = Set-CurrentRatio -Config $cfg -Percent $sel.ratio
        if ($null -eq $applied) {
            [void][System.Windows.Forms.MessageBox]::Show($form,
                "Could not reach the throttle.`n`nIf this is the first time, calibrate the afterburner detent in SimAppPro - until then there is no ratio to set.",
                'Throttle not found', 'OK', 'Warning')
        } else {
            # The throttle no longer reflects a detected module, so nothing
            # should look live until DCS says otherwise.
            Clear-DetectedAircraft
            Refresh-Device
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not set the ratio', 'OK', 'Error')
    } finally { $form.Cursor = 'Default' }
} 'Apply this ratio to the throttle now'

[void](New-Button 'Restore Default' 348 {
    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        "Restore the throttle to how it ships?`r`n`r`nThe detent goes back to having no afterburner mapping. Your table is not touched, and the detent calibration is left alone.",
        'Restore default', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'
    try {
        $r = Clear-CurrentRatio -Config $cfg
        if ($null -eq $r) {
            [void][System.Windows.Forms.MessageBox]::Show($form, 'Could not reach the throttle.', 'Throttle not found', 'OK', 'Warning')
        } else { Refresh-Device }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not restore the default', 'OK', 'Error')
    } finally { $form.Cursor = 'Default' }
} 'Put the throttle back to how it ships, with no ratio applied')

[void](New-Button 'Refresh' 386 { Refresh-Device } 'Re-read the value currently on the throttle')

function Update-ButtonState {
    <# Every row-scoped button is dead without a selection, so none stay lit. #>
    $i = if ($list.SelectedIndices.Count -gt 0) { $list.SelectedIndices[0] } else { -1 }
    $has = $i -ge 0
    # NONE is what every unmatched aircraft falls back to, so it stays put and
    # stays in the table. Its ratio is still editable.
    $isNone = $has -and $ratios[$i].name -ieq 'NONE'
    $btnEdit.Enabled = $has
    $btnDelete.Enabled = $has -and -not $isNone
    $btnActivate.Enabled = $has

    $floor = Get-MoveFloor
    $btnUp.Enabled   = $has -and $i -gt $floor
    $btnDown.Enabled = $has -and $i -ge $floor -and $i -lt ($ratios.Count - 1)
}
$list.Add_SelectedIndexChanged({ Update-ButtonState })

function Refresh-Device {
    $lblDevice.Text = 'Reading the throttle...'
    $form.Refresh()
    # Cheap file read, and independent of whether the throttle answers: a device
    # error should not also blank out what DCS last reported.
    $script:detected = Read-State
    Update-DetectedLabel
    try {
        $cur = Get-CurrentRatio -Config $cfg
        if ($null -eq $cur) {
            $script:currentPercent = $null
            $lblDevice.ForeColor = [System.Drawing.Color]::Firebrick
            $lblDevice.Text = "No calibrated throttle found. Calibrate the afterburner detent in SimAppPro once, then reopen this."
        } else {
            $script:currentPercent = $cur.Percent
            $lblDevice.ForeColor = [System.Drawing.Color]::Black
            $shown = if ($null -eq $cur.Percent) { 'Inactivated (no ratio applied)' } else { "$($cur.Percent)%" }
            $lblDevice.Text = "$($cur.Device)`r`nCurrently on the throttle: $shown"
        }
    } catch {
        $script:currentPercent = $null
        $lblDevice.ForeColor = [System.Drawing.Color]::Firebrick
        $lblDevice.Text = "Could not read the throttle: $($_.Exception.Message)"
    }
    Update-Highlight
}

$lblUpdate = New-Object System.Windows.Forms.LinkLabel
$lblUpdate.Location = New-Object System.Drawing.Point(12, 444)
$lblUpdate.Size = New-Object System.Drawing.Size(400, 22)
$lblUpdate.Anchor = 'Bottom,Left'
$lblUpdate.Visible = $false
$form.Controls.Add($lblUpdate)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'
$btnSave.Location = New-Object System.Drawing.Point(320, 474)
$btnSave.Size = New-Object System.Drawing.Size(100, 34)
$btnSave.Anchor = 'Bottom,Right'
$btnSave.Add_Click({
    try {
        Write-ConfigRatios -Ratios @($ratios)
        $btnSave.Text = 'Saved'
        $form.Refresh()
        Start-Sleep -Milliseconds 400
        $btnSave.Text = 'Save'
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not save', 'OK', 'Error')
    }
})
$form.Controls.Add($btnSave)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(428, 474)
$btnClose.Size = New-Object System.Drawing.Size(104, 34)
$btnClose.Anchor = 'Bottom,Right'
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Location = New-Object System.Drawing.Point(12, 470)
$lblHint.Size = New-Object System.Drawing.Size(300, 44)
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$lblHint.Anchor = 'Bottom,Left'
$lblHint.Text = "Green = the module DCS last reported.`r`nChanges apply in DCS within ~2 seconds."
$form.Controls.Add($lblHint)

# Double-clicking a row is the obvious way to edit it.
$list.Add_DoubleClick($editAction)

# Warn on closing with unsaved edits rather than losing them silently.
$savedSnapshot = ($ratios | ForEach-Object { "$($_.name)=$($_.ratio)" }) -join '|'
$form.Add_FormClosing({
    $now = ($ratios | ForEach-Object { "$($_.name)=$($_.ratio)" }) -join '|'
    if ($now -eq $script:savedSnapshot) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Save your changes before closing?', 'Unsaved changes', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { $_.Cancel = $true; return }
    if ($answer -eq 'Yes') {
        try { Write-ConfigRatios -Ratios @($ratios) }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not save', 'OK', 'Error')
            $_.Cancel = $true
        }
    }
})
$btnSave.Add_Click({ $script:savedSnapshot = ($ratios | ForEach-Object { "$($_.name)=$($_.ratio)" }) -join '|' })
$script:savedSnapshot = $savedSnapshot

Update-List
$form.Add_Shown({
    $form.Activate()
    Refresh-Device

    # Say so, rather than letting a row the user hand-edited just disappear.
    if ($skipped.Count -gt 0) {
        $what = if ($skipped.Count -eq 1) { 'entry whose ratio is' } else { 'entries whose ratios are' }
        [void][System.Windows.Forms.MessageBox]::Show($form,
            ("config.json has $($skipped.Count) $what not a whole number from 0 to 100:`r`n`r`n" +
             (($skipped | ForEach-Object { "    $_" }) -join "`r`n") +
             "`r`n`r`nThose rows are not listed here and are never sent to the throttle. " +
             "Correct them in config.json, or save from this window to drop them for good."),
            'Entries ignored', 'OK', 'Warning')
    }

    if ($cfg.PSObject.Properties['checkForUpdates'] -and -not $cfg.checkForUpdates) { return }
    $latest = Get-LatestRelease
    if ($latest -and (Test-IsNewer -Candidate $latest.Tag -Current $version)) {
        $lblUpdate.Text = "Update available: $($latest.Tag)  (you have v$version)"
        $lblUpdate.Tag = $latest.Url
        $lblUpdate.Visible = $true
        $lblUpdate.Add_LinkClicked({ Start-Process $lblUpdate.Tag })
    }
})

[void]$form.ShowDialog()
