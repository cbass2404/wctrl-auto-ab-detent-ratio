<#
    Test-Syntax.ps1 - cheap pre-release syntax gate.

    Checks every shipped source file without needing a Lua interpreter:

      *.ps1   parsed with the real PowerShell parser
      *.lua   scanned for unterminated strings / long brackets / block comments
      *.json  parsed

    The Lua check is not a parser. It exists to catch one specific and easily
    missed class of bug: a backslash before a closing quote. 'Scripts\' looks
    fine at a glance but escapes the quote, so the string runs on and the file
    stops being valid Lua - which DCS only reports at load time.

        .\tools\Test-Syntax.ps1
#>

[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is always the absolute directory of this file; deriving it from
# $MyInvocation.MyCommand.Path breaks when invoked via a relative -File path.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

$problems = @()

function Add-Problem {
    param([string]$File, [int]$Line, [string]$Message)
    $script:problems += [pscustomobject]@{ File = $File; Line = $Line; Message = $Message }
}

function Test-LuaFile {
    <#
        Walk the file tracking whether we are inside a comment or string, and
        report anything still open at end of line (short strings) or EOF.
    #>
    param([string]$Path)

    $text  = [IO.File]::ReadAllText($Path)
    $i     = 0
    $line  = 1
    $len   = $text.Length

    while ($i -lt $len) {
        $c = $text[$i]

        if ($c -eq "`n") { $line++; $i++; continue }

        # long bracket [[ ... ]] / [=[ ... ]=]  (string or comment body)
        if ($c -eq '[') {
            $m = [regex]::Match($text.Substring($i), '^\[(=*)\[')
            if ($m.Success) {
                $eq    = $m.Groups[1].Value
                $close = ']' + $eq + ']'
                $start = $line
                $idx   = $text.IndexOf($close, $i + $m.Length)
                if ($idx -lt 0) { Add-Problem $Path $start "unterminated long bracket [$eq[" ; return }
                $line += ($text.Substring($i, $idx - $i).ToCharArray() | Where-Object { $_ -eq "`n" }).Count
                $i = $idx + $close.Length
                continue
            }
        }

        # comment
        if ($c -eq '-' -and $i + 1 -lt $len -and $text[$i + 1] -eq '-') {
            $rest = $text.Substring($i + 2)
            $m = [regex]::Match($rest, '^\[(=*)\[')
            if ($m.Success) {
                $eq    = $m.Groups[1].Value
                $close = ']' + $eq + ']'
                $start = $line
                $idx   = $text.IndexOf($close, $i + 2 + $m.Length)
                if ($idx -lt 0) { Add-Problem $Path $start "unterminated block comment --[$eq[" ; return }
                $line += ($text.Substring($i, $idx - $i).ToCharArray() | Where-Object { $_ -eq "`n" }).Count
                $i = $idx + $close.Length
                continue
            }
            $nl = $text.IndexOf("`n", $i)
            if ($nl -lt 0) { return }
            $i = $nl
            continue
        }

        # short string - the case that actually bites
        if ($c -eq '"' -or $c -eq "'") {
            $quote = $c
            $start = $line
            $j = $i + 1
            $closed = $false
            while ($j -lt $len) {
                $d = $text[$j]
                if ($d -eq '\') { $j += 2; continue }          # escape consumes next char
                if ($d -eq "`n") { break }                      # short strings cannot span lines
                if ($d -eq $quote) { $closed = $true; break }
                $j++
            }
            if (-not $closed) {
                Add-Problem $Path $start "unterminated $quote string (a backslash before the closing quote escapes it)"
                return
            }
            $i = $j + 1
            continue
        }

        $i++
    }
}

function Test-ControlChars {
    <#
        Reject stray control characters.

        This exists because a careless escape in a generator script rewrote
        ".\tools\deploy.ps1" as ".<TAB>ools\deploy.ps1" and "tools\release.cmd"
        as "tools<CR>elease.cmd" inside the release workflow - \t and \r taken
        as escapes. Both look almost right in a diff and neither is valid: a TAB
        breaks YAML indentation outright, and a lone CR silently truncates the
        line for anything reading it.

        A TAB is flagged in every file type here; none of them need one.
    #>
    param([string]$Path)

    $text = [IO.File]::ReadAllText($Path)
    $line = 1
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = [int]$text[$i]
        if ($c -eq 10) { $line++; continue }
        if ($c -eq 9)  { Add-Problem $Path $line 'contains a TAB - likely a \t escape taken literally'; return }
        if ($c -eq 13) {
            # CR is only legitimate as part of CRLF
            if ($i + 1 -ge $text.Length -or [int]$text[$i + 1] -ne 10) {
                Add-Problem $Path $line 'contains a lone CR - likely a \r escape taken literally'
                return
            }
            continue
        }
        if ($c -lt 32 -and $c -ne 9 -and $c -ne 10 -and $c -ne 13) {
            Add-Problem $Path $line ("contains control character 0x{0:X2}" -f $c)
            return
        }
    }
}

function Test-YamlFile {
    <#
        Not a YAML parser. Checks what actually breaks a workflow and is easy to
        introduce: control characters (handled separately) and indentation that
        is not a multiple of two.

        Block scalars are skipped. The body of a "run: |" step is a shell
        script, not YAML, so its continuation lines are aligned to whatever
        reads best - flagging those would be noise, and a checker people learn
        to ignore is worse than no checker.
    #>
    param([string]$Path)

    $n = 0
    $blockIndent = -1        # indent of the key that opened a block scalar
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        $n++
        if ($l.Trim().Length -eq 0) { continue }
        $indent = $l.Length - $l.TrimStart(' ').Length

        if ($blockIndent -ge 0) {
            if ($indent -gt $blockIndent) { continue }   # still inside the block
            $blockIndent = -1                            # dedented back out
        }

        if ($indent % 2 -ne 0) {
            Add-Problem $Path $n "odd indentation ($indent spaces) - YAML expects multiples of two"
        }

        # "key: |", "key: >-", "- name: x" followed by "run: |" etc.
        if ($l -match ':\s*[|>][-+0-9]*\s*$') { $blockIndent = $indent }
    }
}

Write-Host "Checking sources under $Root"
Write-Host ''

# Filter by extension rather than using -Include: with -Recurse, Windows
# PowerShell 5.1 returns every match twice, which would also double-report any
# problem found. install.cmd falls back to 5.1, so this has to hold there too.
$wanted = @('.ps1', '.lua', '.json', '.yml', '.yaml', '.cmd', '.vbs')
$files = Get-ChildItem -LiteralPath $Root -Recurse -File |
         Where-Object { $wanted -contains $_.Extension.ToLowerInvariant() } |
         Where-Object { $_.FullName -notmatch '\\\.git\\' } |
         Sort-Object FullName

foreach ($f in $files) {
    # Applies to every type: none of these files should contain a TAB or a
    # lone CR, and both are classic symptoms of a mishandled escape.
    Test-ControlChars -Path $f.FullName

    switch ($f.Extension.ToLowerInvariant()) {
        { $_ -in '.yml', '.yaml' } { Test-YamlFile -Path $f.FullName }
        '.ps1' {
            $err = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
            foreach ($e in $err) { Add-Problem $f.FullName $e.Extent.StartLineNumber $e.Message }
        }
        '.lua'  { Test-LuaFile -Path $f.FullName }
        '.json' {
            try { [void](Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) }
            catch { Add-Problem $f.FullName 0 "invalid JSON: $($_.Exception.Message)" }
        }
    }
    Write-Host ("  {0,-6} {1}" -f $f.Extension, $f.FullName.Replace($Root, '').TrimStart('\'))
}

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host "OK - $($files.Count) file(s), no syntax problems."
    exit 0
}

Write-Host "FAILED - $($problems.Count) problem(s):" -ForegroundColor Red
foreach ($p in $problems) {
    Write-Host ("  {0}:{1}  {2}" -f $p.File.Replace($Root, '').TrimStart('\'), $p.Line, $p.Message) -ForegroundColor Red
}
exit 1
