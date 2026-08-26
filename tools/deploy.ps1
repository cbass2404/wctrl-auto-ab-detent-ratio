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

        .\install.cmd                        # install / update; merges config.json
        .\install.cmd -All                   # every DCS folder found, no prompt
        .\install.cmd -SavedGames <p>[,<p>]  # explicit target(s)
        .\install.cmd -WhatIf                # show what would change, touch nothing
        .\install.cmd -ForceConfig           # discard config.json, use the shipped
                                             # defaults instead (backed up first)
        .\install.cmd -NoShortcut            # skip the Start Menu shortcut
        .\install.cmd -Uninstall             # remove the deployed copy
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$SavedGames,
    [switch]$All,
    [switch]$ForceConfig,
    [switch]$NoShortcut,
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

function Format-RatioRows {
    <#
        Render a ratio table as the aligned rows config.json ships with, so a
        merged file is indistinguishable from a hand-edited one. The column
        width follows the longest name rather than being fixed, so one long
        entry does not knock the rest out of line.
    #>
    param([array]$Ratios)
    $w = 9
    foreach ($r in $Ratios) {
        $n = ([string]$r.name).Length + 3
        if ($n -gt $w) { $w = $n }
    }
    # Built up front: -f binds tighter than +, so composing it inline would
    # format the trailing fragment instead of the whole template.
    $fmt  = '        {{ "name": {0,' + (-$w) + '} "ratio": {1} }}'
    $rows = $Ratios | ForEach-Object {
        $fmt -f ('"' + $_.name + '",'), [int]$_.ratio
    }
    return "[" + [Environment]::NewLine + ($rows -join ("," + [Environment]::NewLine)) + [Environment]::NewLine + "    ]"
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
        no longer ships is dropped, because the code that read it is gone.
        _comment keys always come from the shipped file: they are documentation
        rather than user data, and they go stale otherwise.

        Returns @{ Text; AddedRatios; AddedKeys } or $null if either file cannot
        be read, which leaves the caller with the shipped config untouched.
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

    $edits       = @()   # spans of the shipped text to overwrite
    $addedRatios = @()
    $addedKeys   = @()

    foreach ($p in $shipped.PSObject.Properties) {
        $key = $p.Name
        if ($key -like '_comment*') { continue }

        $userProp = $user.PSObject.Properties[$key]
        if ($null -eq $userProp) { $addedKeys += $key; continue }

        $span = Get-JsonValueSpan -Raw $shippedRaw -Key $key
        if (-not $span) { continue }

        if ($key -eq 'ratios') {
            # The one key that merges rather than being taken wholesale: the
            # user's rows win and keep their order and their values, then any
            # name this version ships that they have never seen is appended.
            $userRatios = @($userProp.Value | Where-Object { $_.name } | ForEach-Object {
                [pscustomobject]@{ name = [string]$_.name; ratio = [int]$_.ratio }
            })
            if ($userRatios.Count -eq 0) { continue }

            $have = @{}
            foreach ($r in $userRatios) { $have[$r.name.ToLowerInvariant()] = $true }

            $merged = @($userRatios)
            foreach ($s in @($shipped.ratios | Where-Object { $_.name })) {
                if ($have.ContainsKey(([string]$s.name).ToLowerInvariant())) { continue }
                $merged      += [pscustomobject]@{ name = [string]$s.name; ratio = [int]$s.ratio }
                $addedRatios += [string]$s.name
            }
            $edits += @{ Start = $span.Start; End = $span.End; Text = (Format-RatioRows -Ratios $merged) }
            continue
        }

        # Everything else is the user's, verbatim. Splicing their raw text
        # rather than a re-serialised value keeps objects, arrays and string
        # quoting exactly as they wrote them.
        $userSpan = Get-JsonValueSpan -Raw $userRaw -Key $key
        if (-not $userSpan) { continue }
        $edits += @{
            Start = $span.Start
            End   = $span.End
            Text  = $userRaw.Substring($userSpan.Start, $userSpan.End - $userSpan.Start)
        }
    }

    # Apply back to front so the earlier offsets stay valid.
    $out = $shippedRaw
    foreach ($e in ($edits | Sort-Object -Property Start -Descending)) {
        $out = $out.Substring(0, $e.Start) + $e.Text + $out.Substring($e.End)
    }

    try { [void]($out | ConvertFrom-Json) } catch { return $null }
    return @{ Text = $out; AddedRatios = @($addedRatios); AddedKeys = @($addedKeys) }
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
    if ($merged.AddedRatios.Count) { $what += "added $($merged.AddedRatios.Count) new aircraft: $($merged.AddedRatios -join ', ')" }
    if ($merged.AddedKeys.Count)   { $what += "added $($merged.AddedKeys.Count) new setting(s): $($merged.AddedKeys -join ', ')" }
    if ($what.Count -eq 0)         { $what += 'kept every setting you had' }

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
        $sc.Save()
        Write-Host "  Start Menu shortcut: $shortcutName"
    } catch {
        Write-Warning "  could not create the Start Menu shortcut: $($_.Exception.Message)"
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
                if (Write-MergedConfig -ShippedPath $f.FullName -UserPath $destConfig `
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
        if (Write-MergedConfig -ShippedPath $destConfig -UserPath $legacyConfig `
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
            if (Write-MergedConfig -ShippedPath $destConfig -UserPath $priorCfg `
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

# ---------------------------------------------------------------------- main --

# Source keeps the plain, unversioned names so the repo has a stable layout and
# clean diffs; the version suffix is applied only on the way out.
$srcDir  = Join-Path $repo "Scripts\$baseName"
$srcHook = Join-Path $repo "Scripts\Hooks\$baseName-hook.lua"
foreach ($p in @($srcDir, $srcHook)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing source '$p' - is this a complete copy of the package?" }
}

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
} elseif (-not $NoShortcut) {
    # Remove first - the shortcut points at a version-stamped path, so a stale
    # one would survive the upgrade pointing at a folder that no longer exists.
    Remove-Shortcut
    New-Shortcut -Dcs $targets[0]
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
