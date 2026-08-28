<#
    tools\deploy.ps1 - Deploy this repo into DCS.

    Users run install.cmd, which wraps this. Named deploy rather than install so
    there is only one file called "install" and no ambiguity about what to run.

    DCS only auto-loads hooks from its Saved Games folder, and the hook resolves
    the helper as   lfs.writedir() .. Scripts\wctrl-auto-ab-detent-ratio\...
    so the repo cannot be the thing DCS runs. This copies Scripts\* into the
    live DCS folder(s).

    Target selection:
      - exactly one DCS folder found  -> use it
      - several found                 -> asks which, or all
      - none found                    -> asks for the path
      - not interactive               -> pass -SavedGames explicitly

        .\install.cmd                        # install / update; see $configPolicy
                                             # below for what happens to config.json
        .\install.cmd -All                   # every DCS folder found, no prompt
        .\install.cmd -SavedGames <p>[,<p>]  # explicit target(s)
        .\install.cmd -WhatIf                # show what would change, touch nothing
        .\install.cmd -ForceConfig           # discard config.json, use the shipped
                                             # defaults instead (backed up first)
        .\install.cmd -KeepConfig            # on a release that replaces config.json
                                             # by default, merge yours forward instead
        .\install.cmd -NoShortcut            # skip the Start Menu shortcut
        .\install.cmd -Shortcut              # create it without asking
        .\install.cmd -Uninstall             # remove the deployed copy
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$SavedGames,
    [switch]$All,
    [switch]$ForceConfig,
    [switch]$KeepConfig,
    [switch]$NoShortcut,
    [switch]$Shortcut,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
# This script lives in tools\, so the repo root is one level up. $PSScriptRoot
# is always the absolute directory of the file, unlike $MyInvocation.MyCommand.Path
# which is relative when invoked with a relative -File path.
$repo        = Split-Path -Parent $PSScriptRoot
$baseName    = 'wctrl-auto-ab-detent-ratio'

$versionFile = Join-Path $repo 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile)) { throw "Missing VERSION file at '$versionFile'." }
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($version)) { throw "VERSION file is empty." }
# Accept "v1.0.0-alpha" or "1.0.0-alpha". The leading v is a git tag convention,
# not part of a semver string, so it is stripped for the deployed names - the
# folder reads better as ...-1.0.0-alpha and it does not matter which form the
# VERSION file uses.
$version = $version -replace '^[vV](?=\d)', ''

# The deployed folder and hook carry the version, so a bug report can be traced
# to a build just by looking at the file names, and so a new version installs
# alongside rather than merging into the old one.
$projectName = "$baseName-$version"
$hookName    = "$baseName-hook-$version.lua"

# How this release treats a config.json that is already installed.
#
#   'Merge'   - the long-term default. Write-MergedConfig splices every value
#               the user has over the shipped file, so an upgrade only ever
#               adds: new settings, new aircraft, current comments. Nothing
#               they tuned is touched.
#
#   'Replace' - Write-ReplacedConfig installs the shipped file verbatim and
#               keeps theirs as a .bak. For a release that fixes the shipped
#               VALUES rather than the schema. A merge cannot deliver that:
#               it treats every key the user already has as theirs to keep,
#               which is exactly the wrong call when the number in their file
#               is the bug being fixed.
#
# Set per release, and set back to 'Merge' in the one after. Both functions
# stay - this line is the only thing that chooses between them, so a future
# release that has to correct a shipped default can flip it and no more.
# -KeepConfig overrides a 'Replace' release for one install; -ForceConfig
# overrides a 'Merge' one.
$configPolicy = 'Merge'

# Anything from this project under any other name: earlier project names, and
# any other version of this one. All of it gets removed after the new version is
# in place - two hooks loaded at once would fire every event twice.
$legacyNames = @('winctrl-auto-throttle-ratio', $baseName)
$legacyHooks = @('winctrl-auto-throttle-ratio-hook.lua', 'wctrl-auto-throttle-ratio-hook.lua', "$baseName-hook.lua")

function Test-OurHook {
    <#
        Does this .lua in Hooks\ belong to us? Covers the current
        <name>-hook-<version>.lua, the earlier <name>-<version>-hook.lua that
        buried the version mid-name, the unversioned <name>-hook.lua, and the
        older project names. Anything we ever shipped has to be recognised here
        or an upgrade leaves a second hook behind and every event fires twice.
    #>
    param([string]$Name)
    if ($Name -like "$baseName-hook-*.lua") { return $true }   # current form
    if ($Name -like "$baseName-*-hook.lua") { return $true }   # earlier form
    if ($legacyHooks -contains $Name)       { return $true }   # older names
    return $false
}

# Subfolders that mark a directory as a DCS "Saved Games" folder.
#
# A name match on DCS* is NOT enough. Modules keep their own data next to the
# real folder - a live example: Saved Games\ held DCS, DCS_F14, DCS_F4E,
# DCS_AJS37, DCS_OH58D and DCS.C130J, where only the first is a DCS root and the
# rest are Heatblur / module data (jester\, character_presets\, user_data.db).
# Installing into one of those would put the hook somewhere DCS never reads.
#
# Scripts\ is deliberately not required: DCS creates it only when something
# needs it, so a clean install legitimately has none and we create it ourselves.
$dcsMarkers = @('Config', 'Logs', 'Mods', 'Scripts')

# ---------------------------------------------------------------- discovery --

function Get-KnownSavedGamesPath {
    <#
        The authoritative Saved Games location. Windows lets a user relocate the
        folder to another drive (Properties -> Location), in which case
        %USERPROFILE%\Saved Games does not exist and guessing it would fail.
        FOLDERID_SavedGames = {4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}
    #>
    try {
        if (-not ('WctrlInstall.KnownFolder' -as [type])) {
            Add-Type -Namespace WctrlInstall -Name KnownFolder -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SHGetKnownFolderPath(ref System.Guid id, uint flags, System.IntPtr token, out System.IntPtr path);
'@
        }
        $guid = [Guid]'4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4'
        $ptr  = [IntPtr]::Zero
        if ([WctrlInstall.KnownFolder]::SHGetKnownFolderPath([ref]$guid, 0, [IntPtr]::Zero, [ref]$ptr) -eq 0) {
            $p = [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
            [Runtime.InteropServices.Marshal]::FreeCoTaskMem($ptr)
            if ($p) { return $p }
        }
    } catch { }
    # Fall back to the conventional location if the shell call is unavailable.
    return (Join-Path $env:USERPROFILE 'Saved Games')
}

function Test-DcsSavedGames {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($m in $dcsMarkers) {
        if (Test-Path -LiteralPath (Join-Path $Path $m)) { return $true }
    }
    return $false
}

function Find-DcsCandidates {
    <#
        Every DCS folder we can see: this user's (via the known folder, so a
        relocated Saved Games still resolves) plus any other profile on the box,
        for a shared machine where several people have DCS.

        Folder names are not hardcoded - DCS's dcs_variant.txt can rename the
        folder (that is where DCS.openbeta came from), so anything matching DCS*
        with a marker subfolder counts.
    #>
    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Get-KnownSavedGamesPath))

    # Other users on this machine. Reading another profile usually needs admin;
    # anything we cannot see is simply skipped.
    try {
        $usersDir = Split-Path -Parent $env:USERPROFILE
        foreach ($prof in Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue) {
            $sg = Join-Path $prof.FullName 'Saved Games'
            if (Test-Path -LiteralPath $sg) { $roots.Add($sg) }
        }
    } catch { }

    $found = [ordered]@{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Filter 'DCS*' -ErrorAction Stop) {
                if (-not (Test-DcsSavedGames $d.FullName)) { continue }
                $key = $d.FullName.TrimEnd('\').ToLowerInvariant()
                if (-not $found.Contains($key)) { $found[$key] = $d.FullName }
            }
        } catch { }   # unreadable profile
    }
    return @($found.Values)
}

# ----------------------------------------------------------------- prompting --

function Test-Interactive {
    # Read-Host blocks forever with no console, so never prompt when piped or in CI.
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
    catch { return [Environment]::UserInteractive }
}

function Read-DcsPathFromUser {
    Write-Host ''
    Write-Host 'No DCS folder was found automatically.'
    Write-Host 'It is usually:  %USERPROFILE%\Saved Games\DCS'
    Write-Host 'Enter the full path to your DCS Saved Games folder (blank to cancel).'
    while ($true) {
        Write-Host ''
        $p = (Read-Host 'DCS folder').Trim('"', ' ')
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }

        if (Test-DcsSavedGames $p) { return $p }

        if (Test-Path -LiteralPath $p -PathType Container) {
            Write-Warning "'$p' exists but has none of: $($dcsMarkers -join ', ') - it may not be a DCS folder."
            if ((Read-Host 'Use it anyway? (y/N)') -match '^(y|yes)$') { return $p }
        } else {
            Write-Warning "'$p' does not exist."
        }
    }
}

function Resolve-SelectionAnswer {
    <#
        Parse a menu answer into the chosen paths, or $null if it is not valid.
        Split out from the prompt loop purely so it can be tested without a
        console: "A"/"all" means everything, otherwise 1-based indices separated
        by commas or spaces. Any bad token rejects the whole answer rather than
        silently installing to a subset.
    #>
    param([string]$Answer, [string[]]$Candidates)

    if ($null -eq $Answer) { return $null }
    $Answer = $Answer.Trim()
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $null }
    if ($Answer -match '^(?i)(a|all)$') { return $Candidates }

    $picked = @()
    foreach ($tok in ($Answer -split '[,\s]+' | Where-Object { $_ })) {
        $n = 0
        if (-not ([int]::TryParse($tok, [ref]$n)) -or $n -lt 1 -or $n -gt $Candidates.Count) { return $null }
        $picked += $Candidates[$n - 1]
    }
    if ($picked.Count -eq 0) { return $null }
    return @($picked | Select-Object -Unique)
}

function Select-DcsTargets {
    param([string[]]$Candidates)

    Write-Host ''
    Write-Host 'Multiple DCS folders found:'
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Candidates[$i])
    }
    Write-Host '  [A] all of them'
    Write-Host ''

    while ($true) {
        $ans = Read-Host 'Install to which? (number, comma-separated list, or A)'
        $sel = Resolve-SelectionAnswer -Answer $ans -Candidates $Candidates
        if ($sel) { return $sel }
        Write-Warning "Enter a number from 1 to $($Candidates.Count), a list like '1,2', or A for all."
    }
}

function Resolve-Targets {
    if ($SavedGames) {
        foreach ($p in $SavedGames) {
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "Path not found: '$p'" }
        }
        return @($SavedGames)
    }

    $candidates = @(Find-DcsCandidates)

    if ($candidates.Count -eq 1) { return $candidates }
    if ($candidates.Count -gt 1) {
        if ($All) { return $candidates }
        if (-not (Test-Interactive)) {
            throw ("Found $($candidates.Count) DCS folders and cannot prompt here. " +
                   "Re-run with -All, or -SavedGames '<path>'. Found: " + ($candidates -join '; '))
        }
        return (Select-DcsTargets -Candidates $candidates)
    }

    if (-not (Test-Interactive)) {
        throw ("No DCS folder found under '$(Get-KnownSavedGamesPath)' and cannot prompt here. " +
               "Re-run with -SavedGames '<path to Saved Games\DCS>'.")
    }
    $manual = Read-DcsPathFromUser
    if (-not $manual) { return @() }
    return @($manual)
}

function Get-PriorInstalls {
    <#
        Every folder in Scripts\ belonging to this project other than the one we
        are about to write: earlier project names and other versions.
    #>
    param([string]$ScriptsDir, [string]$Current)
    $out = @()
    if (-not (Test-Path -LiteralPath $ScriptsDir)) { return $out }
    foreach ($d in Get-ChildItem -LiteralPath $ScriptsDir -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -ieq $Current) { continue }
        $isOurs = ($d.Name -like "$baseName-*") -or ($legacyNames -contains $d.Name)
        if ($isOurs) { $out += $d.FullName }
    }
    return $out
}

function Get-JsonValueSpan {
    <#
        Locate the span of a top-level key's VALUE inside a config.json, as
        offsets into the raw text. Working on the text rather than on a parsed
        object is what lets an upgrade keep the shipped comments, key order and
        hand-tuned alignment: only the spans that actually change get spliced.

        Returns @{ Start; End } (End exclusive) or $null when the key is absent.
    #>
    param([string]$Raw, [string]$Key)

    $m = [regex]::Match($Raw, '(?m)^\s*"' + [regex]::Escape($Key) + '"\s*:\s*')
    if (-not $m.Success) { return $null }
    $i = $m.Index + $m.Length
    if ($i -ge $Raw.Length) { return $null }

    $c = $Raw[$i]
    if ($c -eq '{' -or $c -eq '[') {
        # Walk to the matching close, tracking string state so a bracket inside
        # a string - or an escaped quote - does not throw the depth count off.
        $openCh  = $c
        $closeCh = if ($c -eq '{') { '}' } else { ']' }
        $depth = 0; $inStr = $false; $esc = $false
        for ($j = $i; $j -lt $Raw.Length; $j++) {
            $ch = $Raw[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($ch -eq '\') { $esc = $true }
                elseif ($ch -eq '"') { $inStr = $false }
                continue
            }
            if ($ch -eq '"') { $inStr = $true; continue }
            if ($ch -eq $openCh)  { $depth++; continue }
            if ($ch -eq $closeCh) { $depth--; if ($depth -eq 0) { return @{ Start = $i; End = $j + 1 } } }
        }
        return $null
    }
    if ($c -eq '"') {
        $esc = $false
        for ($j = $i + 1; $j -lt $Raw.Length; $j++) {
            $ch = $Raw[$j]
            if ($esc) { $esc = $false; continue }
            if ($ch -eq '\') { $esc = $true; continue }
            if ($ch -eq '"') { return @{ Start = $i; End = $j + 1 } }
        }
        return $null
    }
    # Number, true, false or null: runs to the next comma, close or line end.
    for ($j = $i; $j -lt $Raw.Length; $j++) {
        if ($Raw[$j] -match '[,\}\r\n]') { return @{ Start = $i; End = $j } }
    }
    return $null
}

function ConvertTo-JsonToken {
    <#
        One JSON scalar, rendered the way it will sit in config.json. Names and
        labels go through ConvertTo-Json rather than being wrapped in quotes by
        hand, so a value containing a quote or a backslash cannot produce a file
        that will not parse.
    #>
    param($Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Format-RatioRows {
    <#
        Render a ratio table as the aligned rows config.json ships with, so a
        merged file is indistinguishable from a hand-edited one. The column
        width follows the longest name rather than being fixed, so one long
        entry does not knock the rest out of line.

        -Indent is the column the CLOSING bracket sits at; rows go four further
        in. The table is nested inside a throttle group now, so this is 12
        rather than the 4 it was when the array was top level.

        A ratio that is not a whole number is written back exactly as the user
        wrote it, rather than being coerced or dropped. The installer's job is
        to preserve what is in their file; helper.ps1 and the config manager are
        what refuse such a row at read time, and they say so when they do.
    #>
    param([array]$Ratios, [int]$Indent = 4, [string]$NewLine = "`r`n")

    if ($Ratios.Count -eq 0) { return '[]' }

    $names = @($Ratios | ForEach-Object { (ConvertTo-JsonToken ([string]$_.name)) + ',' })
    $w = 9
    foreach ($n in $names) { if ($n.Length -gt $w) { $w = $n.Length } }

    # Built up front: -f binds tighter than +, so composing it inline would
    # format the trailing fragment instead of the whole template.
    $fmt  = (' ' * ($Indent + 4)) + '{{ "name": {0,' + (-$w) + '} "ratio": {1} }}'
    $rows = @()
    for ($i = 0; $i -lt $Ratios.Count; $i++) {
        $n = 0
        $value = if ([int]::TryParse([string]$Ratios[$i].ratio, [ref]$n)) {
            [string]$n
        } else {
            ConvertTo-JsonToken $Ratios[$i].ratio
        }
        $rows += $fmt -f $names[$i], $value
    }
    return '[' + $NewLine + ($rows -join (',' + $NewLine)) + $NewLine + (' ' * $Indent) + ']'
}

function Format-ThrottleGroups {
    <#
        Render the "throttles" array the way the shipped file lays it out: one
        object per throttle, keys aligned, the ratio table nested inside it.
    #>
    param([array]$Groups, [string]$NewLine = "`r`n")

    if ($Groups.Count -eq 0) { return '[]' }

    $blocks = @()
    foreach ($g in $Groups) {
        $match = if (@($g.match).Count -eq 0) {
            '[]'
        } else {
            '[ ' + ((@($g.match) | ForEach-Object { ConvertTo-JsonToken ([string]$_) }) -join ', ') + ' ]'
        }
        $blocks += (@(
            '        {'
            '            "match":       ' + $match + ','
            '            "label":       ' + (ConvertTo-JsonToken ([string]$g.label)) + ','
            '            "throttlePid": ' + [int]$g.throttlePid + ','
            '            "ratios":      ' + (Format-RatioRows -Ratios @($g.ratios) -Indent 12 -NewLine $NewLine)
            '        }'
        ) -join $NewLine)
    }
    return '[' + $NewLine + ($blocks -join (',' + $NewLine)) + $NewLine + '    ]'
}

function ConvertTo-ThrottleGroups {
    <#
        A parsed config.json as a list of throttle groups, whatever schema it is
        written in.

        v2 has them already. v1 had one global "ratios" table with the device
        gates - deviceNameIncludes and throttlePid - alongside it at the top
        level; that is exactly one group's worth of information, so it is read
        as one group. Everything downstream then sees a single shape and the
        migration is not a separate code path that has to be kept in step.
    #>
    param($Config)

    $raw = if ($Config.PSObject.Properties['throttles']) {
        @($Config.throttles)
    } elseif ($Config.PSObject.Properties['ratios']) {
        @([pscustomobject]@{
            match       = @($Config.deviceNameIncludes)
            label       = $null
            throttlePid = $Config.throttlePid
            ratios      = $Config.ratios
        })
    } else { @() }

    $out = @()
    foreach ($g in $raw) {
        # NOT $pid: that is an automatic variable holding this process's id.
        $productId = 0
        [void][int]::TryParse([string]$g.throttlePid, [ref]$productId)
        $out += [pscustomobject]@{
            match       = @($g.match |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            ForEach-Object { [string]$_ })
            label       = [string]$g.label
            throttlePid = $productId
            ratios      = @($g.ratios | Where-Object { $_.name } | ForEach-Object {
                                [pscustomobject]@{ name = [string]$_.name; ratio = $_.ratio } })
        }
    }
    return $out
}

function Test-GroupMatch {
    <#
        Do two throttle groups describe the same device?

        Matchers are substrings, so equality is too strict. A user who broadened
        "Orion Throttle Base II" to "Orion Throttle Base" still means the same
        throttle, and treating that as a different device would append a
        duplicate group and split their table in two. Containment in either
        direction is the same rule the device matcher itself applies.

        An empty matcher means "any device from this vendor", which overlaps
        everything by definition - so someone who cleared deviceNameIncludes
        under v1 merges into the shipped group and keeps their empty matcher,
        rather than gaining a second group that would shadow it.
    #>
    param($A, $B)

    $am = @($A.match); $bm = @($B.match)
    if ($am.Count -eq 0 -or $bm.Count -eq 0) { return $true }
    foreach ($x in $am) {
        $xu = ([string]$x).ToUpperInvariant()
        foreach ($y in $bm) {
            $yu = ([string]$y).ToUpperInvariant()
            if ($xu.Contains($yu) -or $yu.Contains($xu)) { return $true }
        }
    }
    return $false
}

function Merge-RatioRows {
    <#
        The user's rows win and keep their order and their values; any name this
        version ships that they have never seen is appended.

        NONE is the fallback rather than an aircraft, and the editor pins it to
        the top. Hoist it there on the way through so every config this
        installer writes has the same known shape, whatever order an older one
        happened to be in. A table that already has it first comes through
        unchanged.

        Returns @{ Rows; Added }.
    #>
    param([array]$UserRatios, [array]$ShippedRatios)

    $merged = @($UserRatios)
    $added  = @()

    $have = @{}
    foreach ($r in $merged) { $have[([string]$r.name).ToLowerInvariant()] = $true }

    foreach ($s in @($ShippedRatios | Where-Object { $_.name })) {
        if ($have.ContainsKey(([string]$s.name).ToLowerInvariant())) { continue }
        $merged += [pscustomobject]@{ name = [string]$s.name; ratio = $s.ratio }
        $added  += [string]$s.name
    }

    $none = @($merged | Where-Object { $_.name -ieq 'NONE' })
    if ($none.Count) {
        $merged = @($none) + @($merged | Where-Object { $_.name -ine 'NONE' })
    }

    return @{ Rows = @($merged); Added = @($added) }
}

function Merge-ThrottleGroups {
    <#
        Two-level merge: pair the user's groups with the shipped ones, merge
        each pair's rows, then deal with the groups that had no partner.

        Two cases, both deliberate:

          * A shipped group the user does not have is APPENDED. They may buy
            that throttle later, and an unmatched group costs nothing until
            they do - the helper only ever activates a group whose device is
            actually plugged in.
          * A user group with a matcher this version does not ship is KEPT.
            They may have hand-added a throttle that works, and dropping it
            would be no different from dropping a ratio they tuned.

        The user's own match, label and throttlePid always survive. A label is
        the one thing that can arrive from the shipped side, and only when the
        user has none - which is how a migrated v1 group, whose schema had no
        such key, gets one at all.

        Returns @{ Groups; AddedRatios; AddedGroups }.
    #>
    param([array]$UserGroups, [array]$ShippedGroups)

    $groups      = @()
    $addedRatios = @()
    $addedGroups = @()
    $paired      = @{}

    foreach ($u in $UserGroups) {
        $s = $null
        for ($i = 0; $i -lt $ShippedGroups.Count; $i++) {
            if ($paired.ContainsKey($i)) { continue }
            if (Test-GroupMatch -A $u -B $ShippedGroups[$i]) {
                $s = $ShippedGroups[$i]
                $paired[$i] = $true
                break
            }
        }

        $shippedRows = if ($s) { @($s.ratios) } else { @() }
        $m = Merge-RatioRows -UserRatios @($u.ratios) -ShippedRatios $shippedRows
        $addedRatios += $m.Added

        $label = if (-not [string]::IsNullOrWhiteSpace($u.label))          { $u.label }
                 elseif ($s -and -not [string]::IsNullOrWhiteSpace($s.label)) { $s.label }
                 elseif (@($u.match).Count)                                { @($u.match) -join ', ' }
                 else                                                      { 'Any WinWing throttle' }

        $groups += [pscustomobject]@{
            match       = @($u.match)
            label       = $label
            throttlePid = $u.throttlePid
            ratios      = @($m.Rows)
        }
    }

    for ($i = 0; $i -lt $ShippedGroups.Count; $i++) {
        if ($paired.ContainsKey($i)) { continue }
        $groups      += $ShippedGroups[$i]
        $addedGroups += [string]$ShippedGroups[$i].label
    }

    return @{ Groups = @($groups); AddedRatios = @($addedRatios); AddedGroups = @($addedGroups) }
}

function Merge-UserConfig {
    <#
        Fold a user's config.json into the one this version ships.

        The shipped file is the skeleton: it carries the current comments, any
        setting added since the user's version, and the current default ratio
        table. Every value the user already has is then spliced back over it, so
        an upgrade is purely additive - nothing they tuned is touched, and the
        only thing that changes is that genuinely new ratio entries and new
        settings appear. When the user is already current the result is
        byte-identical to what is on disk and the caller writes nothing.

        Keys are matched by name. A setting the user's version had that this one
        no longer ships is dropped, because the code that read it is gone. That
        is also what retires v1's top-level "ratios", "deviceNameIncludes" and
        "throttlePid": this version ships none of them, so they are not copied
        across - but ConvertTo-ThrottleGroups has already read them into a
        throttle group by then, so nothing in them is lost.

        _comment keys always come from the shipped file: they are documentation
        rather than user data, and they go stale otherwise. configVersion is the
        same - it is this version's statement about the file it just wrote, and
        carrying the user's forward would leave a migrated file claiming to be
        the shape it no longer is.

        Returns @{ Text; AddedRatios; AddedKeys; AddedGroups; Migrated } or
        $null if either file cannot be read, which leaves the caller with the
        shipped config untouched.
    #>
    param([string]$ShippedPath, [string]$UserPath)

    try {
        $shippedRaw = [IO.File]::ReadAllText($ShippedPath)
        $userRaw    = [IO.File]::ReadAllText($UserPath)
        $shipped    = $shippedRaw | ConvertFrom-Json
        $user       = $userRaw    | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $shipped -or -not $user) { return $null }

    # Follow the shipped file's own line endings rather than the platform's, so
    # a spliced array does not leave the file half CRLF and half LF - and so a
    # merge that changes nothing really does come out byte-identical.
    $nl = if ($shippedRaw.Contains("`r`n")) { "`r`n" } else { "`n" }

    # [pscustomobject], not a hashtable: Windows PowerShell 5.1 does not surface
    # hashtable keys to Sort-Object's -Property lookup, so sorting a list of
    # hashtables by .Start returns them in an ARBITRARY order rather than
    # failing. Applying the splices out of order invalidates every offset after
    # the first one whose replacement is a different length from what it
    # replaced, and the parse-back guard below then rejects the whole merge -
    # which reads to the user as "your settings did not carry forward".
    # install.cmd uses pwsh when it is present and powershell.exe otherwise, so
    # this has to be right on 5.1, not just on 7.
    $edits       = @()   # spans of the shipped text to overwrite
    $addedRatios = @()
    $addedGroups = @()
    $addedKeys   = @()
    $migrated    = [bool]($null -eq $user.PSObject.Properties['throttles'] -and
                          $null -ne $user.PSObject.Properties['ratios'])

    foreach ($p in $shipped.PSObject.Properties) {
        $key = $p.Name
        if ($key -like '_comment*') { continue }
        if ($key -eq 'configVersion') { continue }

        $span = Get-JsonValueSpan -Raw $shippedRaw -Key $key
        if (-not $span) { continue }

        if ($key -eq 'throttles') {
            # The one key that merges rather than being taken wholesale, and the
            # only one that has to look at the user's file as a whole rather
            # than at a single value - a v1 config keeps this key's contents
            # spread across three top-level keys.
            $userGroups = @(ConvertTo-ThrottleGroups -Config $user)
            if ($userGroups.Count -eq 0) { continue }

            $m = Merge-ThrottleGroups -UserGroups $userGroups `
                                      -ShippedGroups @(ConvertTo-ThrottleGroups -Config $shipped)
            $addedRatios += $m.AddedRatios
            $addedGroups += $m.AddedGroups

            $edits += [pscustomobject]@{
                Start = $span.Start
                End   = $span.End
                Text  = (Format-ThrottleGroups -Groups $m.Groups -NewLine $nl)
            }
            continue
        }

        $userProp = $user.PSObject.Properties[$key]
        if ($null -eq $userProp) { $addedKeys += $key; continue }

        # Everything else is the user's, verbatim. Splicing their raw text
        # rather than a re-serialised value keeps objects, arrays and string
        # quoting exactly as they wrote them.
        $userSpan = Get-JsonValueSpan -Raw $userRaw -Key $key
        if (-not $userSpan) { continue }
        $edits += [pscustomobject]@{
            Start = $span.Start
            End   = $span.End
            Text  = $userRaw.Substring($userSpan.Start, $userSpan.End - $userSpan.Start)
        }
    }

    # Apply back to front so the earlier offsets stay valid. Sorted on an
    # explicit expression rather than a property name, so the ordering cannot
    # depend on how the records expose their members.
    $out = $shippedRaw
    foreach ($e in ($edits | Sort-Object -Property @{ Expression = { [int]$_.Start } } -Descending)) {
        $out = $out.Substring(0, $e.Start) + $e.Text + $out.Substring($e.End)
    }

    try { [void]($out | ConvertFrom-Json) } catch { return $null }
    return @{
        Text        = $out
        AddedRatios = @($addedRatios)
        AddedKeys   = @($addedKeys)
        AddedGroups = @($addedGroups)
        Migrated    = $migrated
    }
}

function Write-MergedConfig {
    <#
        Merge $UserPath into the shipped config and write the result to
        $DestPath. Writes nothing when the merge is a no-op, so reinstalling the
        same version neither churns the file nor leaves a pointless backup.

        Returns $true when the user's settings ended up in $DestPath, whether or
        not anything actually needed writing.
    #>
    param([string]$ShippedPath, [string]$UserPath, [string]$DestPath, [string]$Source, [switch]$Backup)

    $merged = Merge-UserConfig -ShippedPath $ShippedPath -UserPath $UserPath
    if (-not $merged) {
        Write-Warning "  could not read $UserPath - leaving the shipped config.json in place"
        return $false
    }

    $current = ''
    if (Test-Path -LiteralPath $DestPath) { $current = [IO.File]::ReadAllText($DestPath) }
    if ($current -eq $merged.Text) {
        Write-Host '  kept your config.json (already current)'
        return $true
    }

    $what = @()
    # The migration is the headline when it happens: the file's shape changed,
    # which is worth saying out loud even though nothing about it behaves
    # differently afterwards.
    if ($merged.Migrated)            { $what += 'moved your ratio table and device filter into a throttle group (config format 1 -> 2)' }
    if ($merged.AddedGroups.Count)   { $what += "added $($merged.AddedGroups.Count) new throttle(s): $($merged.AddedGroups -join ', ')" }
    # Names only while the list is short enough to read. A release that widens
    # the default table adds dozens at once, and naming all of them buries
    # everything else this summary says - the count is the useful part, and the
    # config manager shows the names.
    if ($merged.AddedRatios.Count -gt 6) {
        $what += "added $($merged.AddedRatios.Count) new aircraft to your ratio table"
    } elseif ($merged.AddedRatios.Count) {
        $what += "added $($merged.AddedRatios.Count) new aircraft: $($merged.AddedRatios -join ', ')"
    }
    if ($merged.AddedKeys.Count)     { $what += "added $($merged.AddedKeys.Count) new setting(s): $($merged.AddedKeys -join ', ')" }
    if ($what.Count -eq 0)           { $what += 'kept every setting you had' }

    if (-not $PSCmdlet.ShouldProcess($DestPath, "Merge config.json from $Source - " + ($what -join '; '))) {
        return $true
    }

    if ($Backup -and (Test-Path -LiteralPath $DestPath)) {
        $bak = "$DestPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $DestPath -Destination $bak -Force
        Write-Host "  backed up config.json -> $(Split-Path $bak -Leaf)"
    }
    [IO.File]::WriteAllText($DestPath, $merged.Text, (New-Object Text.UTF8Encoding($false)))

    Write-Host "  carried your config.json forward from $Source"
    foreach ($w in $what) { Write-Host "    - $w" }
    return $true
}

function Write-ReplacedConfig {
    <#
        Install the shipped config.json over the user's, keeping theirs as a
        timestamped .bak beside it.

        The counterpart to Write-MergedConfig, for a release whose fix IS a
        shipped value. A merge is additive by design - it only adds keys and
        ratio rows the user does not already have - so a corrected default for
        an aircraft they already have a row for would never reach them. This
        path is how that correction lands.

        The backup is unconditional, unlike the merge path's, because a replace
        always discards something: the user's file either goes under the shipped
        one or, when it lives in a prior install's folder, is left behind
        uncarried. Either way the only copy of what they had tuned is the .bak,
        so it is written even when the caller did not ask for one.

        Returns $true when $DestPath holds this version's config, matching
        Write-MergedConfig's contract so the two are interchangeable.
    #>
    param([string]$ShippedPath, [string]$UserPath, [string]$DestPath, [string]$Source)

    try { $shippedText = [IO.File]::ReadAllText($ShippedPath) } catch {
        Write-Warning "  could not read $ShippedPath - leaving config.json alone"
        return $false
    }

    # An upgrade has already copied the shipped file to $DestPath by the time
    # the legacy and prior-install callers run, so the write below is a no-op
    # for them - what matters there is the backup, and not carrying the old
    # file forward. Only the in-place reinstall has the user's file sitting at
    # $DestPath itself.
    $current = ''
    if (Test-Path -LiteralPath $DestPath) { $current = [IO.File]::ReadAllText($DestPath) }

    $userExists = (Test-Path -LiteralPath $UserPath)
    $userText   = if ($userExists) { [IO.File]::ReadAllText($UserPath) } else { '' }
    if ($current -eq $shippedText -and (-not $userExists -or $userText -eq $shippedText)) {
        Write-Host '  kept your config.json (already this version''s defaults)'
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess($DestPath, "Replace config.json with this version's defaults (yours from $Source is backed up)")) {
        return $true
    }

    if ($userExists) {
        # Named for the destination, not the source, so a config carried from a
        # prior install lands in the new install's lib\ folder - where someone
        # looking for what they lost will actually look.
        $bak = "$DestPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $UserPath -Destination $bak -Force
        Write-Host "  backed up your config.json -> $(Split-Path $bak -Leaf)"
    }

    if ($current -ne $shippedText) {
        [IO.File]::WriteAllText($DestPath, $shippedText, (New-Object Text.UTF8Encoding($false)))
    }

    Write-Host "  replaced config.json with this version's defaults"
    Write-Host "    - this release corrects settings that shipped wrong, so it does not"
    Write-Host "      merge; your previous file is the .bak above"
    Write-Host "    - reinstall with -KeepConfig to merge yours forward instead"
    return $true
}

function Write-UserConfig {
    <#
        Hand a config.json off to whichever path this release uses, so the
        three call sites below stay identical whichever way $configPolicy is
        set and neither path can rot from disuse.

        -ForceConfig and -KeepConfig are the per-install overrides, one for
        each direction: -ForceConfig replaces on a Merge release, -KeepConfig
        merges on a Replace one. -ForceConfig is handled by the caller, which
        has to skip the merge before it copies rather than after.
    #>
    param([string]$ShippedPath, [string]$UserPath, [string]$DestPath, [string]$Source, [switch]$Backup)

    if ($configPolicy -eq 'Replace' -and -not $KeepConfig) {
        return (Write-ReplacedConfig -ShippedPath $ShippedPath -UserPath $UserPath `
                                     -DestPath $DestPath -Source $Source)
    }
    return (Write-MergedConfig -ShippedPath $ShippedPath -UserPath $UserPath `
                               -DestPath $DestPath -Source $Source -Backup:$Backup)
}

$shortcutName = 'WinWing Afterburner Ratios.lnk'

function Get-StartMenuDir {
    # Per-user Programs folder: no admin needed, and it is what Start searches.
    Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
}

function Remove-Shortcut {
    $lnk = Join-Path (Get-StartMenuDir) $shortcutName
    if (Test-Path -LiteralPath $lnk) {
        if ($PSCmdlet.ShouldProcess($lnk, 'Remove shortcut')) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Host "  removed Start Menu shortcut"
        }
    }
}

function New-Shortcut {
    <#
        A Start Menu entry so nobody has to dig five levels into Saved Games.

        It targets wscript.exe with the hidden shim rather than the .cmd, so
        launching from Start opens the window with no console flash at all.

        The target path contains the version, so this must be recreated on every
        upgrade - Remove-Shortcut runs first and the previous version's folder is
        deleted afterwards, which would otherwise leave a dead shortcut behind.
    #>
    param([string]$Dcs)

    $sep    = [IO.Path]::DirectorySeparatorChar
    $libDir = Join-Path (Join-Path (Join-Path $Dcs 'Scripts') $projectName) 'lib'
    $shim   = Join-Path $libDir 'run-hidden.vbs'
    if (-not (Test-Path -LiteralPath $shim)) { return }
    $icon   = Join-Path $libDir 'app.ico'

    $dir = Get-StartMenuDir
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'Create')) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $lnk = Join-Path $dir $shortcutName

    if (-not $PSCmdlet.ShouldProcess($lnk, 'Create shortcut')) { return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
        $sc.Arguments        = '"' + $shim + '" config-manager-gui.ps1'
        $sc.WorkingDirectory = $libDir
        $sc.Description      = "Edit afterburner detent ratios (v$version)"
        # Without this the entry wears wscript.exe's generic script icon, which
        # says nothing about what it opens. Missing icon is not worth failing
        # the shortcut over, so it is only set when the file is actually there.
        if (Test-Path -LiteralPath $icon) { $sc.IconLocation = "$icon,0" }
        $sc.Save()
        Write-Host "  Start Menu shortcut: $shortcutName"
    } catch {
        Write-Warning "  could not create the Start Menu shortcut: $($_.Exception.Message)"
    }
}

function Get-ShortcutAction {
    <#
        Decide what happens to the Start Menu entry: 'create', 'remove', or
        'skip' - leave whatever is there alone.

        The question is asked on every install, not only the first, because
        earlier versions created the shortcut without asking: someone who never
        wanted one has no way to say so except here, so answering no removes the
        entry they never agreed to. Answering yes still goes through a remove
        and a recreate, since the target path carries the version and a shortcut
        left pointing at the previous folder would be dead by the end of this
        run.

        -NoShortcut stays a narrower thing than "no": it skips creation and
        leaves an existing shortcut in place. Removing what is already there is
        a different decision, and a scripted install should not make it.
    #>
    if ($NoShortcut) { return 'skip' }
    if ($Shortcut)   { return 'create' }

    # -WhatIf answers yes so the dry run still reports the shortcut it would
    # create, and a non-interactive run keeps the long-standing behaviour;
    # -NoShortcut is the documented way to opt out of a scripted install.
    if ($WhatIfPreference)      { return 'create' }
    if (-not (Test-Interactive)) { return 'create' }

    $existing = Test-Path -LiteralPath (Join-Path (Get-StartMenuDir) $shortcutName)

    Write-Host ''
    Write-Host 'A Start Menu shortcut opens the ratio editor without digging'
    Write-Host 'through Saved Games. Nothing else depends on it.'
    if ($existing) { Write-Host 'You have one now - answering no removes it.' }
    while ($true) {
        $ans = (Read-Host 'Add a Start Menu shortcut? (Y/n)').Trim()
        if ([string]::IsNullOrWhiteSpace($ans)) { return 'create' }
        if ($ans -match '^(?i)(y|yes)$')        { return 'create' }
        if ($ans -match '^(?i)(n|no)$')         { return 'remove' }
        Write-Warning 'Answer y or n.'
    }
}

# ------------------------------------------------------------------- actions --

function Uninstall-FromTarget {
    <# Removes every version of this project, not just the current one. #>
    param([string]$Dcs)
    $scriptsDir = Join-Path $Dcs 'Scripts'
    $hooksDir   = Join-Path $scriptsDir 'Hooks'
    $removed    = 0

    foreach ($d in @(Get-PriorInstalls -ScriptsDir $scriptsDir -Current '') ) {
        if ($PSCmdlet.ShouldProcess($d, 'Remove')) {
            Remove-Item -LiteralPath $d -Recurse -Force
            Write-Host "  removed $d"
        }
        $removed++
    }
    foreach ($h in Get-ChildItem -LiteralPath $hooksDir -File -Filter '*.lua' -ErrorAction SilentlyContinue) {
        if (-not (Test-OurHook $h.Name)) { continue }
        if ($PSCmdlet.ShouldProcess($h.FullName, 'Remove')) {
            Remove-Item -LiteralPath $h.FullName -Force
            Write-Host "  removed $($h.FullName)"
        }
        $removed++
    }

    if ($removed -eq 0) { Write-Host '  nothing installed here' }
}

function Install-ToTarget {
    param([string]$Dcs)

    $scriptsDir = Join-Path $Dcs 'Scripts'
    $destDir    = Join-Path $scriptsDir $projectName
    $hooksDir   = Join-Path $scriptsDir 'Hooks'
    $destHook   = Join-Path $hooksDir $hookName

    # Prior installs of this project under any other name or version. Their
    # ratios are lifted into the new config, then they are removed, so exactly
    # one version is ever deployed.
    $priors = @(Get-PriorInstalls -ScriptsDir $scriptsDir -Current $projectName)
    $script:carriedRatios = $false

    foreach ($d in @($scriptsDir, $hooksDir, $destDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            if ($PSCmdlet.ShouldProcess($d, 'Create')) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }
    }

    # config.json lives in lib\ alongside the code that owns it; the GUI is the
    # only thing meant to edit it, so it stays out of the folder the user sees.
    $sep          = [IO.Path]::DirectorySeparatorChar
    $destConfig   = Join-Path $destDir ('lib' + $sep + 'config.json')
    $configExists = Test-Path -LiteralPath $destConfig

    # Copy the whole tree - the payload is no longer flat.
    foreach ($f in Get-ChildItem -LiteralPath $srcDir -Recurse -File) {
        $rel  = $f.FullName.Substring($srcDir.Length).TrimStart($sep)
        $dest = Join-Path $destDir $rel

        if ($rel -ieq ('lib' + $sep + 'config.json') -and $configExists) {
            if (-not $ForceConfig) {
                # Reinstall over an existing config: merge rather than skip, so
                # aircraft and settings added since that file was written show
                # up. Everything already in it is preserved, so this is a no-op
                # unless this package genuinely ships something new.
                if (Write-UserConfig -ShippedPath $f.FullName -UserPath $destConfig `
                                     -DestPath $destConfig -Source 'your existing install' -Backup) {
                    $script:carriedRatios = $true
                    continue
                }
                Write-Host '  kept existing config.json (-ForceConfig to replace)'
                continue
            }
            $backup = "$destConfig.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            if ($PSCmdlet.ShouldProcess($destConfig, 'Back up then overwrite')) {
                Copy-Item -LiteralPath $destConfig -Destination $backup -Force
                Write-Host "  backed up config.json -> $(Split-Path $backup -Leaf)"
            }
        }

        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) {
            if ($PSCmdlet.ShouldProcess($parent, 'Create')) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        }
        if ($PSCmdlet.ShouldProcess($dest, 'Copy')) {
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            Write-Host "  copied $rel"
        }
    }

    # Installs before lib\ kept config.json at the top of this same folder, so
    # an upgrade in place finds no lib\config.json and would otherwise replace
    # the user's settings with the shipped defaults - and leave the old file
    # orphaned where nothing reads it. Merge it across, then remove it.
    $legacyConfig = Join-Path $destDir 'config.json'
    if (-not $configExists -and (Test-Path -LiteralPath $legacyConfig)) {
        if (Write-UserConfig -ShippedPath $destConfig -UserPath $legacyConfig `
                             -DestPath $destConfig -Source 'the previous layout') {
            $script:carriedRatios = $true
        }
    }
    if (Test-Path -LiteralPath $legacyConfig) {
        if ($PSCmdlet.ShouldProcess($legacyConfig, 'Remove config.json left by the previous layout')) {
            Remove-Item -LiteralPath $legacyConfig -Force
            Write-Host '  removed the old top-level config.json'
        }
    }
    foreach ($b in Get-ChildItem -LiteralPath $destDir -File -Filter 'config.json.bak-*' -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($b.FullName, 'Remove stale backup from the previous layout')) {
            Remove-Item -LiteralPath $b.FullName -Force
            Write-Host "  removed stale $($b.Name)"
        }
    }

    # Carry the config forward from whichever prior install has one. Only for a
    # fresh folder: a same-version reinstall has already merged in place above.
    if (-not $configExists -and -not $script:carriedRatios) {
        foreach ($prior in $priors) {
            # Installs before lib\ kept config.json at the top of the folder.
            $priorCfg = Join-Path $prior ('lib' + $sep + 'config.json')
            if (-not (Test-Path -LiteralPath $priorCfg)) { $priorCfg = Join-Path $prior 'config.json' }
            if (-not (Test-Path -LiteralPath $priorCfg)) { continue }
            if (Write-UserConfig -ShippedPath $destConfig -UserPath $priorCfg `
                                 -DestPath $destConfig -Source (Split-Path $prior -Leaf)) {
                $script:carriedRatios = $true
            }
            break
        }
    }

    # A true replace: drop anything this package does not ship, at any depth.
    # config.json and its backups are user data and are never pruned.
    $packaged = @(Get-ChildItem -LiteralPath $srcDir -Recurse -File |
                  ForEach-Object { $_.FullName.Substring($srcDir.Length).TrimStart($sep) })
    foreach ($old in Get-ChildItem -LiteralPath $destDir -Recurse -File) {
        $rel  = $old.FullName.Substring($destDir.Length).TrimStart($sep)
        $leaf = Split-Path -Leaf $rel
        if ($packaged -contains $rel) { continue }
        if ($leaf -eq 'config.json' -or $leaf -like 'config.json.bak-*') { continue }
        if ($PSCmdlet.ShouldProcess($old.FullName, 'Remove file not in this package')) {
            Remove-Item -LiteralPath $old.FullName -Force
            Write-Host "  removed stale $rel"
        }
    }

    # Hook: substitute the version-stamped folder name into the placeholders.
    if ($PSCmdlet.ShouldProcess($destHook, 'Copy')) {
        $hookText = [IO.File]::ReadAllText($srcHook).
                        Replace('@@PROJECT_DIR@@', $projectName).
                        Replace('@@VERSION@@', $version)
        [IO.File]::WriteAllText($destHook, $hookText, (New-Object Text.UTF8Encoding($false)))
        Write-Host "  installed $hookName"
    }

    # Remove every prior version and its hook, last, so a failure above leaves
    # the old install working rather than deleting it and then falling over.
    foreach ($prior in $priors) {
        if ($PSCmdlet.ShouldProcess($prior, 'Remove previous version')) {
            Remove-Item -LiteralPath $prior -Recurse -Force
            Write-Host "  removed previous $(Split-Path $prior -Leaf)"
        }
    }
    foreach ($h in Get-ChildItem -LiteralPath $hooksDir -File -Filter '*.lua' -ErrorAction SilentlyContinue) {
        if ($h.Name -ieq $hookName) { continue }
        if (-not (Test-OurHook $h.Name)) { continue }
        if ($PSCmdlet.ShouldProcess($h.FullName, 'Remove previous hook')) {
            Remove-Item -LiteralPath $h.FullName -Force
            Write-Host "  removed previous hook $($h.Name)"
        }
    }

    if (-not $configExists -and -not $script:carriedRatios) {
        Write-Host '  A starting ratio table is included. Edit it from the Start Menu'
        Write-Host "  ('WinWing Afterburner Ratios') or with launch-config-manager.cmd."
    }
}

# ----------------------------------------------------------------- preflight --

# Why a live DCS has to be waited out rather than worked around.
#
# DCS reads Scripts\Hooks\*.lua once, at process start, so nothing installed
# while it is running takes effect before a restart. An upgrade or uninstall
# does more than nothing, though: Install-ToTarget removes the previous
# version's folder and hook once the new copy is down, which pulls the ground
# out from under the hook DCS already has loaded, and the helper that hook
# launched is live during a mission holding files in that folder open, where
# Remove-Item has no way to succeed. Blocking up front is what lets everything
# below treat the target as its own.
#
# DCS_updater.exe is deliberately not listed. It does not load hooks, and
# blocking on it would stop an install during a routine module download.
$dcsProcessNames = @('DCS', 'DCS_server')

function Get-RunningDcs {
    <#
        Live DCS processes, or an empty array.

        Matched on process name alone. Mapping a running DCS.exe back to a
        particular Saved Games folder is not reliable - the install directory
        and the Saved Games directory are unrelated paths, and a user can have
        stable and beta - so any live DCS blocks every target.

        .Path is deliberately never read: it is access-denied for a process
        owned by another user or running elevated, and those are exactly the
        ones this still has to see. Get-Process -Name itself does not need the
        rights that reading .Path does.
    #>
    return @(Get-Process -Name $dcsProcessNames -ErrorAction SilentlyContinue)
}

function Format-RunningDcs {
    param($Processes)
    # Get-Process reports the name without .exe; put it back, it is what the
    # user sees in Task Manager and in the DCS shortcut.
    return (($Processes | ForEach-Object { "$($_.Name).exe, PID $($_.Id)" }) -join '; ')
}

function Confirm-DcsClosed {
    <#
        Preflight gate. Runs before targets are resolved, so a blocked run shows
        no prompts, writes no file and touches no shortcut.

        There is deliberately no override switch. Everything past this point
        assumes it has the target folder to itself: the copy overwrites files
        the running helper holds open, and an upgrade deletes the folder the
        loaded hook is still resolving against. Waiting is free, since hooks
        are read once at launch and nothing installed now takes effect before
        a restart either way.

        -WhatIf reports the condition and carries on. A dry run changes nothing,
        and someone checking what an upgrade would do is the last person who
        should be made to quit DCS first.
    #>

    $rechecked = $false

    while ($true) {
        $procs = Get-RunningDcs

        if ($procs.Count -eq 0) {
            if ($rechecked) { Write-Host 'DCS is closed - continuing.'; Write-Host '' }
            return
        }

        $found = Format-RunningDcs $procs

        Write-Host ''
        Write-Host "DCS is running ($found)."
        Write-Host ''
        if ($Uninstall) {
            Write-Host 'This session has the installed files open, and the helper keeps'
            Write-Host 'writing ratios to the throttle until DCS exits.'
        } else {
            Write-Host 'Hooks load when DCS starts, so an install only takes effect on the'
            Write-Host 'next launch. An update also replaces files this session has open.'
        }
        Write-Host ''

        if ($WhatIfPreference) {
            Write-Host 'Continuing anyway: -WhatIf only reports, it changes nothing.'
            Write-Host ''
            return
        }

        # The common case is a double-clicked install.cmd with DCS open on
        # another monitor, so wait for it rather than making them start over.
        # Nothing to wait with when there is no console.
        if (-not (Test-Interactive)) {
            Write-Host 'Close DCS, then run this again.'
            Write-Host ''
            exit 1
        }

        $ans = Read-Host 'Close DCS, then press Enter to check again, or Q to quit'
        if ($ans -match '^(?i)\s*q') {
            Write-Host ''
            Write-Host 'Cancelled - nothing was changed.'
            exit 1
        }
        $rechecked = $true
    }
}

# ---------------------------------------------------------------------- main --

# Source keeps the plain, unversioned names so the repo has a stable layout and
# clean diffs; the version suffix is applied only on the way out.
$srcDir  = Join-Path $repo "Scripts\$baseName"
$srcHook = Join-Path $repo "Scripts\Hooks\$baseName-hook.lua"
foreach ($p in @($srcDir, $srcHook)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing source '$p' - is this a complete copy of the package?" }
}

# Before anything is resolved or prompted for: a run blocked here has to leave
# the disk exactly as it found it.
Confirm-DcsClosed

$targets = @(Resolve-Targets)
if ($targets.Count -eq 0) {
    Write-Host 'Cancelled - nothing was changed.'
    return
}

Write-Host ''
Write-Host ("Target{0}:" -f $(if ($targets.Count -gt 1) { "s ($($targets.Count))" } else { '' }))
$targets | ForEach-Object { Write-Host "  $_" }
Write-Host ''

foreach ($t in $targets) {
    Write-Host $t
    if ($Uninstall) { Uninstall-FromTarget -Dcs $t } else { Install-ToTarget -Dcs $t }
    Write-Host ''
}

# One Start Menu entry, not one per DCS folder. -NoShortcut must leave an
# existing shortcut alone rather than delete it: skipping creation and removing
# what is already there are different things.
if ($Uninstall) {
    Remove-Shortcut
} else {
    $shortcutAction = Get-ShortcutAction
    if ($shortcutAction -ne 'skip') {
        # Remove first either way - the shortcut points at a version-stamped
        # path, so a stale one would survive the upgrade pointing at a folder
        # that no longer exists.
        Remove-Shortcut
        if ($shortcutAction -eq 'create') { New-Shortcut -Dcs $targets[0] }
    }
}

if ($Uninstall) {
    Write-Host 'Uninstalled. The throttle keeps whatever ratio was last written;'
    Write-Host 'run helper.ps1 -Restore first if you want it back to neutral.'
    return
}

Write-Host 'Installed. Start a mission, then check:'
foreach ($t in $targets) { Write-Host "  $(Join-Path $t "Logs\$baseName.log")" }
Write-Host ''
Write-Host 'Verify the device is seen first with:'
Write-Host "  & '$(Join-Path $targets[0] "Scripts\$projectName\lib\helper.ps1")' -Devices"
