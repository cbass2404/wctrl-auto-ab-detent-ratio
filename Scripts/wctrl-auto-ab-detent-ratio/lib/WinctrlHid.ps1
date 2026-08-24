<#
    WinctrlHid.ps1 - Win32 HID access for WinWing / WinUSA / WinCtrl devices.

    The vendor has rebranded twice (WinWing -> WinUSA -> WinCtrl) in about 18
    months, so the product strings burned into firmware differ between devices
    of the same model. The USB vendor id is assigned to the company rather than
    the brand and has stayed 0x4098 throughout, which is why device selection
    keys on the VID and never on a brand name.

    Pure P/Invoke against setupapi.dll + hid.dll + kernel32.dll, which is what
    SimAppPro's WWTHID.dll does internally (SetupDiGetClassDevs -> CreateFileA ->
    WriteFile/ReadFile + HidD_*). No external runtime or module required.

    ---------------------------------------------------------------------------
    WIRE PROTOCOL  (derived from a WWTHID.log capture + live probing, 2026-08-24)

    Output report, 14 bytes (== OutputReportByteLength):

        byte  0     0x02        report id ("channel:2" in SimAppPro's log)
        bytes 1-4   id          target part id, little-endian uint32
                                0x00000001 = broadcast to every part
        byte  5     len         significant byte count of data
        bytes 6-13  data[8]     command payload

    Input reports use the same layout. Report id 0x01 is ordinary joystick
    state and is ignored here. Replies carry the responding part's id with
    0x1000 ADDED (0xBE60 -> 0xCE60); PART_REPLY_BIAS below normalises it, so a
    broadcast enumerates every part.

    Commands (first data byte):
        01                      REQUEST_DEVICE_HW     len 1
        02                      REQUEST_DEVICE_FW     len 1
        03                      REQUEST_DEVICE_SN     len 1
        05 oo oo oo             READ_CFG_DATA         len 4   offset 24-bit LE
        06 oo oo oo dd dd dd dd WRITE_CFG_DATA        len 8   offset + 4 bytes
        18                      REQUEST_DEVICE_MODE   len 1
        00                      ONLINE_HEARTBEAT      len 1

    Config offsets of interest:
        0x09C,0x0A0,0x0A4   12-byte device serial, three 4-byte chunks
        0x114, 0x118        afterburner calibration (all-FF = uncalibrated)
        0x11C               afterburner ratio: byte0 = 100 - percent,
                            0xFF = "Inactivated"
    ---------------------------------------------------------------------------
#>

# Assigned to the vendor, unchanged across the WinWing/WinUSA/WinCtrl rebrands.
$script:VENDOR_ID        = 0x4098
$script:REPORT_ID        = 0x02
$script:BROADCAST        = 1
$script:PART_REPLY_BIAS  = 0x1000

$script:AB_RATIO_OFFSET  = 0x11C
$script:AB_CAL_OFFSETS   = @(0x114, 0x118)
$script:SERIAL_OFFSETS   = @(0x9C, 0xA0, 0xA4)

if (-not ('Winctrl.Hid' -as [type])) {
    $cs = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Winctrl {

public class HidInfo {
    public string Path;
    public int VendorId;
    public int ProductId;
    public string Product = "";
    public string Serial = "";
    public int InLen;
    public int OutLen;
}

public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
        public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")] public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)] public static extern bool HidD_GetSerialNumberString(IntPtr h, StringBuilder b, int len);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)] public static extern bool HidD_GetProductString(IntPtr h, StringBuilder b, int len);
    [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] public static extern int  HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
    [DllImport("hid.dll")] public static extern bool HidD_SetNumInputBuffers(IntPtr h, int n);

    [DllImport("setupapi.dll", CharSet = CharSet.Auto)] public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll", CharSet = CharSet.Auto)] public static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA a);
    [DllImport("setupapi.dll", CharSet = CharSet.Auto)] public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA a, IntPtr det, int size, ref int req, IntPtr di);
    [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr CreateFile(string n, uint acc, uint share, IntPtr sec, uint disp, uint flags, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool WriteFile(IntPtr h, byte[] b, int n, out int w, IntPtr o);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadFile(IntPtr h, byte[] b, int n, out int r, IntPtr o);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CancelIoEx(IntPtr h, IntPtr o);

    public const uint GENERIC_RW = 0xC0000000;
    public const uint SHARE_RW = 3;
    public const uint OPEN_EXISTING = 3;
    public static readonly IntPtr INVALID = new IntPtr(-1);

    public static List<HidInfo> Enumerate(int vendorId, int productId) {
        var list = new List<HidInfo>();
        Guid g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); // PRESENT|DEVICEINTERFACE
        if (set == INVALID) throw new Exception("SetupDiGetClassDevs failed");
        try {
            for (int i = 0; ; i++) {
                var ifd = new SP_DEVICE_INTERFACE_DATA();
                ifd.cbSize = Marshal.SizeOf(ifd);
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref ifd)) break;

                int need = 0;
                SetupDiGetDeviceInterfaceDetail(set, ref ifd, IntPtr.Zero, 0, ref need, IntPtr.Zero);
                if (need <= 0) continue;

                IntPtr buf = Marshal.AllocHGlobal(need);
                string path = null;
                try {
                    Marshal.WriteInt32(buf, 0, IntPtr.Size == 8 ? 8 : 6);
                    if (SetupDiGetDeviceInterfaceDetail(set, ref ifd, buf, need, ref need, IntPtr.Zero))
                        path = Marshal.PtrToStringAuto(new IntPtr(buf.ToInt64() + 4));
                } finally { Marshal.FreeHGlobal(buf); }
                if (string.IsNullOrEmpty(path)) continue;

                IntPtr h = CreateFile(path, 0, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (h == INVALID) continue;
                try {
                    var at = new HIDD_ATTRIBUTES(); at.Size = Marshal.SizeOf(at);
                    if (!HidD_GetAttributes(h, ref at)) continue;
                    if (at.VendorID != vendorId) continue;
                    if (productId != 0 && at.ProductID != productId) continue;

                    var info = new HidInfo { Path = path, VendorId = at.VendorID, ProductId = at.ProductID };
                    var sb = new StringBuilder(256);
                    if (HidD_GetSerialNumberString(h, sb, 256)) info.Serial = sb.ToString();
                    sb.Clear();
                    if (HidD_GetProductString(h, sb, 256)) info.Product = sb.ToString();

                    IntPtr pp;
                    if (HidD_GetPreparsedData(h, out pp)) {
                        HIDP_CAPS caps; HidP_GetCaps(pp, out caps); HidD_FreePreparsedData(pp);
                        info.InLen = caps.InputReportByteLength;
                        info.OutLen = caps.OutputReportByteLength;
                    }
                    list.Add(info);
                } finally { CloseHandle(h); }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return list;
    }
}

// Blocking ReadFile on a dedicated thread, results delivered through a queue.
// This keeps a silent device from ever hanging the caller and avoids the
// pitfalls of marshalling OVERLAPPED from PowerShell.
public class Hid : IDisposable {
    IntPtr h = Native.INVALID;
    Thread reader;
    volatile bool running;
    readonly BlockingCollection<byte[]> q = new BlockingCollection<byte[]>(1024);
    public int InLen { get; private set; }
    public int OutLen { get; private set; }

    public Hid(string path, int inLen, int outLen) {
        InLen = inLen; OutLen = outLen;
        h = Native.CreateFile(path, Native.GENERIC_RW, Native.SHARE_RW, IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == Native.INVALID)
            throw new Exception("CreateFile failed for " + path + " (win32 " + Marshal.GetLastWin32Error() + ")");
        Native.HidD_SetNumInputBuffers(h, 128);
        running = true;
        reader = new Thread(ReadLoop); reader.IsBackground = true; reader.Start();
    }

    void ReadLoop() {
        while (running) {
            var buf = new byte[InLen];
            int n;
            if (!Native.ReadFile(h, buf, InLen, out n, IntPtr.Zero)) break;
            if (n <= 0) continue;
            if (n != InLen) { var t = new byte[n]; Array.Copy(buf, t, n); buf = t; }
            if (!q.TryAdd(buf)) { byte[] junk; q.TryTake(out junk); q.TryAdd(buf); }
        }
    }

    public void Write(byte[] report) {
        int w;
        if (!Native.WriteFile(h, report, report.Length, out w, IntPtr.Zero))
            throw new Exception("WriteFile failed (win32 " + Marshal.GetLastWin32Error() + ")");
    }

    /// <summary>Next input report, or null on timeout.</summary>
    public byte[] Read(int timeoutMs) {
        byte[] r;
        return q.TryTake(out r, timeoutMs) ? r : null;
    }

    public void Drain() { byte[] junk; while (q.TryTake(out junk)) { } }

    public void Dispose() {
        running = false;
        if (h != Native.INVALID) {
            Native.CancelIoEx(h, IntPtr.Zero);
            Native.CloseHandle(h);
            h = Native.INVALID;
        }
    }
}
}
'@
    Add-Type -TypeDefinition $cs -Language CSharp
}

function Get-WinctrlDevice {
    [CmdletBinding()]
    param([int]$VendorId = $script:VENDOR_ID, [int]$ProductId = 0)
    [Winctrl.Native]::Enumerate($VendorId, $ProductId) | ForEach-Object {
        [pscustomobject]@{
            Path       = $_.Path
            VendorId   = ('0x{0:X4}' -f $_.VendorId)
            ProductId  = ('0x{0:X4}' -f $_.ProductId)
            ProductIdN = $_.ProductId
            Product    = $_.Product
            Serial     = $_.Serial
            InLen      = $_.InLen
            OutLen     = $_.OutLen
        }
    }
}

function Open-WinctrlDevice {
    param([Parameter(Mandatory)]$Device)
    New-Object Winctrl.Hid $Device.Path, $Device.InLen, $Device.OutLen
}

function New-WinctrlFrame {
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [uint32]$PartId = 1,
        [int]$Len = -1,
        [int]$ReportLength = 14
    )
    if ($Len -lt 0) { $Len = $Data.Length }
    $r = New-Object byte[] $ReportLength
    $r[0] = [byte]$script:REPORT_ID
    [Array]::Copy([BitConverter]::GetBytes([uint32]$PartId), 0, $r, 1, 4)
    $r[5] = [byte]$Len
    [Array]::Copy($Data, 0, $r, 6, [Math]::Min($Data.Length, $ReportLength - 6))
    return ,$r
}

function Invoke-WinctrlCommand {
    <#
        Send one command frame and gather replies until quiet.
        A broadcast (PartId 1) yields one reply per part.
    #>
    param(
        [Parameter(Mandatory)]$Hid,
        [Parameter(Mandatory)][byte[]]$Data,
        [uint32]$PartId = 1,
        [int]$Len = -1,
        [int]$TimeoutMs = 500,
        [int]$MaxReplies = 16
    )
    $Hid.Drain()
    $Hid.Write((New-WinctrlFrame -Data $Data -PartId $PartId -Len $Len -ReportLength $Hid.OutLen))

    # A broadcast has to wait out the whole window to hear from every part, but
    # a targeted command can return the moment its part answers. Without this
    # every read costs a full timeout and a single ratio change takes seconds.
    $targeted = ($PartId -ne 1)

    $cmd = $Data[0]
    $replies = @()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($replies.Count -lt $MaxReplies) {
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { break }
        $raw = $Hid.Read([Math]::Min($remaining, 150))
        if ($null -eq $raw) { continue }
        if ($raw.Length -lt 14 -or $raw[0] -ne $script:REPORT_ID) { continue }   # joystick state
        if ($raw[6] -ne $cmd) { continue }                                       # reply to another command
        $from = [BitConverter]::ToUInt32($raw, 1) - $script:PART_REPLY_BIAS
        $replies += [pscustomobject]@{
            PartId = $from
            Len    = [int]$raw[5]
            Data   = $raw[6..13]
        }
        if ($targeted -and $from -eq $PartId) { break }
    }
    return $replies
}

function Read-WinctrlConfig {
    <# READ_CFG_DATA (0x05). Returns objects with PartId / Offset / Value[4]. #>
    param(
        [Parameter(Mandatory)]$Hid,
        [Parameter(Mandatory)][int]$Offset,
        [uint32]$PartId = 1,
        [int]$TimeoutMs = 500
    )
    $data = [byte[]]@(0x05, ($Offset -band 0xFF), (($Offset -shr 8) -band 0xFF), (($Offset -shr 16) -band 0xFF), 0, 0, 0, 0)
    Invoke-WinctrlCommand -Hid $Hid -Data $data -PartId $PartId -Len 4 -TimeoutMs $TimeoutMs | ForEach-Object {
        $off = [int]$_.Data[1] -bor ([int]$_.Data[2] -shl 8) -bor ([int]$_.Data[3] -shl 16)
        if ($off -eq $Offset) {
            [pscustomobject]@{
                PartId = $_.PartId
                Offset = $off
                Value  = [byte[]]@($_.Data[4], $_.Data[5], $_.Data[6], $_.Data[7])
            }
        }
    }
}

function Write-WinctrlConfig {
    <# WRITE_CFG_DATA (0x06). Requires an explicit PartId; never broadcasts. #>
    param(
        [Parameter(Mandatory)]$Hid,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][byte[]]$Value,
        [Parameter(Mandatory)][uint32]$PartId,
        [int]$TimeoutMs = 800
    )
    if ($Value.Length -ne 4) { throw "Write-WinctrlConfig: Value must be exactly 4 bytes" }
    if ($PartId -eq 1) { throw "Write-WinctrlConfig: refusing to broadcast a write" }
    $data = [byte[]]@(0x06, ($Offset -band 0xFF), (($Offset -shr 8) -band 0xFF), (($Offset -shr 16) -band 0xFF),
                      $Value[0], $Value[1], $Value[2], $Value[3])
    $acks = Invoke-WinctrlCommand -Hid $Hid -Data $data -PartId $PartId -Len 8 -TimeoutMs $TimeoutMs
    foreach ($a in $acks) {
        $off = [int]$a.Data[1] -bor ([int]$a.Data[2] -shl 8) -bor ([int]$a.Data[3] -shl 16)
        if ($a.PartId -eq $PartId -and $off -eq $Offset) { return $true }
    }
    return $false
}

function Get-WinctrlParts {
    <#
        Broadcast REQUEST_DEVICE_HW to enumerate parts, read each part's
        12-byte serial (0x9C/0xA0/0xA4) and its afterburner calibration.
        HasAfterburner is true when the calibration words are programmed,
        which is how we pick the throttle base out of the assembly.
    #>
    param([Parameter(Mandatory)]$Hid)

    $hw = Invoke-WinctrlCommand -Hid $Hid -Data ([byte[]]@(0x01,0,0,0,0,0,0,0)) -Len 1 -TimeoutMs 700
    $ids = @($hw | Select-Object -ExpandProperty PartId -Unique)

    foreach ($id in $ids) {
        $chunks = @()
        foreach ($off in $script:SERIAL_OFFSETS) {
            $hit = Read-WinctrlConfig -Hid $Hid -Offset $off -PartId $id | Where-Object PartId -eq $id | Select-Object -First 1
            if ($hit) { $chunks += (($hit.Value | ForEach-Object { '{0:x2}' -f $_ }) -join '') }
        }
        $calOk = $true
        foreach ($off in $script:AB_CAL_OFFSETS) {
            $hit = Read-WinctrlConfig -Hid $Hid -Offset $off -PartId $id | Where-Object PartId -eq $id | Select-Object -First 1
            if (-not $hit -or (@($hit.Value | Where-Object { $_ -ne 0xFF }).Count -eq 0)) { $calOk = $false }
        }
        [pscustomobject]@{
            PartId         = $id
            PartIdHex      = ('0x{0:X4}' -f $id)
            Serial         = ($chunks -join '').ToUpper()
            HasAfterburner = $calOk
        }
    }
}

function Get-WinctrlAfterburnerRatio {
    <# Returns the ratio percent, or $null when the device reports "Inactivated". #>
    param([Parameter(Mandatory)]$Hid, [Parameter(Mandatory)][uint32]$PartId)
    $r = Read-WinctrlConfig -Hid $Hid -Offset $script:AB_RATIO_OFFSET -PartId $PartId | Where-Object PartId -eq $PartId | Select-Object -First 1
    if (-not $r) { return $null }
    if ($r.Value[0] -gt 100) { return $null }
    return (100 - $r.Value[0])
}

function Set-WinctrlAfterburnerRatio {
    <#
        Writes 0x11C byte0 = 100 - Percent, preserving bytes 1-3, exactly as
        SimAppPro's SetAfterburnerRatio.vue Activate() does.
        -Clear writes FF FF FF FF ("Inactivated").
    #>
    param(
        [Parameter(Mandatory)]$Hid,
        [Parameter(Mandatory)][uint32]$PartId,
        [int]$Percent,
        [switch]$Clear
    )
    $cur = Read-WinctrlConfig -Hid $Hid -Offset $script:AB_RATIO_OFFSET -PartId $PartId | Where-Object PartId -eq $PartId | Select-Object -First 1
    if (-not $cur) { throw "Could not read current afterburner ratio from part 0x$('{0:X4}' -f $PartId)" }

    if ($Clear) {
        $val = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF)
    } else {
        if ($Percent -lt 0 -or $Percent -gt 100) { throw "Percent must be 0..100 (got $Percent)" }
        $val = [byte[]]@([byte](100 - $Percent), $cur.Value[1], $cur.Value[2], $cur.Value[3])
    }

    if (-not (Write-WinctrlConfig -Hid $Hid -Offset $script:AB_RATIO_OFFSET -Value $val -PartId $PartId)) {
        throw "Device did not acknowledge the afterburner ratio write"
    }
    # Read back so callers can verify rather than trust.
    return (Get-WinctrlAfterburnerRatio -Hid $Hid -PartId $PartId)
}
