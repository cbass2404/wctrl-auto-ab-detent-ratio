@echo off
setlocal enabledelayedexpansion

rem  tools\release.cmd - tag and push a release. Maintainer tool.
rem
rem  Order of checks:
rem    1. working tree / branch state - warns and asks before continuing
rem    2. tag from VERSION must not already exist, locally or on origin
rem    3. asks for a release message; submitting an empty one cancels
rem    4. pushes the branch, then the tag
rem
rem  Pushing the tag is what triggers .github/workflows/release.yml, which
rem  builds and publishes the release.

rem Everything below runs against the repo root, one level up from tools\.
cd /d "%~dp0.."

echo(
echo ===============================================
echo   Release
echo ===============================================
echo(

rem --- must be in a git repo ----------------------------------------------
git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo ERROR: not a git repository.
    goto :fail
)

for /f "usebackq tokens=* delims= " %%b in (`git rev-parse --abbrev-ref HEAD`) do set "BRANCH=%%b"
for /f "usebackq tokens=* delims= " %%c in (`git rev-parse --short HEAD`) do set "COMMIT=%%c"

echo   branch : %BRANCH%
echo   commit : %COMMIT%  (this is what the tag will point at)
echo(

rem ==========================================================================
rem  1. working tree and branch state
rem ==========================================================================

rem Refresh remote refs first, or "not pushed" is judged against stale data.
echo   fetching origin ...
git fetch -q origin >nul 2>&1
echo(

rem Uncommitted: staged, unstaged or untracked. --porcelain covers all three.
set "DIRTY="
for /f "usebackq delims=" %%s in (`git status --porcelain`) do set "DIRTY=1"

rem Unpushed: ahead of upstream, or no upstream at all.
set "AHEAD=0"
set "BEHIND=0"
set "NOUPSTREAM="
git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >nul 2>&1
if errorlevel 1 (
    set "NOUPSTREAM=1"
) else (
    for /f "usebackq tokens=* delims= " %%n in (`git rev-list --count "@{u}..HEAD"`) do set "AHEAD=%%n"
    for /f "usebackq tokens=* delims= " %%n in (`git rev-list --count "HEAD..@{u}"`) do set "BEHIND=%%n"
)

set "WARN="
if defined DIRTY set "WARN=1"
if defined NOUPSTREAM set "WARN=1"
if not "!AHEAD!"=="0" set "WARN=1"
if not "!BEHIND!"=="0" set "WARN=1"

if not defined WARN (
    echo   working tree clean, branch in sync with origin.
    echo(
    goto :state_ok
)

echo   -----------------------------------------------
echo     Heads up
echo   -----------------------------------------------

if defined DIRTY (
    echo(
    echo   Uncommitted changes:
    echo(
    git status --short
    echo(
    echo   These will NOT be in the release. A tag captures only what is
    echo   committed, so anything above is left out.
)

if defined NOUPSTREAM (
    echo(
    echo   Branch '%BRANCH%' has no upstream - it has never been pushed.
)

if not "!AHEAD!"=="0" (
    echo(
    echo   !AHEAD! commit^(s^) not pushed to origin:
    echo(
    git log --oneline "@{u}..HEAD"
    echo(
    echo   These WILL be pushed before the tag.
)

if not "!BEHIND!"=="0" (
    echo(
    echo   origin is !BEHIND! commit^(s^) AHEAD of you.
    echo   Pushing will most likely be rejected - pull first.
)

echo(
echo   -----------------------------------------------
set "SURE="
set /p "SURE=Continue anyway? (y/N): "
if /i "!SURE!"=="y"   goto :state_ok
if /i "!SURE!"=="yes" goto :state_ok
echo(
echo Cancelled - nothing was tagged or pushed.
goto :end

:state_ok

rem ==========================================================================
rem  2. version and tag availability
rem ==========================================================================

if not exist "VERSION" (
    echo ERROR: no VERSION file in %CD%
    goto :fail
)

set "VERSION="
for /f "usebackq tokens=* delims= " %%v in ("VERSION") do (
    if not defined VERSION set "VERSION=%%v"
)
if not defined VERSION (
    echo ERROR: VERSION is empty.
    goto :fail
)

rem Git tags conventionally carry a leading v; the VERSION file may or may not.
set "TAG=%VERSION%"
if /i not "%VERSION:~0,1%"=="v" set "TAG=v%VERSION%"

echo   VERSION file : %VERSION%
echo   tag to create: %TAG%
echo(

rem Check origin first: whether the tag is PUBLISHED decides the remedy. The
rem fetch above pulls remote tags down, so a released tag also shows up locally
rem and reporting it as merely "local" would suggest deleting it - wrong for a
rem tag other people may already have.
echo   checking origin for an existing %TAG% ...
set "ONORIGIN="
git ls-remote --exit-code --tags origin "refs/tags/%TAG%" >nul 2>&1
if not errorlevel 1 set "ONORIGIN=1"

set "ONLOCAL="
git rev-parse -q --verify "refs/tags/%TAG%" >nul 2>&1
if not errorlevel 1 set "ONLOCAL=1"

if defined ONORIGIN (
    echo(
    echo ===============================================
    echo   ERROR: %TAG% has already been released.
    echo ===============================================
    echo(
    echo   The tag exists on origin, so it may already be published and other
    echo   people may have it. A released tag must not be moved.
    echo(
    echo   Bump VERSION to the next version and release that instead.
    goto :fail
)

if defined ONLOCAL (
    echo(
    echo ERROR: tag %TAG% exists locally but not on origin.
    echo(
    echo   It was probably created and never pushed, or pushed and then
    echo   deleted from origin. It may point at an older commit than HEAD.
    echo(
    echo   Delete it and re-run to tag the current commit:
    echo       git tag -d %TAG%
    goto :fail
)

echo   ok, %TAG% is free.
echo(

rem ==========================================================================
rem  3. message doubles as the final confirmation
rem ==========================================================================

echo Enter a release message for %TAG%.
echo Press Enter on an empty line to cancel.
echo(
set "MSG="
set /p "MSG=Message: "

if not defined MSG (
    echo(
    echo Cancelled - nothing was tagged or pushed.
    goto :end
)

rem ==========================================================================
rem  4. tag and push
rem ==========================================================================

echo(
echo Tagging %COMMIT% as %TAG% ...
git tag -a "%TAG%" -m "!MSG!"
if errorlevel 1 (
    echo ERROR: git tag failed.
    goto :fail
)

echo Pushing %BRANCH% ...
git push origin "%BRANCH%"
if errorlevel 1 (
    echo(
    echo ERROR: pushing the branch failed. The local tag was created but not
    echo pushed. Remove it with:  git tag -d %TAG%
    goto :fail
)

echo Pushing %TAG% ...
git push origin "%TAG%"
if errorlevel 1 (
    echo(
    echo ERROR: pushing the tag failed. Remove the local tag with:
    echo     git tag -d %TAG%
    goto :fail
)

echo(
echo ===============================================
echo   Pushed %TAG%
echo ===============================================
echo(
for /f "usebackq tokens=* delims= " %%u in (`git remote get-url origin`) do set "ORIGIN=%%u"
set "ORIGIN=%ORIGIN:.git=%"
echo   The release workflow is now running:
echo     %ORIGIN%/actions
echo(
echo   It will publish here when it goes green:
echo     %ORIGIN%/releases
echo(
goto :end

:fail
echo(
set "RC=1"

:end
if not defined RC set "RC=0"
echo(
pause
exit /b %RC%
