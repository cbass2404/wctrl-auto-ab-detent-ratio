# wctrl-auto-ab-detent-ratio

**Your WinWing throttle's afterburner detent, set automatically for whatever aircraft you
just jumped into.**

Enter an F/A-18 and the detent moves to your Hornet ratio. Switch to an F-14 and it
follows. Quit DCS and the throttle goes back to neutral so other sims are unaffected.

No more alt-tabbing to SimAppPro every time you change module.

- SimAppPro needed once, to calibrate the detent. Never again after that.
- Nothing to install but this — no Node, Python or .NET. Windows PowerShell only.
- Runs unelevated. No DCS, SimAppPro or WinWing file is modified.

> **Beta.** Working well day to day, but the USB protocol was reverse-engineered, so
> treat it as community software rather than a vendor feature. Bug reports welcome.

---

## Contents

**Getting it running**

- [Setup](#setup) — start here
  - [1. Calibrate the afterburner detent](#1-calibrate-the-afterburner-detent)
  - [2. Install](#2-install)
  - [3. Check your ratios](#3-check-your-ratios)
  - [4. Per-aircraft DCS settings](#4-per-aircraft-dcs-settings) — the F-14 needs one
  - [5. Check it works](#5-check-it-works)
- [Updating and uninstalling](#updating-and-uninstalling)
- [Troubleshooting](#troubleshooting) — something is not working

**Background** — none of this is needed to use the tool

- [How it works](#how-it-works)
  - [Why this works without SimAppPro](#why-this-works-without-simapppro)
  - [How it triggers](#how-it-triggers)
  - [Which device it touches](#which-device-it-touches)
  - [Matching rules](#matching-rules) — how an aircraft name picks a ratio
    - [Keeping the fallback current](#keeping-the-fallback-current)
  - [Restoring to neutral](#restoring-to-neutral) — what happens when you quit DCS
    - [restoreRatio vs noMatchRatio](#restoreratio-vs-nomatchratio)
  - [Install internals](#install-internals)
    - [Finding your DCS folder](#finding-your-dcs-folder)
    - [Versions](#versions)
    - [What an install replaces](#what-an-install-replaces)
    - [Repository layout](#repository-layout)
  - [Manual use](#manual-use) — the command line options
  - [Wire protocol (reverse-engineered)](#wire-protocol-reverse-engineered)
    - [Config offsets](#config-offsets)
    - [Part discovery](#part-discovery)
    - [Serial encoding](#serial-encoding)
    - [Worked example](#worked-example)
  - [Notes](#notes)

---

## Setup

Five steps, about ten minutes. **Only step 1 needs SimAppPro** — after that you can close
it and leave it closed.

### 1. Calibrate the afterburner detent

**In SimAppPro**, open your throttle and run the afterburner calibration.

When it asks you to set the detent, **push the physical detent all the way to the end of
its track.** That is what the recommended ratios below assume — if your detent sits
somewhere else, the numbers still work but will need more tweaking to feel right.

**This is the only thing SimAppPro is needed for.** Everything after this — the ratio
table, applying ratios, tweaking them — happens in this tool. You can close SimAppPro and
leave it closed.

The step is required: until the detent is calibrated there is no reference point to scale
against, and this tool will refuse to touch the device (it uses that calibration to
identify the right throttle in the first place).

### 2. Install

**Download the [latest release](../../releases), extract it, and double-click
`install.cmd`.** That is the whole install.

It finds your DCS folder — or asks, if you have more than one — and copies itself in.

<details>
<summary>Why <code>install.cmd</code> and not the PowerShell script?</summary>

Windows will not run a `.ps1` on double-click; the extension has no `Open` verb, so it
opens in an editor. That is a deliberate security control, and you should **not**
re-associate `.ps1` to work around it — that makes every PowerShell script on the machine
runnable with one click.

There is a second obstacle: the default `RemoteSigned` execution policy refuses an
unsigned script carrying the Mark of the Web, which everything extracted from a
downloaded zip has.

`install.cmd` handles both. Explorer executes `.cmd` directly, and it launches PowerShell
with `-ExecutionPolicy Bypass` for that one process only — nothing machine-wide changes.

</details>

### 3. Check your ratios

It ships with a table that works well with the detent at the end of its track, so you may
not need to change anything:

| Aircraft | Ratio | | Aircraft | Ratio |
|---|---|---|---|---|
| `NONE` | 100 | | `MiG-21` | 91 |
| `F-4` | 70 | | `MiG-29` | 60 |
| `FA-18` | 82 | | `AJS37` | 81 |
| `F-14` | 54 | | `F-5` | 82 |
| `F-15` | 80 | | `F4U` | 75 |
| `F-16` | 75 | | `C-130` | 75 |

To change them, open **WinWing Afterburner Ratios** from the Start Menu — the installer
adds it, so you never need to go near the DCS folders.

Add, edit and delete aircraft, and hit **Activate** to push a ratio straight to the
throttle so you can feel it without launching DCS. Edits apply to a running DCS within a
couple of seconds, so you can tune from the cockpit.

The name is matched as a **case-insensitive substring** of the DCS aircraft name, so
`FA-18` covers `FA-18C_hornet`. On several matches the longest name wins. **`NONE` is the
fallback** for anything unmatched — keep it in the list.

> Edit ratios through this window rather than by hand. `config.json` now lives in the
> `lib` folder with the code that owns it, and hand edits are an easy way to end up with
> a file the tool cannot read.

### 4. Per-aircraft DCS settings

Most aircraft need nothing here. The **F-14 is the exception** — Heatblur implements its
own detent handling, so DCS needs to agree with your throttle.

In DCS: **Options → Controls → F-14B → Special** tab:

| Setting                       | Value    |
| ----------------------------- | -------- |
| `Afterburner Detent`          | **54.5** |
| `Afterburner Detent Deadzone` | **1**    |

Both may need minor tweaking for your throttle. If the burner lights just before or just
after the physical detent clicks, adjust `Afterburner Detent` by a few tenths.

### 5. Check it works

Launch DCS, jump into an aircraft, and look at:

```
Saved Games\DCS\Logs\wctrl-auto-ab-detent-ratio.log
```

You should see something like:

```
[info] v2.0.0-alpha listening on 127.0.0.1:16537; restore target Inactivated
[info] aircraft 'FA-18C_hornet' -> 82% (matched 'FA-18')
[info] afterburner ratio Inactivated -> 82% for FA-18C_hornet
```

Changing aircraft mid-session works too, and so does editing a ratio in SimAppPro while
DCS is running — it is picked up within a couple of seconds and re-applied to the aircraft
you are already sitting in.

---

## Updating and uninstalling

Download the new release and double-click `install.cmd` again. Your ratios and settings
carry over, the old version is removed, and the Start Menu shortcut is repointed at the
new one.

```powershell
install.cmd -Uninstall     # remove it entirely, shortcut included
install.cmd -WhatIf        # show what would change, without doing it
install.cmd -All           # install to every DCS folder found
install.cmd -NoShortcut    # skip the Start Menu shortcut
```

---

## Troubleshooting

**Nothing in the log, or no log at all.**
Check `Saved Games\DCS\Logs\dcs.log` for `WINCTRL-AB` lines. If they are missing, the hook
did not load — confirm `Scripts\Hooks\` contains a `wctrl-auto-ab-detent-ratio-hook-*.lua`.

**"no afterburner-capable throttle part found".**
The detent is not calibrated. Go back to step 1.

**"no device matched deviceNameIncludes".**
You are on different WinWing hardware. Run this to see what is attached:

```powershell
& "$env:USERPROFILE\Saved Games\DCS\Scripts\wctrl-auto-ab-detent-ratio-*\lib\helper.ps1" -Devices
```

Then put a distinctive part of your throttle's name into `deviceNameIncludes` in
`lib\config.json`. Match the **model**, not the brand — the vendor has been WinWing, WinUSA
and WinCtrl in about 18 months, and the brand is baked into the product string.

**An aircraft gets the wrong ratio.**
The longest matching entry wins. Add a more specific entry in the ratio editor, or use
`overrides` in `lib\config.json` to pin an exact DCS aircraft name to a ratio.

**Reporting a bug.** Include the version — it is in the folder name, the hook filename,
and the first line of the log.

---

## How it works

Everything below is background. You do not need any of it to use the tool.

### Why this works without SimAppPro

The afterburner ratio is not a SimAppPro setting. It lives in the **throttle's own
flash memory**. SimAppPro's `SetAfterburnerRatio.vue` does exactly one thing when you
click _Activate_:

```js
Activate(t){ this.$set(this.strength_pct, 0, t.ratio);
  var e = cloneDeep(this.strength_pct); e[0] = 100 - e[0];
  WWTHID_Sync("WriteFlash",{SerialNumber:this.SerialNumber, Offset:"0x11C", Data:e}) }
```

which reaches `WWTHID_JSAPI.WriteFlash(serial, "0x11C", data)` → `WWTHID.dll` → USB HID.
This helper performs the same write directly, so the setting persists on the hardware
and survives SimAppPro being closed or uninstalled.

SimAppPro itself exposes no API for this: its UDP :16536 listener only accepts
`net` / `mission` / `mod` / `addOutput` / `addCommon` / `getOutput` / `original`, and it
runs with no remote-debugging port. Driving its UI was never an option.

### How it triggers

WinWing's own `Scripts/wwt/wwtNetwork.lua` already fans every export message out to
**three** ports:

```lua
w_net.addr = {{ ip="127.0.0.1", port=16535 },   -- SimAppPro2
              { ip="127.0.0.1", port=16536 },   -- SimAppPro1
              { ip="127.0.0.1", port=16537 }}   -- debug
```

Only `16536` is bound (by SimAppPro). Binding **16537** yields
`{"func":"mod","msg":"FA-18C_hornet"}` on aircraft change, a heartbeat every 3 s, and
`{"func":"mission","msg":"stop"}` at mission end — with zero edits to any DCS or
WinWing file.

The DCS hook additionally sends the same `mod` message itself. That is deliberate:
`wwtExport.lua` emits `mod` only when the name _changes_, so if the helper were still
starting up that single datagram would be lost forever. The hook also covers the case
where the wwt export is disabled entirely.

### Which device it touches

Nothing is hardcoded. At startup the helper enumerates every WinWing HID device
(VID `0x4098`), then narrows by two independent gates:

1. **`deviceNameIncludes`** — case-insensitive substrings; a device qualifies if its
   product name contains **any** of them. Default `[ "Orion Throttle Base II" ]`.
2. **Programmed afterburner calibration** at `0x114`/`0x118`, which picks the base out
   of the base + handles assembly.

The part id (`0xBE60` here) is discovered by broadcast, never assumed, so swapping
handles or throttles re-discovers correctly.

Match the **model, not the brand.** The vendor rebranded twice — **WinWing → WinUSA →
WinCtrl** — in roughly 18 months, so the same model reports as `WINWING ...`,
`WINUSA ...` or `WINCTRL ...` depending on how old its firmware is. No brand word
belongs in the filter.

Device selection keys on the **USB vendor id `0x4098`**, which is assigned to the
company rather than the brand and survived all three names — SimAppPro's own
`supportDevice.json` lists `"vid": 16536` for both its `WINWING` and `WINCTRL` entries
of the same hardware.

> Substrings are prefix-friendly: a filter of `"Orion Throttle Base I"` also matches a
> **Base II**, since one name contains the other. Filtering _for_ the Base II is safe
> (a Base I lacks the `II`); filtering for a Base I needs a longer, distinguishing
> string. Use `[]` to accept any WinWing device.

Run `lib\helper.ps1 -Devices` to see what is attached and what the filter allows:

```
deviceNameIncludes = [Orion Throttle Base II]
MATCH  0xBD64  WINCTRL Orion Throttle Base II + F15EX HANDLE L + F15EX HANDLE R
  -    0xBF05  WINCTRL CarrierAce PTO 2
  -    0xBB36  WINCTRL 32 MCDU CAPTAIN
  -    0xBEF0  WINCTRL Orion Combat Rudder Pedals Metal
  -    0xBEDE  WINCTRL CarrierAce UFC + CarrierAce HUD
```

If the filter matches nothing the helper logs what it _did_ find and touches no device.

### Matching rules

1. An exact-name entry in `overrides` wins outright.
2. Otherwise the **aircraft name must contain the table entry's name**, case-insensitively
   (`FA-18C_hornet` contains `FA-18`). Both sides go through `ToUpperInvariant()`, so
   entry names you typed in SimAppPro match regardless of case — `f-4e` matches
   `F-4E-45MC` exactly as `F-4E` does.
3. On multiple matches the **longest entry name wins**, so `F-4E` beats a hypothetical `F-4`.
4. `NONE` never matches by name — it is the fallback when nothing else hits.
5. If there is no `NONE` entry, fall back to `restoreRatio` (75, the throttle's neutral value).

Verified against real DCS module names:

| Aircraft                                  | Result                            |
| ----------------------------------------- | --------------------------------- |
| `FA-18C_hornet`                           | 82 % (matched `FA-18`)            |
| `F-16C_50`                                | 75 % (matched `F-16`)             |
| `F-14B`                                   | 54 % (matched `F-14`)             |
| `AJS37`                                   | 81 % (matched `AJS37`)            |
| `AH-64D_BLK_II`                           | 100 % (no match → `NONE`)         |
| `f-4e-45mc` vs entry `f-4e`               | 70 % (case-insensitive both ways) |
| `F-4E-45MC` with entries `f-4` and `F-4E` | 70 % (longest match wins)         |

The ratio table lives in this tool's own `config.json` and is the single source of truth.
SimAppPro is never read at runtime — it is an Electron app that rewrites its whole config
from memory, so treating it as a live source made this tool hostage to another program's
lifecycle. Edits are made with `launch-config-manager.cmd`, and a running helper picks them up
within two seconds by watching the file's timestamp.

#### Keeping the fallback current

The helper only ever **reads** `config.json`; `launch-config-manager.cmd` is the only thing that
writes it. Saving rewrites just the `ratios` array by locating its span and splicing, so
the `_comment_` keys documenting every setting, the key order, and your other settings
survive byte-for-byte. The file is written BOM-free through a temp file and an atomic
move, and is parsed back before being committed — a save that would produce unreadable
JSON is refused rather than written.

A running helper notices the change within two seconds by watching the file's timestamp,
reloads, and re-applies to the aircraft already in use, so a ratio can be tuned from the
cockpit.

### Restoring to neutral

`restoreRatio` (default **`"clear"`**) is applied on mission stop, on DCS exit, and if
traffic stops for `heartbeatTimeoutMs` (a DCS crash), so other sims are unaffected.

`"clear"` writes `FF FF FF FF` to `0x11C` — the device's **"Inactivated"** state, meaning
no afterburner mapping at all. That is the throttle as it ships, which is what you want
outside DCS. It is what SimAppPro's _Clear configuration_ button does.

**Clearing does not touch the afterburner calibration.** Verified on hardware:

```
before:       0x114=3f 2c 00 00   0x118=bf 2d 00 00   0x11C=19 ff ff ff   (75%)
after clear:  0x114=3f 2c 00 00   0x118=bf 2d 00 00   0x11C=ff ff ff ff   (Inactivated)
restored 75:  0x114=3f 2c 00 00   0x118=bf 2d 00 00   0x11C=19 ff ff ff   (75%)
```

Calibration lives at `0x114`/`0x118` and is untouched, so nothing needs recalibrating.
Set `restoreRatio` to a number 0–100 instead if you would rather leave a specific ratio
applied outside DCS. An unparseable value logs a warning and falls back to `"clear"`.

#### restoreRatio vs noMatchRatio

These are deliberately separate:

| Setting        | When                                                                       | Default                 |
| -------------- | -------------------------------------------------------------------------- | ----------------------- |
| `restoreRatio` | leaving DCS — mission stop, DCS exit, watchdog                             | `"clear"` (Inactivated) |
| `noMatchRatio` | inside DCS, aircraft matched nothing **and** the table has no `NONE` entry | `75`                    |

The first neutralises the throttle for other games; the second keeps it usable in an
unrecognised aircraft. Conflating them would either neutralise the throttle mid-flight
or leave a DCS ratio applied in other sims.

### Install internals

#### Finding your DCS folder

- **One DCS folder** — used automatically.
- **Several** (multiple variants, or several users on the PC) — it lists them and asks
  which, or `A` for all.
- **None** — it asks for the path and validates it before copying anything.
- **Non-interactive** (piped, CI) — it will not hang on a prompt; pass `-SavedGames`.

The location comes from the Windows _known folder_ API rather than assuming
`%USERPROFILE%\Saved Games`, so a Saved Games folder relocated to another drive still
resolves. Other user profiles are scanned too; anything unreadable is skipped.

Folder _names_ are not hardcoded — DCS's `dcs_variant.txt` can rename the folder (that is
where `DCS.openbeta` came from). A candidate has to contain one of `Config`, `Logs`,
`Mods` or `Scripts`, because modules store their own data in similarly named folders:
one real machine had `DCS`, `DCS_F14`, `DCS_F4E`, `DCS_AJS37`, `DCS_OH58D` and
`DCS.C130J` side by side, where only the first was a DCS root.

#### Versions

The deployed folder and hook carry the version from the repo's `VERSION` file:

```
Scripts\wctrl-auto-ab-detent-ratio-0.1-alpha
Scripts\Hooks\wctrl-auto-ab-detent-ratio-hook-0.1-alpha.lua
```

The version is the **suffix** in both, so they sort together and read consistently.

So a bug report identifies its build at a glance, and `helper.ps1 -Status` reports it too.
The repo keeps the plain unversioned names; the suffix is applied on the way out.

Each version installs into its **own folder**, and installing removes every other version
and its hook — two hooks loaded at once would fire every event twice. Only one thing is
carried across an upgrade:

```
carried over 11 ratios from wctrl-auto-ab-detent-ratio-0.1-alpha
removed previous wctrl-auto-ab-detent-ratio-0.1-alpha
removed previous hook wctrl-auto-ab-detent-ratio-0.1-alpha-hook.lua
```

**`ratios` is the only key that migrates.** Every other setting is re-created from the new
version's shipped `config.json`, which means config keys can be added, renamed or dropped
between releases without a migration path — the new version simply starts from its own
defaults. That is the point of versioned folders rather than upgrading in place.

The log file stays unversioned (`Logs\wctrl-auto-ab-detent-ratio.log`) so it is always in
the same place; each run records its version in the first line.

#### What an install replaces

Installing is a **complete replace of the program files**, not a merge:

- every shipped file is overwritten;
- any file left over from an older version that this package no longer ships is
  **removed**, so an update cannot leave a stale module behind;
- an install under an older _project name_ is removed too, since two hooks loading at
  once would double every event;
- installing into a DCS folder with no `Scripts` directory works — it is created.

The single exception is **`config.json`, which is yours and is kept.** It holds your
settings and your mirrored ratio table, and anyone who has since uninstalled SimAppPro
has no other copy of it. Use `-ForceConfig` to replace it anyway; the previous file is
backed up to `config.json.bak-<timestamp>` first.

#### Repository layout

```
Scripts/                                   mirrors DCS Saved Games\Scripts
  Hooks/wctrl-auto-ab-detent-ratio-hook.lua   auto-loaded by DCS; starts the helper
  wctrl-auto-ab-detent-ratio/
    launch-config-manager.cmd              the only file a user runs
    lib/                                   everything else, kept out of the way
      helper.ps1        UDP listener, aircraft->ratio matching, flash writes, watchdog
      WinctrlHid.ps1    Win32 HID layer + the reverse-engineered wire protocol
      config-manager-gui.ps1   the ratio editor window
      config.json       settings + the ratio table (source of truth)
      run-hidden.vbs    starts a script with no console window
install.cmd                                the installer - double-click this
VERSION                                    single source of truth for the version
tools/
  deploy.ps1                               does the work; install.cmd wraps it
  Test-Syntax.ps1                          syntax gate                          (dev)
  release.cmd                              tag and push a release               (dev)
```

### Manual use

```powershell
.\helper.ps1 -Devices     # every WinWing device, and which the filter allows
.\helper.ps1 -Status      # device, part, current ratio, active table
.\helper.ps1 -Apply 82    # set a ratio once
.\helper.ps1 -Restore     # back to restoreRatio
```

Log: `Saved Games\DCS\Logs\wctrl-auto-ab-detent-ratio.log`

---

### Wire protocol (reverse-engineered)

Captured by setting `"HIDLog": true` in `%APPDATA%\SimAppPro\config.json` (read only at
startup), clicking _Activate_ twice, and reading `%APPDATA%\WWTHID\SimAppPro\WWTHID.log`;
then confirmed by live probing.

Output report is **14 bytes** (`OutputReportByteLength`):

```
byte  0     0x02        report id  (SimAppPro logs this as "channel:2")
bytes 1-4   id          target part id, little-endian uint32
                        0x00000001 = broadcast to every part
byte  5     len         significant byte count of data
bytes 6-13  data[8]     command payload
```

Input reports use the same layout; report id `0x01` is ordinary joystick state.
**Replies carry the responding part's id with `0x1000` added** (`0xBE60` → `0xCE60`);
WWTHID masks this off before logging.

| Command               | `data`                    | `len` |
| --------------------- | ------------------------- | ----- |
| `REQUEST_DEVICE_HW`   | `01`                      | 1     |
| `REQUEST_DEVICE_FW`   | `02`                      | 1     |
| `REQUEST_DEVICE_SN`   | `03`                      | 1     |
| `READ_CFG_DATA`       | `05 oo oo oo`             | 4     |
| `WRITE_CFG_DATA`      | `06 oo oo oo dd dd dd dd` | 8     |
| `REQUEST_DEVICE_MODE` | `18`                      | 1     |
| `ONLINE_HEARTBEAT`    | `00`                      | 1     |

`oo oo oo` is a 24-bit little-endian config offset.

#### Config offsets

| Offset                    | Meaning                                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| `0x09C`, `0x0A0`, `0x0A4` | 12-byte device serial, three 4-byte chunks                                                  |
| `0x114`, `0x118`          | afterburner calibration points; all-`FF` = not calibrated                                   |
| `0x11C`                   | afterburner ratio — **byte 0 = `100 - percent`**, bytes 1–3 preserved, `0xFF` = Inactivated |

#### Part discovery

Send any command with `id = 01 00 00 00` and every sub-part answers with its own id.
On an Orion Throttle Base II + F15EX handles that is `0xBF01`, `0xBF02` (handles) and
`0xBE60` (base). The base is identified as the afterburner-capable part because its
`0x114`/`0x118` calibration words are programmed — so no part id is hardcoded.

#### Serial encoding

The serial reported in the HID descriptor is the **nibble-swapped** form of the raw
flash bytes SimAppPro displays:

| Source                            | Value                      |
| --------------------------------- | -------------------------- |
| Flash `0x09C`–`0x0A7` / SimAppPro | `1A2B3C4D5E6F70819293A4B5` |
| HID descriptor string             | `A1B2C3D4E5F6071829394A5B` |

_(illustrative values — check your own with `helper.ps1 -Status`)_

Every byte has its nibbles swapped (`2E`→`E2`, `06`→`60`, `4D`→`D4`, …).

#### Worked example

```
send  02 | 60 be 00 00 | 04 | 05 1c 01 00 00 00 00 00     read 0x11C
recv  02 | 60 ce 00 00 | 08 | 05 1c 01 00 19 ff ff ff     0x19 = 25 -> 75%
send  02 | 60 be 00 00 | 08 | 06 1c 01 00 2e ff ff ff     write 0x2E = 46 -> 54%
recv  02 | 60 ce 00 00 | 04 | 06 1c 01 00 00 00 00 00     ack
```

### Notes

- HID access to these devices does **not** require administrator rights.
  `SimAppPro.exe` requests elevation (`highestAvailable` manifest) for driver/registry
  work, not for device I/O — `WCtrlDcsBiosBridge.exe` drives the same hardware
  as `asInvoker`.
- SimAppPro's `WWTHID_JSAPI.node` was rejected as an alternative: it is 32-bit x86,
  built against the raw V8 API of Electron 8.3.0 / Node 12.13.0, so hosting it would
  need a matching legacy 32-bit runtime or a UAC prompt on every mission start.
- The helper only ever writes offset `0x11C`. Calibration and serial regions are
  read-only to it.
