#Requires -Version 5.1

# The production NativeCcd type is already loaded in the main test process. A child PowerShell process
# gives these boundary cases a fake type with the same surface, so not one P/Invoke can reach Windows.
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class NativeCcd {
    public const uint QDC_ALL_PATHS = 1, QDC_ONLY_ACTIVE_PATHS = 2, PATH_ACTIVE = 1;
    public const uint MODE_IDX_INVALID = 0xffffffff, MODE_INFO_TYPE_SOURCE = 1;
    public const uint PIXELFORMAT_32BPP = 4, SCANLINE_PROGRESSIVE = 1;
    public const uint ROTATION_IDENTITY = 1, SCALING_IDENTITY = 1, GET_TARGET_NAME = 2;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 32, SDC_VALIDATE = 64;
    public const uint SDC_APPLY = 128, SDC_SAVE_TO_DATABASE = 512;

    public struct LUID { public uint Low; public int High; }
    public struct RATIONAL { public uint Numerator, Denominator; }
    public struct SOURCE_INFO { public LUID adapterId; public uint id, modeInfoIdx; }
    public struct TARGET_INFO {
        public LUID adapterId;
        public uint id, modeInfoIdx, targetAvailable, rotation, scaling, scanLineOrdering;
        public RATIONAL refreshRate;
    }
    public struct PATH_INFO { public SOURCE_INFO sourceInfo; public TARGET_INFO targetInfo; public uint flags; }
    public struct MODE_INFO {
        public uint infoType, id, srcWidth, srcHeight, srcPixelFormat;
        public LUID adapterId;
        public int srcPosX, srcPosY;
    }
    public struct HEADER { public uint type, size; public LUID adapterId; public uint id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TARGET_DEVICE_NAME {
        public HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
    }

    public static PATH_INFO[] AllPaths = new PATH_INFO[0];
    public static PATH_INFO[] ActivePaths = new PATH_INFO[0];
    public static MODE_INFO[] ActiveModes = new MODE_INFO[0];
    public static uint AppliedCount;

    public static int GetDisplayConfigBufferSizes(uint flags, ref int pathCount, ref int modeCount) {
        PATH_INFO[] paths = flags == QDC_ALL_PATHS ? AllPaths : ActivePaths;
        pathCount = paths.Length;
        modeCount = flags == QDC_ALL_PATHS ? 0 : ActiveModes.Length;
        return 0;
    }
    public static int QueryDisplayConfig(uint flags, ref int pathCount, PATH_INFO[] paths,
                                         ref int modeCount, MODE_INFO[] modes, IntPtr topology) {
        PATH_INFO[] sourcePaths = flags == QDC_ALL_PATHS ? AllPaths : ActivePaths;
        sourcePaths.CopyTo(paths, 0);
        if (flags != QDC_ALL_PATHS) { ActiveModes.CopyTo(modes, 0); }
        return 0;
    }
    public static int DisplayConfigGetDeviceInfo(ref TARGET_DEVICE_NAME target) {
        target.monitorFriendlyDeviceName = "Panel";
        return 0;
    }
    public static int SetDisplayConfig(int pathCount, PATH_INFO[] paths, int modeCount,
                                       MODE_INFO[] modes, uint flags) {
        if ((flags & SDC_APPLY) != 0) { AppliedCount = (uint)pathCount; }
        return 0;
    }
}
"@

$core = Join-Path (Split-Path $PSScriptRoot -Parent) 'DisplayCore.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$null)
foreach ($name in @('Get-CcdPathChoice', 'Get-LayoutPositions', 'Invoke-CcdFullConfigAttempt',
                     'Set-CcdFullConfig', 'New-LayoutResult', 'Invoke-CcdLayoutAttempt')) {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $function) { throw "Could not load $name from DisplayCore.ps1." }
    . ([scriptblock]::Create($function.Extent.Text))
}

function Write-DisplayLog { param($Message) }
function Get-CcdPathDevice { param($Path) return ('panel' + $Path.targetInfo.id) }
function Get-KnownDisplays { return @{} }
function Set-DisplayIdentity { param($State, $Known) }

function New-FakePath {
    param([uint32]$AdapterLow, [uint32]$TargetId, [uint32]$Available = 1)

    $path = New-Object NativeCcd+PATH_INFO
    $source = $path.sourceInfo
    $luid = $source.adapterId; $luid.Low = $AdapterLow
    $source.adapterId = $luid; $source.id = 0
    $path.sourceInfo = $source
    $target = $path.targetInfo
    $target.adapterId = $luid; $target.id = $TargetId; $target.targetAvailable = $Available
    $path.targetInfo = $target; $path.flags = [NativeCcd]::PATH_ACTIVE
    return $path
}

$paths = New-Object 'NativeCcd+PATH_INFO[]' 2
$paths[0] = New-FakePath -AdapterLow 1 -TargetId 0
$paths[1] = New-FakePath -AdapterLow 2 -TargetId 1
[NativeCcd]::AllPaths = $paths
$targets = @(
    [pscustomobject]@{ DevicePath = 'panel0'; Label = 'A'; Width = 1920; Height = 1080
        Hz = 60; RateNum = 60000; RateDen = 1000; Rotation = 1; X = 0; Y = 0 }
    [pscustomobject]@{ DevicePath = 'panel1'; Label = 'B'; Width = 1920; Height = 1080
        Hz = 60; RateNum = 60000; RateDen = 1000; Rotation = 1; X = 1920; Y = 0 }
)

[NativeCcd]::AppliedCount = 0
if (-not (Set-CcdFullConfig -Targets $targets -PrimaryPath 'panel0' -Exact) -or
    [NativeCcd]::AppliedCount -ne 2) {
    throw 'Two adapters with source id zero did not produce two applied paths.'
}

[NativeCcd]::AppliedCount = 0
$missing = @($targets) + @([pscustomobject]@{ DevicePath = 'panel2'; Label = 'C'; Width = 1920; Height = 1080
    Hz = 60; RateNum = 60000; RateDen = 1000; Rotation = 1; X = 3840; Y = 0 })
if ((Set-CcdFullConfig -Targets $missing -PrimaryPath 'panel0' -Exact) -or
    [NativeCcd]::AppliedCount -ne 0) {
    throw 'An incomplete requested target set reached SetDisplayConfig.'
}

$withPhantom = New-Object 'NativeCcd+PATH_INFO[]' 3
$withPhantom[0] = $paths[0]; $withPhantom[1] = $paths[1]
$withPhantom[2] = New-FakePath -AdapterLow 9 -TargetId 99 -Available 0
[NativeCcd]::AllPaths = $withPhantom
[NativeCcd]::AppliedCount = 0
if (-not (Set-CcdFullConfig -Targets $targets -PrimaryPath 'panel0' -Exact) -or
    [NativeCcd]::AppliedCount -ne 2) {
    throw 'An unrelated unavailable path broke a complete requested target set.'
}

$activePaths = New-Object 'NativeCcd+PATH_INFO[]' 1
$activePath = New-FakePath -AdapterLow 1 -TargetId 0
$source = $activePath.sourceInfo; $source.modeInfoIdx = 0; $activePath.sourceInfo = $source
$activePaths[0] = $activePath
$activeModes = New-Object 'NativeCcd+MODE_INFO[]' 1
$mode = New-Object NativeCcd+MODE_INFO
$mode.infoType = [NativeCcd]::MODE_INFO_TYPE_SOURCE
$mode.srcWidth = 1920; $mode.srcHeight = 1080; $mode.srcPosX = 100; $mode.srcPosY = 0
$activeModes[0] = $mode
[NativeCcd]::ActivePaths = $activePaths; [NativeCcd]::ActiveModes = $activeModes
function Wait-ForLayout { param($WantedPositions) return $false }

$layout = Invoke-CcdLayoutAttempt -PrimaryPath 'panel0' -Order @() -Attempt 1 -Attempts 1
if ($layout.Ok -or $layout.Changed) { throw 'An unsettled applied layout was reported as successful.' }

Write-Output 'native engine fixture passed'
