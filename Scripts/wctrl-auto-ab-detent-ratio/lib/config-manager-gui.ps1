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

$cfg    = Read-Config
$ratios = New-Object System.Collections.ArrayList
foreach ($r in @($cfg.ratios)) {
    if ($r.name) { [void]$ratios.Add([pscustomobject]@{ name = [string]$r.name; ratio = [int]$r.ratio }) }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Afterburner detent ratios  -  v$version"
$form.Size = New-Object System.Drawing.Size(560, 560)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(480, 460)

$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Location = New-Object System.Drawing.Point(12, 12)
$lblDevice.Size = New-Object System.Drawing.Size(520, 34)
$lblDevice.Text = 'Looking for your throttle...'
$lblDevice.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblDevice)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(12, 54)
$list.Size = New-Object System.Drawing.Size(400, 380)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.GridLines = $true
$list.HideSelection = $false
$list.Anchor = 'Top,Left,Bottom,Right'
[void]$list.Columns.Add('Aircraft', 250)
[void]$list.Columns.Add('Ratio %', 110)
$form.Controls.Add($list)

# What the throttle currently reports, so the matching row(s) can be shown as
# active. More than one entry can share a ratio, and all of them are highlighted
# - the device stores a percentage, not which aircraft it came from, so claiming
# a single row is "the" active one would be inventing information.
$script:currentPercent = $null

$script:activeBack = [System.Drawing.Color]::FromArgb(198, 239, 206)
$script:activeFore = [System.Drawing.Color]::FromArgb(0, 97, 0)

function Update-Highlight {
    foreach ($item in $list.Items) {
        $isActive = ($null -ne $script:currentPercent) -and
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

function Update-List {
    param([string]$SelectName)
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($r in $ratios) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.name)
        [void]$item.SubItems.Add([string]$r.ratio)
        [void]$list.Items.Add($item)
        if ($SelectName -and $r.name -eq $SelectName) { $item.Selected = $true; $item.EnsureVisible() }
    }
    Update-Highlight
    $list.EndUpdate()
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
    param([string]$Name = '', [int]$Ratio = 75, [string]$Title = 'Add aircraft')

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

[void](New-Button 'Add' 54 {
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
    $r = Show-EntryDialog -Name $sel.name -Ratio $sel.ratio -Title 'Edit aircraft'
    if (-not $r) { return }
    $sel.name = $r.name; $sel.ratio = $r.ratio
    Update-List -SelectName $r.name
}
[void](New-Button 'Edit' 92 $editAction 'Change the selected entry')

[void](New-Button 'Delete' 130 {
    $sel = Get-Selected
    if (-not $sel) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, "Remove '$($sel.name)' from the table?", 'Remove entry', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $ratios.Remove($sel)
    Update-List
} 'Remove the selected entry')

$btnActivate = New-Button 'Activate' 180 {
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
            Refresh-Device
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not set the ratio', 'OK', 'Error')
    } finally { $form.Cursor = 'Default' }
} 'Apply this ratio to the throttle now'

[void](New-Button 'Unset' 218 {
    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        "Clear the ratio on the throttle?`r`n`r`nThe detent goes back to how it ships, with no afterburner mapping. Your table is not touched, and the detent calibration is left alone.",
        'Unset the throttle', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'
    try {
        $r = Clear-CurrentRatio -Config $cfg
        if ($null -eq $r) {
            [void][System.Windows.Forms.MessageBox]::Show($form, 'Could not reach the throttle.', 'Throttle not found', 'OK', 'Warning')
        } else { Refresh-Device }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not clear the ratio', 'OK', 'Error')
    } finally { $form.Cursor = 'Default' }
} 'Clear the ratio so the throttle behaves as it ships')

[void](New-Button 'Refresh' 262 { Refresh-Device } 'Re-read the value currently on the throttle')

function Refresh-Device {
    $lblDevice.Text = 'Reading the throttle...'
    $form.Refresh()
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
$lblHint.Text = "Green = currently on the throttle.`r`nChanges apply in DCS within ~2 seconds."
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
