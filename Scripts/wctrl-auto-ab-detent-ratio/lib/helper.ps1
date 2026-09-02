<#
    helper.ps1 - Auto-set the WinWing throttle afterburner ratio per DCS aircraft.

    Listens on UDP 127.0.0.1:16537 - the port WinWing's own wwtNetwork.lua already
    broadcasts to (it fans every message out to 16535 / 16536 / 16537, the last
    labelled "debug" and normally unbound). No DCS or WinWing file is modified.

    Messages consumed:
        {"func":"mod","msg":"FA-18C_hornet"}   aircraft entered/changed -> apply ratio
        {"func":"mission","msg":"stop"}        mission ended            -> restore
        {"func":"heartbeat","msg":<t>}         3s keepalive             -> watchdog

    The ratio is written straight to the throttle's flash over USB HID.

    SimAppPro is needed exactly once, to calibrate the afterburner detent (which
    programs 0x114/0x118 - the same calibration used here to identify the right
    throttle part). After that it is not required at all: the ratio table lives
    in this folder's config.json and is edited with launch-config-manager.cmd.

    Modes:
        helper.ps1                 run the listener (default)
        helper.ps1 -Status         print device state and exit
        helper.ps1 -Apply 82       set a ratio once and exit
        helper.ps1 -Restore        apply the configured restore ratio and exit
#>

[CmdletBinding()]
param(
    [int]$Apply = -1,
    [switch]$Restore,
    [switch]$Status,
    [switch]$Devices,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- logging ----

# Version comes from the folder name, which deploy.ps1 stamps
# (wctrl-auto-ab-detent-ratio-0.1-alpha). Running from the repo checkout leaves
# the plain name, which reports as 'dev'. Nothing extra to keep in sync.
$script:BaseName = 'wctrl-auto-ab-detent-ratio'
# helper.ps1 lives in <install>\lib, so the version-stamped name is on the
# parent directory, not this one.
$script:InstallDir = Split-Path -Parent $scriptDir
$script:Version  = $(
    $leaf = Split-Path -Leaf $script:InstallDir
    if ($leaf -like "$script:BaseName-*") { $leaf.Substring($script:BaseName.Length + 1) } else { 'dev' }
)

# Log name stays unversioned so it is always in the same place; the version is
# recorded in the first line of every run instead. Exactly two logs are kept:
# the session now running, and the one before it.
$script:LogDir      = Join-Path $env:USERPROFILE "Saved Games\DCS\Logs"
$script:LogPath     = Join-Path $script:LogDir "$script:BaseName.log"
$script:PrevLogPath = "$script:LogPath.bak"

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    } catch { }
    if ($Foreground -or $Status -or $Devices -or $Apply -ge 0 -or $Restore) { Write-Host $line }
}

function Start-LogSession {
    <#
        Roll the log over for a new DCS session: the previous .bak goes, this
        session's log becomes the .bak, and the next Write-Log starts a fresh one
        (Add-Content creates it). Same .bak convention deploy.ps1 uses for
        config.json, minus the timestamp - only one old log is ever kept.

        A rename moves no bytes, and -Force overwrites the old .bak in the same
        call, so the whole rotation is one filesystem operation. Nothing here is
        worth failing a run over - a log that could not be moved is simply
        appended to, exactly as before.

        Only the listener calls this, and only once it owns the UDP port: a
        second instance losing that race must not wipe the log of the one that
        is actually running. -Status / -Apply / -Restore / -Devices append to
        the current session's log rather than starting a new one.
    #>
    try {
        if (Test-Path $script:LogPath) {
            Move-Item -Path $script:LogPath -Destination $script:PrevLogPath -Force
        }
        elseif (Test-Path $script:PrevLogPath) {
            # No log to promote, so whatever is sitting in the .bak is older than
            # the session it claims to be and would only mislead.
            Remove-Item -Path $script:PrevLogPath -Force
        }
    } catch { }
}

# ----------------------------------------------------------------- config ----

$script:DefaultRatios = @(
    @{ name = 'NONE'; ratio = 100 }
)

# Identity of config.json as of the last load, so an edit made while DCS is
# running is picked up without re-parsing the file on every tick.
$script:TableStamp = $null

# The throttle group in force, and the config stamp it was resolved against.
# Resolving can mean enumerating HID devices, so it is done once per config
# load rather than once per operation.
$script:ActiveGroup      = $null
$script:ActiveGroupStamp = $null

function Get-HelperConfig {
    $path = Join-Path $scriptDir 'config.json'
    $cfg = [ordered]@{
        port               = 16537
        restoreRatio       = 'clear'
        noMatchRatio       = 75
        heartbeatTimeoutMs = 15000
        dcsProcessName     = 'DCS'
        checkForUpdates    = $true
    }
    if (Test-Path $path) {
        try {
            $j = Get-Content $path -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $j.PSObject.Properties[$k]) { $cfg[$k] = $j.$k }
            }
        } catch {
            Write-Log "config.json unreadable, using defaults: $($_.Exception.Message)" 'warn'
        }
    }
    return $cfg
}

function Get-ConfigPath { Join-Path $scriptDir 'config.json' }

function Get-ConfigStamp {
    # Cheap identity of our config file, so an edit made by config-manager while
    # DCS is running is noticed without re-reading and re-parsing every tick.
    try {
        $i = Get-Item (Get-ConfigPath) -ErrorAction Stop
        return ('{0}:{1}' -f $i.LastWriteTimeUtc.Ticks, $i.Length)
    } catch { return $null }
}

function Get-ThrottleGroups {
    <#
        The throttle groups from config.json, normalised.

        A group is @{ match; label; throttlePid; ratios } - which device it
        applies to, and the ratio table for that device. Grouping exists so a
        second throttle can carry its own table rather than fighting over a
        shared one; the shipped file has exactly one group and almost every
        install will stay that way.

        config v1 had one global "ratios" table plus a top-level
        deviceNameIncludes / throttlePid. That shape is folded into a single
        group here so a config the installer has not migrated yet still runs.
        This is only ever a read-side fallback - deploy.ps1 is what actually
        rewrites the file.

        A ratio that is not a whole 0..100 is dropped, not clamped or guessed
        at: it cannot be written to the throttle. Each row is parsed on its own
        so one hand-edited mistake costs that entry and not the entire table.
    #>
    $path = Get-ConfigPath
    if (-not (Test-Path $path)) { return @() }

    try { $j = Get-Content $path -Raw | ConvertFrom-Json }
    catch {
        Write-Log "config.json unreadable: $($_.Exception.Message)" 'warn'
        return @()
    }

    $raw = if ($j.throttles) {
        @($j.throttles)
    } elseif ($j.ratios) {
        @([pscustomobject]@{
            match       = @($j.deviceNameIncludes)
            label       = $null
            throttlePid = $j.throttlePid
            ratios      = $j.ratios
        })
    } else { @() }

    $groups = @()
    foreach ($g in $raw) {
        $match = @($g.match |
                   Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                   ForEach-Object { [string]$_ })

        # NOT $pid: that is an automatic variable holding this process's id.
        $productId = 0
        [void][int]::TryParse([string]$g.throttlePid, [ref]$productId)

        $label = [string]$g.label
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = if ($match.Count) { $match -join ', ' } else { 'any WinWing throttle' }
        }

        $ratios = @()
        $bad    = @()
        foreach ($e in @($g.ratios | Where-Object { $_.name })) {
            $n = 0
            if ([int]::TryParse([string]$e.ratio, [ref]$n) -and $n -ge 0 -and $n -le 100) {
                $ratios += @{ name = [string]$e.name; ratio = $n }
            } else {
                $bad += "$($e.name)=$($e.ratio)"
            }
        }
        if ($bad.Count -gt 0) {
            Write-Log ("$label - ignoring $($bad.Count) ratio entr" +
                       $(if ($bad.Count -eq 1) { 'y' } else { 'ies' }) +
                       " that are not a whole 0-100: $($bad -join ', ')") 'warn'
        }

        $groups += @{ match = $match; label = $label; throttlePid = $productId; ratios = $ratios }
    }
    # No leading comma here, unlike Get-RatioTable: every caller collects this
    # with @(...), and @() around a comma-wrapped array yields a one-element
    # array holding the array rather than the array itself.
    return $groups
}

function Select-MatchingDevice {
    <#
        Filter an already-enumerated device list down to the ones a group is
        allowed to touch.

        Without a name filter any VID 0x4098 device whose part reports
        programmed afterburner calibration would be fair game - which could pick
        up a different throttle (a stick base, or a rudder base) and
        reconfigure it.

        'match' is a list of case-insensitive substrings; a device qualifies if
        its product string contains ANY of them. Deliberately brand-agnostic:
        the vendor rebranded twice (WinWing -> WinUSA -> WinCtrl) in ~18 months,
        so the same model reports as "WINWING ...", "WINUSA ..." or
        "WINCTRL ..." depending on firmware age. Match the model, never the
        brand. An empty list accepts any device from this vendor (selection
        still keys on the VID, which the rebrands did not change).
    #>
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Devices
    )

    $filters = @($Group.match)
    if ($filters.Count -eq 0) { return @($Devices) }

    return @($Devices | Where-Object {
        $name = [string]$_.Product
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        $upper = $name.ToUpperInvariant()
        foreach ($f in $filters) { if ($upper.Contains(([string]$f).ToUpperInvariant())) { return $true } }
        return $false
    })
}

function Get-ActiveThrottleGroup {
    <#
        The group whose ratios apply right now: the first one that finds a
        device actually plugged in.

        Resolving means enumerating HID devices, so the answer is cached against
        the config stamp and recomputed only when config.json changes. With a
        single group - what ships, and what almost every install will ever have
        - there is nothing to resolve and no enumeration happens at all.

        With nothing connected, or nothing matching any group, fall back to the
        first group, so there is still a table to apply and still a filter to
        search with. Which group was picked and why is always logged: that line
        is what makes this diagnosable once a second throttle exists.
    #>
    $stamp = Get-ConfigStamp
    if ($script:ActiveGroup -and $script:ActiveGroupStamp -and $stamp -eq $script:ActiveGroupStamp) {
        return $script:ActiveGroup
    }

    $groups = @(Get-ThrottleGroups)
    if ($groups.Count -eq 0) { return $null }

    $picked = $null
    $why    = ''
    if ($groups.Count -eq 1) {
        $picked = $groups[0]
        $why    = 'the only one configured'
    } else {
        foreach ($g in $groups) {
            $devs = @(Get-WinctrlDevice -ProductId ([int]$g.throttlePid))
            if (@(Select-MatchingDevice -Group $g -Devices $devs).Count -gt 0) {
                $picked = $g
                $why    = 'its device is connected'
                break
            }
        }
        if (-not $picked) {
            $picked = $groups[0]
            $why    = "none of the $($groups.Count) configured throttles is connected - using the first"
        }
    }

    Write-Log "throttle group: $($picked.label) ($why)"
    $script:ActiveGroup      = $picked
    $script:ActiveGroupStamp = $stamp
    return $picked
}

function Get-RatioTable {
    <#
        Our own config.json is the source of truth. SimAppPro is needed once, to
        calibrate the afterburner detent, and never read from here: it is an
        Electron app that rewrites its whole config from memory, so treating it
        as a live source made this tool hostage to another program's lifecycle.
        Ratios are edited with launch-config-manager.cmd or by hand.

        The rows are the ACTIVE group's, so a config describing two throttles
        applies the table written for the one that is plugged in.
    #>
    $group = Get-ActiveThrottleGroup
    $script:TableStamp = Get-ConfigStamp

    # Leading comma on both returns: a single-row table would otherwise unroll
    # to the bare hashtable, and Sync-RatioTableIfChanged's .Count check would
    # then be counting that hashtable's KEYS rather than the table's rows.
    if ($group -and @($group.ratios).Count -gt 0) {
        Write-Log "ratio table: $(@($group.ratios).Count) entries for $($group.label)"
        return ,@($group.ratios)
    }

    Write-Log ('no ratios configured - every aircraft will get NONE. ' +
               'Run launch-config-manager.cmd to add some.') 'warn'
    return ,@($script:DefaultRatios)
}

function Get-RestoreTarget {
    <#
        The value applied when leaving DCS. Either an integer percent or the
        string 'clear', which writes FF FF FF FF - the device's "Inactivated"
        state, i.e. no afterburner mapping at all. Clearing does NOT disturb the
        calibration at 0x114/0x118, so nothing needs recalibrating afterwards.
    #>
    param([Parameter(Mandatory)]$Config)
    $v = $Config.restoreRatio
    if ($v -is [string] -and $v -ieq 'clear') { return 'clear' }
    $n = 0
    if ([int]::TryParse([string]$v, [ref]$n) -and $n -ge 0 -and $n -le 100) { return $n }
    Write-Log ("restoreRatio '" + $v + "' is not 0..100 or ""clear""; using ""clear""") 'warn'
    return 'clear'
}

# ------------------------------------------------------------------ state ----

function Get-StatePath { Join-Path $scriptDir 'state.json' }

function Read-StateFile {
    <#
        Whatever is on disk, or $null. Callers only ever use this to keep the
        half of the file they are not writing, so an unreadable file just means
        "keep nothing" and the write goes ahead anyway: a corrupt state.json
        must not be able to stop the helper recording a fresh one.
    #>
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-StateFile {
    <#
        Serialise the whole file.

        Its own file rather than a key in config.json. config.json is
        hand-edited and rewritten by the GUI's Save, so a second writer there
        would mean two processes splicing one file, where a Save landing on a
        stale read silently drops a name. state.json is machine-owned, which
        also means it can simply be serialised whole: there are no comments, key
        order or hand alignment to preserve, so none of the splice machinery is
        needed.

        Temp file then Move-Item -Force, so a reader never sees half a file. The
        config manager writes here too, for a ratio applied by hand, which makes
        this a read-modify-write across two processes - the loser of a
        same-instant collision loses its half. Both halves are display state
        that the next detection or Refresh rewrites, so a lock would cost more
        than the race does.

        Never throws. A state write must not be able to fail a detection.
    #>
    param($State)

    $path = Get-StatePath
    $tmp  = "$path.tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Write-Log "could not write state.json: $($_.Exception.Message)" 'warn'
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } } catch { }
    }
}

function New-StateAircraft {
    <# Null for a blank name, which is how "nothing is detected" is stored. #>
    param([string]$Name, $Ratio, [string]$Via)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    return [ordered]@{
        name  = $Name
        ratio = $Ratio
        via   = $Via
        at    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function New-StateProfile {
    <#
        Null for a blank entry, which is how "no row is on the throttle" is
        stored - a restore to neutral, or a resolve that landed on noMatchRatio
        and so belongs to no row at all.

        NONE is a row like any other and is stored by name: it is what the
        helper actually applied, and the editor should light it up.
    #>
    param([string]$Entry, $Ratio, [string]$Source)
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $null }
    return [ordered]@{
        name   = $Entry
        ratio  = $Ratio
        source = $Source
        at     = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Write-DetectedAircraft {
    <#
        Record what DCS reported AND which table row answered for it, so the
        config manager can colour the row that is actually on the throttle
        instead of re-deriving the match from a percentage.

        Two keys, because they answer different questions and go stale
        separately. lastDetectedAircraft is the DCS module name, which only a
        detection changes. lastAppliedProfile is the row now written to the
        device, which the config manager's Activate changes too: a ratio applied
        by hand is every bit as live as a detected one, and before this the
        editor had no way to know which row it came from.

        'name' on the profile is the TABLE ENTRY name, not the aircraft. An
        FA-18C_hornet detection resolves to the "FA-18" row, and "FA-18" is what
        goes here.

        Written on DETECTION, not on apply, and regardless of whether the HID
        write actually happened: the label should report what DCS said even when
        the throttle write failed verification.
    #>
    param([string]$Name, $Ratio, [string]$Via, [string]$Entry)

    Write-StateFile ([ordered]@{
        lastDetectedAircraft = New-StateAircraft -Name $Name -Ratio $Ratio -Via $Via
        lastAppliedProfile   = New-StateProfile -Entry $Entry -Ratio $Ratio -Source 'auto'
    })
}

function Clear-DetectedAircraft {
    <#
        No module detected: nothing in the editor should claim one.

        The applied profile is deliberately kept. It describes what is
        physically on the throttle, and the device holds its ratio in
        non-volatile memory - so a helper killed from Task Manager, or a power
        cut, loses the detection but not the ratio, and the row that put it
        there is still the honest answer. Restore-Neutral, which does rewrite
        the device, clears it explicitly.
    #>
    $s = Read-StateFile
    $keep = if ($s) { $s.lastAppliedProfile } else { $null }
    Write-StateFile ([ordered]@{
        lastDetectedAircraft = $null
        lastAppliedProfile   = $keep
    })
}

function Clear-AppliedProfile {
    <# The device is going back to neutral, so no row is live and nothing in the
       editor should be green. The detected name is left alone. #>
    $s = Read-StateFile
    $keep = if ($s) { $s.lastDetectedAircraft } else { $null }
    Write-StateFile ([ordered]@{
        lastDetectedAircraft = $keep
        lastAppliedProfile   = $null
    })
}

# --------------------------------------------------------------- matching ----

function Resolve-Ratio {
    <#
        The aircraft name must CONTAIN the table entry's name (case-insensitive).
        Longest match wins so "F-4E" beats "F-4" on an F-4E. NONE never matches
        by name - it is the fallback. With no NONE entry, fall back to the
        configured noMatchRatio.

        'entry' is the row that answered, which is what state.json records for
        the editor's highlight. It is $null only for the noMatchRatio case,
        where the ratio applied belongs to no row in the table.
    #>
    param(
        [Parameter(Mandatory)][string]$Aircraft,
        [Parameter(Mandatory)][array]$Table,
        [Parameter(Mandatory)]$Config
    )

    $up = $Aircraft.ToUpperInvariant()
    $best = $null
    foreach ($e in $Table) {
        if ([string]::IsNullOrWhiteSpace($e.name)) { continue }
        if ($e.name -ieq 'NONE') { continue }
        if ($up.Contains($e.name.ToUpperInvariant())) {
            if ($null -eq $best -or $e.name.Length -gt $best.name.Length) { $best = $e }
        }
    }
    if ($best) { return @{ ratio = [int]$best.ratio; via = "matched '$($best.name)'"; entry = [string]$best.name } }

    $none = $Table | Where-Object { $_.name -ieq 'NONE' } | Select-Object -First 1
    if ($none) { return @{ ratio = [int]$none.ratio; via = 'no match -> NONE'; entry = [string]$none.name } }

    return @{ ratio = [int]$Config.noMatchRatio; via = "no match, no NONE entry -> default $($Config.noMatchRatio)%"; entry = $null }
}

# ----------------------------------------------------------------- device ----

$script:CachedDevice = $null
$script:CachedPart   = $null

function Select-ThrottleDevice {
    <#
        Narrow the WinWing devices down to the ones we are allowed to touch.

        Both gates - the name filter and the product id - now come off the
        ACTIVE throttle group rather than the top level, so a second throttle
        with a different product id can be described without disturbing the
        first. The matching itself is unchanged; see Select-MatchingDevice for
        why it is deliberately brand-agnostic.
    #>
    $group = Get-ActiveThrottleGroup
    if (-not $group) {
        Write-Log 'no throttles configured in config.json' 'warn'
        return @()
    }

    $all = @(Get-WinctrlDevice -ProductId ([int]$group.throttlePid))
    if ($all.Count -eq 0) {
        Write-Log 'no WinWing HID device found (throttle unplugged?)' 'warn'
        return @()
    }

    $matched = @(Select-MatchingDevice -Group $group -Devices $all)
    if ($matched.Count -eq 0) {
        Write-Log ("no device matched " + $group.label + " match [" + (@($group.match) -join ', ') + "]; " +
                   "found: " + (($all | ForEach-Object { '"' + $_.Product + '"' }) -join ', ')) 'warn'
    }
    return $matched
}

function Use-Throttle {
    <#
        Open the throttle, run a scriptblock against it, always close.
        Opening per operation (rather than holding the handle) survives
        unplug/replug and keeps us off the device between aircraft changes.
        Returns $null and logs if no afterburner-capable device is present.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)]$Config)

    # Part discovery is a broadcast plus five reads per part - seconds of work.
    # Cache the result and only re-discover if the cached part stops answering
    # (unplug/replug, or a different throttle attached).
    if ($script:CachedDevice) {
        $hid = $null
        try {
            $hid = Open-WinctrlDevice -Device $script:CachedDevice
            if ($null -ne (Get-WinctrlAfterburnerRatio -Hid $hid -PartId $script:CachedPart.PartId)) {
                return (& $Action $hid $script:CachedPart $script:CachedDevice)
            }
            Write-Log 'cached throttle part stopped responding; re-discovering' 'warn'
        } catch {
            Write-Log "cached throttle unusable ($($_.Exception.Message)); re-discovering" 'warn'
        } finally {
            if ($hid) { $hid.Dispose() }
        }
        $script:CachedDevice = $null
        $script:CachedPart   = $null
    }

    $devices = @(Select-ThrottleDevice)
    if ($devices.Count -eq 0) { return $null }

    foreach ($dev in $devices) {
        $hid = $null
        try { $hid = Open-WinctrlDevice -Device $dev }
        catch { Write-Log "cannot open $($dev.Product): $($_.Exception.Message)" 'warn'; continue }
        try {
            $part = Get-WinctrlParts -Hid $hid | Where-Object HasAfterburner | Select-Object -First 1
            if (-not $part) { continue }
            $script:CachedDevice = $dev
            $script:CachedPart   = $part
            Write-Log "throttle: $($dev.Product) part $($part.PartIdHex) serial $($part.Serial)"
            return (& $Action $hid $part $dev)
        } catch {
            Write-Log "device error on $($dev.Product): $($_.Exception.Message)" 'warn'
        } finally {
            if ($hid) { $hid.Dispose() }
        }
    }
    # The gate is programmed calibration at 0x114/0x118, which only SimAppPro's
    # afterburner calibration writes. An uncalibrated detent has no ratio to set.
    Write-Log ('no afterburner-capable throttle part found - the detent reports no calibration. ' +
               'Calibrate the afterburner once in SimAppPro (throttle settings -> calibrate); ' +
               'after that SimAppPro is not needed again.') 'warn'
    return $null
}

function Format-Ratio {
    param($Value)
    if ($null -eq $Value) { return 'Inactivated' }
    return "$Value%"
}

function Set-Ratio {
    <# -Target is an integer percent, or the string 'clear' for Inactivated. #>
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Config, [string]$Reason = '')

    $wantClear = ($Target -is [string] -and $Target -ieq 'clear')
    $wantPct   = if ($wantClear) { $null } else { [int]$Target }

    $result = Use-Throttle -Config $Config -Action {
        param($hid, $part, $dev)
        # null == device reports Inactivated
        $before = Get-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId
        if ($before -eq $wantPct) { return @{ applied = $false; value = $before } }
        $after = if ($wantClear) {
            Set-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId -Clear
        } else {
            Set-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId -Percent $wantPct
        }
        return @{ applied = $true; value = $after; before = $before }
    }

    if ($null -eq $result) { return $false }
    if (-not $result.applied) {
        Write-Log "already at $(Format-Ratio $result.value) $Reason"
        return $true
    }
    if ($result.value -ne $wantPct) {
        Write-Log "WRITE VERIFY FAILED: wanted $(Format-Ratio $wantPct), device reports $(Format-Ratio $result.value)" 'error'
        return $false
    }
    Write-Log "afterburner ratio $(Format-Ratio $result.before) -> $(Format-Ratio $result.value) $Reason"
    return $true
}

# ------------------------------------------------------------------- main ----

. (Join-Path $scriptDir 'WinctrlHid.ps1')
$cfg = Get-HelperConfig

if ($Devices) {
    $all = @(Get-WinctrlDevice)
    if ($all.Count -eq 0) { Write-Log 'no WinWing (VID 0x4098) HID devices found' 'warn'; return }
    $active  = Get-ActiveThrottleGroup
    $allowed = @(Select-ThrottleDevice | ForEach-Object { $_.Path })
    # Which group is in force matters as much as which devices match it, so the
    # active one is starred rather than left to be inferred from the MATCH rows.
    foreach ($g in @(Get-ThrottleGroups)) {
        $mark = if ($active -and $g.label -eq $active.label) { '*' } else { ' ' }
        Write-Log ("$mark $($g.label): match = [" + (@($g.match) -join ', ') +
                   "], throttlePid = $($g.throttlePid), $(@($g.ratios).Count) ratios")
    }
    foreach ($d in $all) {
        $mark = if ($allowed -contains $d.Path) { 'MATCH ' } else { '  -   ' }
        Write-Log ("$mark $($d.ProductId)  $($d.Product)")
    }
    return
}

if ($Status) {
    Write-Log "version: $script:Version"
    Use-Throttle -Config $cfg -Action {
        param($hid, $part, $dev)
        Write-Log "device : $($dev.Product)"
        Write-Log "part   : $($part.PartIdHex)  serial $($part.Serial)"
        Write-Log "ratio  : $(Format-Ratio (Get-WinctrlAfterburnerRatio -Hid $hid -PartId $part.PartId))"
    } | Out-Null
    $tbl = Get-RatioTable
    Write-Log ("table  : " + (($tbl | ForEach-Object { "$($_.name)=$($_.ratio)" }) -join ', '))
    return
}

# Neither touches state.json, and neither can mislead the editor. -Apply takes a
# raw percentage rather than a row, so there is no row to record; a stale
# lastAppliedProfile stops being green the moment the percentage it names is no
# longer the one on the throttle. -Restore leaves the device Inactivated, which
# reports no percentage at all, so nothing is green either way. The config
# manager's own Activate is the one hand-applied path that DOES know its row,
# and it records it.
if ($Apply -ge 0) { [void](Set-Ratio -Target $Apply -Config $cfg -Reason '(manual)'); return }
if ($Restore)     { [void](Set-Ratio -Target (Get-RestoreTarget $cfg) -Config $cfg -Reason '(manual restore)'); return }

# ---- listener ----

$script:table = Get-RatioTable

$udp = $null
try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ExclusiveAddressUse = $false
    $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, [int]$cfg.port)))
} catch {
    Write-Log "port $($cfg.port) unavailable ($($_.Exception.Message)); another instance is probably running - exiting" 'warn'
    return
}
$udp.Client.ReceiveTimeout = 1000

# The port is ours, so this process is the session. The hook starts the helper
# once per DCS launch and the helper exits with DCS, so this fires exactly once
# per session - the log below is the first line of the fresh file.
Start-LogSession

$restoreTarget = Get-RestoreTarget $cfg
Write-Log "v$script:Version listening on 127.0.0.1:$($cfg.port); restore target $(if ($restoreTarget -eq 'clear') { 'Inactivated' } else { "$restoreTarget%" })"

# A helper killed from Task Manager or lost to a power cut leaves its last
# detection behind, and the next session must not inherit it.
Clear-DetectedAircraft

$script:currentAircraft = $null
$script:missionLive     = $false
$script:lastTraffic     = [DateTime]::UtcNow
$script:lastDcsCheck    = [DateTime]::UtcNow
$script:sawDcs          = $false   # DCS confirmed alive at least once
$script:dcsUp           = $false   # answer of the last process check
$script:quietLogged     = $false   # a hold has been logged for this silence
$script:lastTableCheck  = [DateTime]::UtcNow

function Sync-RatioTableIfChanged {
    <#
        Pick up ratios edited while DCS is running - launch-config-manager.cmd writing
        config.json, or a hand edit. A stat of the file is enough to notice.

        The new table is re-applied to whatever aircraft the player is already
        sitting in, otherwise a freshly added entry would not take effect until
        they switched aircraft. A transient read failure leaves the current
        table in place rather than clearing it.
    #>
    $stamp = Get-ConfigStamp
    if (-not $stamp -or -not $script:TableStamp -or $stamp -eq $script:TableStamp) { return }

    $new = Get-RatioTable
    if ($new.Count -eq 0) { return }

    $script:table = $new

    if ($script:currentAircraft) {
        $r = Resolve-Ratio -Aircraft $script:currentAircraft -Table $script:table -Config $cfg
        Write-Log "config changed; re-resolving '$($script:currentAircraft)' -> $($r.ratio)% ($($r.via))"
        # Re-resolving can move the answer to a different row, so the recorded
        # ratio has to follow or the editor would highlight nothing.
        Write-DetectedAircraft -Name $script:currentAircraft -Ratio $r.ratio -Via $r.via -Entry $r.entry
        [void](Set-Ratio -Target $r.ratio -Config $cfg -Reason "for $($script:currentAircraft) (config updated)")
    }
}

function Stop-Mission {
    <#
        Back to the DCS menu, mission ended. The throttle keeps the ratio and
        state.json keeps the name, because neither has stopped being true: the
        player is still in DCS and is very likely going straight into another
        mission or server in the same aircraft. Restoring here would write the
        device twice for that round trip - once to neutral, once back to the
        same ratio - and blank the editor's green row in between, all to end up
        where it started. Device config lives in non-volatile memory, so a write
        that changes nothing is still worth not making.

        Leaving $currentAircraft set is what makes the round trip free: the 'mod'
        handler skips a name that has not changed, so re-entering the same
        aircraft does nothing at all. A different aircraft applies as usual.

        missionLive no longer gates the watchdog - the process list decides
        that now - so all it does is keep this function to one log line if DCS
        reports the stop more than once. That is worth having; the menu is also
        exactly where someone quits, and the watchdog has to keep watching
        through it to notice.

        Leaving DCS entirely is still a restore - that is Restore-Neutral, from
        the watchdog's process check or the shutdown path.
    #>
    if (-not $script:missionLive) { return }
    $script:missionLive = $false
    $held = if ($script:currentAircraft) { "holding $($script:currentAircraft)" } else { 'nothing to hold' }
    Write-Log "mission stop; $held until DCS exits or another aircraft is reported"
}

function Restore-Neutral {
    param([string]$Reason)
    if ($null -eq $script:currentAircraft) { return }
    $script:currentAircraft = $null
    $script:missionLive = $false
    Clear-DetectedAircraft
    Clear-AppliedProfile
    [void](Set-Ratio -Target $restoreTarget -Config $cfg -Reason "($Reason)")
}

try {
    while ($true) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $null
        try { $bytes = $udp.Receive([ref]$remote) }
        catch [System.Net.Sockets.SocketException] { $bytes = $null }   # 1s idle tick

        if ($bytes -and $bytes.Length -gt 0) {
            if ($script:quietLogged) {
                $gap = ([DateTime]::UtcNow - $script:lastTraffic).TotalMilliseconds
                Write-Log "traffic resumed after $([int]$gap) ms"
                $script:quietLogged = $false
            }
            $script:lastTraffic = [DateTime]::UtcNow
            $script:sawDcs      = $true
            $text = [Text.Encoding]::UTF8.GetString($bytes)

            # Cheap prefilter: the export also streams addOutput at ~30Hz.
            if ($text.Contains('"mod"') -or $text.Contains('"mission"')) {
                try {
                    $msg = $text | ConvertFrom-Json
                    switch ($msg.func) {
                        'mod' {
                            $name = [string]$msg.msg
                            $script:missionLive = $true
                            if ($name -and $name -ne 'NONE' -and $name -ne $script:currentAircraft) {
                                $script:currentAircraft = $name
                                $r = Resolve-Ratio -Aircraft $name -Table $script:table -Config $cfg
                                Write-Log "aircraft '$name' -> $($r.ratio)% ($($r.via))"
                                Write-DetectedAircraft -Name $name -Ratio $r.ratio -Via $r.via -Entry $r.entry
                                [void](Set-Ratio -Target $r.ratio -Config $cfg -Reason "for $name")
                            }
                        }
                        'mission' {
                            if ($msg.msg -eq 'stop') { Stop-Mission } else { $script:missionLive = $true }
                        }
                    }
                } catch {
                    Write-Log "bad datagram ignored: $($_.Exception.Message)" 'warn'
                }
            }
        }

        # Ratios edited mid-session? Cheap file stat, every 2s.
        if (([DateTime]::UtcNow - $script:lastTableCheck).TotalSeconds -ge 2) {
            $script:lastTableCheck = [DateTime]::UtcNow
            try { Sync-RatioTableIfChanged } catch { Write-Log "table reload failed: $($_.Exception.Message)" 'warn' }
        }

        # Watchdog. One silence timer, and one question asked only when it
        # expires: is DCS still there?
        #
        # Silence is not evidence of anything on its own. The heartbeat comes
        # out of the export loop, which DCS only runs while it is rendering, so
        # alt-tabbing out, a paused single-player mission, a long load and the
        # menu between missions all go quiet for far longer than the timeout
        # while DCS is perfectly healthy. Restoring on silence alone dropped the
        # ratio mid-sortie and then did not put it back, because 'mod' is only
        # sent on entering or changing aircraft, never on resuming one.
        #
        # So silence past the timeout only decides when to look; the process
        # list decides what it means. Still running is a pause of some kind:
        # hold the ratio, however long it lasts. Gone is the end of the session:
        # restore and exit, so other sims are unaffected and the port is free.
        #
        # This is also why the process list is not polled on a timer any more.
        # While a mission streams there is nothing to ask about, and Get-Process
        # enumerates every process on the machine; the 5s throttle now only
        # paces the question during a silence that is already unusual.
        $quiet = ([DateTime]::UtcNow - $script:lastTraffic).TotalMilliseconds
        if ($quiet -gt [int]$cfg.heartbeatTimeoutMs -and
            ([DateTime]::UtcNow - $script:lastDcsCheck).TotalSeconds -ge 5) {

            $script:lastDcsCheck = [DateTime]::UtcNow
            $script:dcsUp = [bool](Get-Process -Name $cfg.dcsProcessName -ErrorAction SilentlyContinue)

            if ($script:dcsUp) {
                # Once per silence, not once a second - and only when there
                # is a ratio being held through it. Silence with no aircraft
                # behind it is just the menu, or DCS not started yet, and has
                # nothing at stake worth a line in the log.
                if (-not $script:quietLogged -and $script:currentAircraft) {
                    $script:quietLogged = $true
                    Write-Log "no traffic for $([int]$quiet) ms, DCS still running; holding $($script:currentAircraft)"
                }
            } elseif ($script:sawDcs) {
                # sawDcs is set by traffic as well as by a sighting, so this
                # still fires correctly if dcsProcessName has been set wrong -
                # the datagrams themselves proved DCS was up. Before any of
                # that, silence just means DCS has not been started yet, and
                # the helper waits.
                Restore-Neutral 'DCS exited'
                Write-Log 'DCS no longer running - helper exiting'
                break
            }
        }
    }
} finally {
    try { Restore-Neutral 'helper shutting down' } catch { }
    if ($udp) { $udp.Close() }
    Write-Log 'stopped'
}
