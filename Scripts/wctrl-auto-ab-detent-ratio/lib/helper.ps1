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
# recorded in the first line of every run instead.
$script:LogPath = Join-Path $env:USERPROFILE "Saved Games\DCS\Logs\$script:BaseName.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try {
        $dir = Split-Path -Parent $script:LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    } catch { }
    if ($Foreground -or $Status -or $Devices -or $Apply -ge 0 -or $Restore) { Write-Host $line }
}

# ----------------------------------------------------------------- config ----

$script:DefaultRatios = @(
    @{ name = 'NONE'; ratio = 100 }
)

# Identity of config.json as of the last load, so an edit made while DCS is
# running is picked up without re-parsing the file on every tick.
$script:TableStamp = $null

function Get-HelperConfig {
    $path = Join-Path $scriptDir 'config.json'
    $cfg = [ordered]@{
        port               = 16537
        restoreRatio       = 'clear'
        noMatchRatio       = 75
        throttlePid        = 0
        deviceNameIncludes = @('Orion Throttle Base II')
        heartbeatTimeoutMs = 15000
        dcsProcessName     = 'DCS'
        checkForUpdates    = $true
        overrides          = @{}
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
    # Normalise overrides to a hashtable: it arrives as a PSCustomObject from
    # ConvertFrom-Json but is a hashtable when defaulted.
    $ov = @{}
    if ($cfg.overrides -is [hashtable]) {
        foreach ($k in $cfg.overrides.Keys) { $ov[[string]$k] = [int]$cfg.overrides[$k] }
    } elseif ($cfg.overrides) {
        foreach ($p in $cfg.overrides.PSObject.Properties) { $ov[[string]$p.Name] = [int]$p.Value }
    }
    $cfg.overrides = $ov
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

function Get-RatioTable {
    <#
        Our own config.json is the source of truth. SimAppPro is needed once, to
        calibrate the afterburner detent, and never read from here: it is an
        Electron app that rewrites its whole config from memory, so treating it
        as a live source made this tool hostage to another program's lifecycle.
        Ratios are edited with launch-config-manager.cmd or by hand.
    #>
    $path = Get-ConfigPath
    if (Test-Path $path) {
        try {
            $j = Get-Content $path -Raw | ConvertFrom-Json
            if ($j.ratios) {
                # A ratio that is not a whole 0..100 is dropped, not clamped or
                # guessed at: it cannot be written to the throttle. Each row is
                # parsed on its own so one hand-edited mistake costs that entry
                # and not the entire table - [int] on a non-numeric string
                # throws, and the catch below would fall back to the defaults,
                # quietly discarding every ratio the user had tuned.
                $t   = @()
                $bad = @()
                foreach ($e in @($j.ratios | Where-Object { $_.name })) {
                    $n = 0
                    if ([int]::TryParse([string]$e.ratio, [ref]$n) -and $n -ge 0 -and $n -le 100) {
                        $t += @{ name = [string]$e.name; ratio = $n }
                    } else {
                        $bad += "$($e.name)=$($e.ratio)"
                    }
                }
                if ($bad.Count -gt 0) {
                    Write-Log ("ignoring $($bad.Count) ratio entr" +
                               $(if ($bad.Count -eq 1) { 'y' } else { 'ies' }) +
                               " that are not a whole 0-100: $($bad -join ', ')") 'warn'
                }
                if ($t.Count -gt 0) {
                    $script:TableStamp = Get-ConfigStamp
                    Write-Log "ratio table: $($t.Count) entries"
                    return $t
                }
            }
        } catch {
            Write-Log "config.json unreadable: $($_.Exception.Message)" 'warn'
        }
    }
    $script:TableStamp = Get-ConfigStamp
    Write-Log ('no ratios configured - every aircraft will get NONE. ' +
               'Run launch-config-manager.cmd to add some.') 'warn'
    return $script:DefaultRatios
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

# --------------------------------------------------------------- matching ----

function Resolve-Ratio {
    <#
        The aircraft name must CONTAIN the table entry's name (case-insensitive).
        Longest match wins so "F-4E" beats "F-4" on an F-4E. NONE never matches
        by name - it is the fallback. With no NONE entry, fall back to the
        configured restore ratio (the throttle's neutral 75%).
    #>
    param(
        [Parameter(Mandatory)][string]$Aircraft,
        [Parameter(Mandatory)][array]$Table,
        [Parameter(Mandatory)]$Config
    )

    foreach ($k in $Config.overrides.Keys) {
        if ($k -ieq $Aircraft) {
            return @{ ratio = [int]$Config.overrides[$k]; via = "override '$k'" }
        }
    }

    $up = $Aircraft.ToUpperInvariant()
    $best = $null
    foreach ($e in $Table) {
        if ([string]::IsNullOrWhiteSpace($e.name)) { continue }
        if ($e.name -ieq 'NONE') { continue }
        if ($up.Contains($e.name.ToUpperInvariant())) {
            if ($null -eq $best -or $e.name.Length -gt $best.name.Length) { $best = $e }
        }
    }
    if ($best) { return @{ ratio = [int]$best.ratio; via = "matched '$($best.name)'" } }

    $none = $Table | Where-Object { $_.name -ieq 'NONE' } | Select-Object -First 1
    if ($none) { return @{ ratio = [int]$none.ratio; via = 'no match -> NONE' } }

    return @{ ratio = [int]$Config.noMatchRatio; via = "no match, no NONE entry -> default $($Config.noMatchRatio)%" }
}

# ----------------------------------------------------------------- device ----

$script:CachedDevice = $null
$script:CachedPart   = $null

function Select-ThrottleDevice {
    <#
        Narrow the WinWing devices down to the ones we are allowed to touch.

        Without a name filter any VID 0x4098 device whose part reports programmed
        afterburner calibration would be fair game - which could pick up a
        different throttle (an Orion Base I, or a second stick) and reconfigure it.

        deviceNameIncludes is a list of case-insensitive substrings; a device
        qualifies if its product string contains ANY of them. Deliberately
        brand-agnostic: the vendor rebranded twice (WinWing -> WinUSA ->
        WinCtrl) in ~18 months, so the same model reports as "WINWING ...",
        "WINUSA ..." or "WINCTRL ..." depending on firmware age. Match the
        model, never the brand. An empty list accepts any device from this
        vendor (selection still keys on the VID, which the rebrands did not
        change).
    #>
    param([Parameter(Mandatory)]$Config)

    $all = @(Get-WinctrlDevice -ProductId ([int]$Config.throttlePid))
    if ($all.Count -eq 0) {
        Write-Log 'no WinWing HID device found (throttle unplugged?)' 'warn'
        return @()
    }

    $filters = @($Config.deviceNameIncludes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($filters.Count -eq 0) { return $all }

    $matched = @($all | Where-Object {
        $name = [string]$_.Product
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        $upper = $name.ToUpperInvariant()
        foreach ($f in $filters) { if ($upper.Contains(([string]$f).ToUpperInvariant())) { return $true } }
        return $false
    })

    if ($matched.Count -eq 0) {
        Write-Log ("no device matched deviceNameIncludes [" + ($filters -join ', ') + "]; " +
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

    $devices = @(Select-ThrottleDevice -Config $Config)
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
    $allowed = @(Select-ThrottleDevice -Config $cfg | ForEach-Object { $_.Path })
    Write-Log ("deviceNameIncludes = [" + (@($cfg.deviceNameIncludes) -join ', ') + "]")
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

$restoreTarget = Get-RestoreTarget $cfg
Write-Log "v$script:Version listening on 127.0.0.1:$($cfg.port); restore target $(if ($restoreTarget -eq 'clear') { 'Inactivated' } else { "$restoreTarget%" })"

$script:currentAircraft = $null
$script:missionLive     = $false
$script:lastTraffic     = [DateTime]::UtcNow
$script:lastDcsCheck    = [DateTime]::UtcNow
$script:sawDcs          = $false
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
        [void](Set-Ratio -Target $r.ratio -Config $cfg -Reason "for $($script:currentAircraft) (config updated)")
    }
}

function Restore-Neutral {
    param([string]$Reason)
    if ($null -eq $script:currentAircraft) { return }
    $script:currentAircraft = $null
    $script:missionLive = $false
    [void](Set-Ratio -Target $restoreTarget -Config $cfg -Reason "($Reason)")
}

try {
    while ($true) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $null
        try { $bytes = $udp.Receive([ref]$remote) }
        catch [System.Net.Sockets.SocketException] { $bytes = $null }   # 1s idle tick

        if ($bytes -and $bytes.Length -gt 0) {
            $script:lastTraffic = [DateTime]::UtcNow
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
                                [void](Set-Ratio -Target $r.ratio -Config $cfg -Reason "for $name")
                            }
                        }
                        'mission' {
                            if ($msg.msg -eq 'stop') { Restore-Neutral 'mission stop' }
                            else { $script:missionLive = $true }
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

        # Watchdog: DCS crashed or the export died without a mission:stop.
        if ($script:missionLive) {
            $quiet = ([DateTime]::UtcNow - $script:lastTraffic).TotalMilliseconds
            if ($quiet -gt [int]$cfg.heartbeatTimeoutMs) {
                Restore-Neutral "no traffic for $([int]$quiet) ms"
            }
        }

        # DCS gone entirely -> restore and exit, so other sims are unaffected.
        if (([DateTime]::UtcNow - $script:lastDcsCheck).TotalSeconds -ge 5) {
            $script:lastDcsCheck = [DateTime]::UtcNow
            $dcsUp = [bool](Get-Process -Name $cfg.dcsProcessName -ErrorAction SilentlyContinue)
            if ($dcsUp) {
                $script:sawDcs = $true
            } elseif ($script:sawDcs) {
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
