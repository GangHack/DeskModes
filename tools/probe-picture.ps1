#Requires -Version 5.1

<#
    tools\probe-picture.ps1 — asks a monitor's picture-preset register over DDC/CI, one request per run,
    so that a person at the desk can say what changed. A development tool: it is not shipped, and the
    program never does on its own what this does.

    Brightness has one standard code and one meaning everywhere. Picture presets (Reader, FPS, sRGB...)
    do not: MCCS names 0xDC for them, but both LGs on this desk are silent on it and answer on LG's own
    0x15 instead, and the numbers behind the names are the vendor's to choose. The only instrument that
    tells 6 from 17 is an eye on the screen, so the tool does one thing per run and a person says what
    happened. Two ways round, and the first is the safer one:

      learn   pick a preset with the monitor's own buttons, then READ the register: the number that
              changed is that preset's number;
      apply   WRITE a number learnt that way, then look whether the picture followed.

        .\tools\probe-picture.ps1                               the monitors that are on, with outputs
        .\tools\probe-picture.ps1 ULTRAGEAR                     read 0xDC and 0x15 on that monitor
        .\tools\probe-picture.ps1 ULTRAGEAR -Code 0x15          read one register: current and maximum
        .\tools\probe-picture.ps1 ULTRAGEAR -Code 0x15 -Value 6 write, wait, read back
        .\tools\probe-picture.ps1 ULTRAGEAR -Capabilities       the capabilities string — read below

    -Capabilities is a long conversation on the I2C bus, and on 21 August it left the UltraGear deaf to
    every DDC request until its link was cycled. Ask once, at the start, with the cable within reach.

    -Monitor is part of the display's name as `Set-Display.ps1 status` prints it, or the output name
    (\\.\DISPLAY2). Numbers take both forms: 0x15 and 21.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Monitor,
    [string]$Code,
    [string]$Value,
    [switch]$Capabilities
)

$ErrorActionPreference = 'Stop'

# The engine is needed for one thing: the map from an output (\\.\DISPLAY2) to a name a person knows.
# Loading it writes to the log, and this run is nobody's business in last-run.log — the tests point the
# log elsewhere the same way, and for the same reason.
if (-not $env:SCREENDECK_LOG_FILE) {
    $env:SCREENDECK_LOG_FILE = Join-Path ([IO.Path]::GetTempPath()) 'screendeck-probe.log'
}
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'DisplayCore.ps1')

# Its own P/Invoke block rather than a change to NativeDdc: the program's block is compiled into a
# cached DLL keyed by its hash, and a probe must not be the reason every start recompiles it.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class ProbeDdc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX {
        public int cbSize;
        public int mLeft, mTop, mRight, mBottom;
        public int wLeft, wTop, wRight, wBottom;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string description;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr rect, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoEx(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out int type, out uint current, out uint maximum);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetCapabilitiesStringLength(IntPtr h, out uint length);

    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder text, uint length);

    [DllImport("dxva2.dll")]
    public static extern bool DestroyPhysicalMonitor(IntPtr h);

    // Output name -> physical monitor, the same walk NativeDdc takes. The caller destroys the handle.
    public static List<KeyValuePair<string, PHYSICAL_MONITOR>> Open() {
        var found = new List<KeyValuePair<string, PHYSICAL_MONITOR>>();
        var screens = new List<IntPtr>();
        MonitorEnumProc collect = delegate(IntPtr h, IntPtr hdc, IntPtr rect, IntPtr data) {
            screens.Add(h); return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, collect, IntPtr.Zero);
        foreach (IntPtr screen in screens) {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfoEx(screen, ref info)) { continue; }
            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(screen, out count) || count == 0) { continue; }
            var physical = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(screen, count, physical)) { continue; }
            foreach (PHYSICAL_MONITOR p in physical) {
                found.Add(new KeyValuePair<string, PHYSICAL_MONITOR>(info.szDevice, p));
            }
        }
        return found;
    }

    // Three tries with a pause, as in the program: one refusal on this bus is noise, not an answer.
    public static int LastError;
    private static bool WithRetry(Func<bool> call) {
        for (int i = 0; i < 3; i++) {
            if (call()) { return true; }
            LastError = Marshal.GetLastWin32Error();
            if (i < 2) { System.Threading.Thread.Sleep(60); }
        }
        return false;
    }

    public class Reading {
        public bool Answered;
        public int Type;          // 0 = momentary (a button), 1 = set parameter (a value that stays)
        public uint Current, Maximum;
        public int Error;
    }

    public static Reading Read(IntPtr h, byte code) {
        var r = new Reading();
        int type = 0; uint cur = 0, max = 0;
        r.Answered = WithRetry(delegate { return GetVCPFeatureAndVCPFeatureReply(h, code, out type, out cur, out max); });
        r.Type = type; r.Current = cur; r.Maximum = max;
        if (!r.Answered) { r.Error = LastError; }
        return r;
    }

    public static bool Write(IntPtr h, byte code, uint value) {
        return WithRetry(delegate { return SetVCPFeature(h, code, value); });
    }

    public static string ReadCapabilities(IntPtr h) {
        uint length = 0;
        if (!WithRetry(delegate { return GetCapabilitiesStringLength(h, out length); }) || length == 0) { return null; }
        var text = new StringBuilder((int)length + 1);
        if (!WithRetry(delegate { return CapabilitiesRequestAndCapabilitiesReply(h, text, length); })) { return null; }
        return text.ToString();
    }
}
'@

function ConvertTo-Number {
    param([string]$Text)
    if ($Text -match '^0x([0-9a-f]+)$') { return [Convert]::ToInt32($Matches[1], 16) }
    return [int]$Text
}

function Format-Hex {
    param([uint32]$Number)
    return ('0x{0:X2} ({1})' -f $Number, $Number)
}

function Write-Reading {
    param([string]$Label, [byte]$VcpCode, $Reading)
    $head = '  0x{0:X2}: ' -f $VcpCode
    if (-not $Reading.Answered) {
        Write-Host ($head + ('no answer (0x{0:X8})' -f $Reading.Error)) -ForegroundColor DarkGray
        return
    }
    $kind = $(if ($Reading.Type -eq 0) { 'momentary' } else { 'set-parameter' })
    Write-Host ($head + ('current {0}, maximum {1}, {2}' -f (Format-Hex $Reading.Current), (Format-Hex $Reading.Maximum), $kind))
}

# --- who is on the desk -------------------------------------------------------
$state = @(Get-DisplayState)
$byOutput = @{}
foreach ($m in $state) { if ($m.Output) { $byOutput[[string]$m.Output] = [string]$m.Label } }

$opened = @([ProbeDdc]::Open())
if ($opened.Count -eq 0) { throw 'No physical monitor answered EnumDisplayMonitors — is anything on?' }

try {
    if (-not $Monitor) {
        Write-Host ''
        Write-Host 'Monitors that are on (a sleeping one is not here at all, it answers nothing):' -ForegroundColor Cyan
        foreach ($pair in $opened) {
            $name = $(if ($byOutput.Contains($pair.Key)) { $byOutput[$pair.Key] } else { '?' })
            Write-Host ('  {0,-14} {1}' -f $pair.Key, $name)
        }
        Write-Host ''
        Write-Host 'Next: .\tools\probe-picture.ps1 <part of a name>   reads 0xDC and 0x15 on it' -ForegroundColor DarkGray
        return
    }

    $hits = @($opened | Where-Object {
        $name = $(if ($byOutput.Contains($_.Key)) { $byOutput[$_.Key] } else { '' })
        $_.Key -eq $Monitor -or ($name -and $name.ToUpperInvariant().Contains($Monitor.ToUpperInvariant()))
    })
    if ($hits.Count -eq 0) { throw "No monitor that is on matches '$Monitor'. Run the tool without arguments for the list." }
    if ($hits.Count -gt 1) { throw "'$Monitor' matches more than one monitor; give the output name (\\.\DISPLAYn) instead." }

    $target = $hits[0]
    $handle = $target.Value.handle
    $label  = $(if ($byOutput.Contains($target.Key)) { $byOutput[$target.Key] } else { $target.Key })
    Write-Host ''
    Write-Host ('{0} on {1}' -f $label, $target.Key) -ForegroundColor Cyan

    if ($Capabilities) {
        Write-Host '  asking for the capabilities string (this is the slow one)...' -ForegroundColor DarkGray
        $caps = [ProbeDdc]::ReadCapabilities($handle)
        if ($null -eq $caps) {
            Write-Host ('  no answer (0x{0:X8})' -f [ProbeDdc]::LastError) -ForegroundColor DarkGray
        }
        else {
            Write-Host $caps
        }
        return
    }

    $codes = @()
    if ($Code) { $codes = @([byte](ConvertTo-Number $Code)) }
    else       { $codes = @([byte]0xDC, [byte]0x15) }

    if ($Value) {
        if ($codes.Count -ne 1) { throw '-Value needs -Code: which register to write.' }
        $number = [uint32](ConvertTo-Number $Value)
        $before = [ProbeDdc]::Read($handle, $codes[0])
        Write-Host '  before:' -ForegroundColor DarkGray
        Write-Reading -Label $label -VcpCode $codes[0] -Reading $before
        $ok = [ProbeDdc]::Write($handle, $codes[0], $number)
        if ($ok) { Write-Host ('  wrote {0}' -f (Format-Hex $number)) }
        else     { Write-Host ('  write refused (0x{0:X8})' -f [ProbeDdc]::LastError) -ForegroundColor Yellow }
        # A monitor takes its time to apply a preset, and a read straight after the write can still
        # show the old number (the UltraFine did exactly that with brightness on 21 August).
        Start-Sleep -Milliseconds 400
        $after = [ProbeDdc]::Read($handle, $codes[0])
        Write-Host '  after:' -ForegroundColor DarkGray
        Write-Reading -Label $label -VcpCode $codes[0] -Reading $after
        if ($after.Answered) {
            if ($after.Current -eq $number) { Write-Host '  the monitor took it' -ForegroundColor Green }
            else { Write-Host ('  the monitor reports {0} instead' -f (Format-Hex $after.Current)) -ForegroundColor Yellow }
        }
        return
    }

    foreach ($c in $codes) {
        Write-Reading -Label $label -VcpCode $c -Reading ([ProbeDdc]::Read($handle, $c))
    }
}
finally {
    foreach ($pair in $opened) { [void][ProbeDdc]::DestroyPhysicalMonitor($pair.Value.handle) }
}
