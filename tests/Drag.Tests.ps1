param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -PassThru
# Fake native backend: tests never press a real mouse button.
Add-Type @'
using System.Collections.Generic;
public static class PotatoMouseNative {
    public static List<int> Events=new List<int>();
    public static void MouseEvent(int flags,int x,int y,int data,int extra) { Events.Add(flags); }
}
'@
& $module {
    $script:moves=0
    function Move-PotatoMouse { param($X,$Y) $script:moves++; if ($script:moves -eq 2) { throw 'Simulated movement failure' } }
    $failed=$false
    try { Invoke-PotatoDrag @{StartX=1;StartY=2;EndX=3;EndY=4;Smooth=$false} | Out-Null } catch { $failed=$_.Exception.Message -eq 'Simulated movement failure' }
    if (-not $failed -or [PotatoMouseNative]::Events.Count -ne 2 -or [PotatoMouseNative]::Events[0] -ne 2 -or [PotatoMouseNative]::Events[1] -ne 4) { throw 'Drag error did not release the held mouse button.' }
    [PotatoMouseNative]::Events.Clear()
    $failed=$false
    try { Invoke-PotatoDrag @{StartX=1;StartY=2;EndX=3} | Out-Null } catch { $failed=$true }
    if (-not $failed -or [PotatoMouseNative]::Events.Count) { throw 'Invalid endpoint dispatched mouse input.' }
    function Resolve-PotatoCommandTarget { param($ArgsMap,[switch]$AllowPathAsTarget) @{ok=$false;error='Missing target'} }
    $failed=$false
    try { Invoke-PotatoDrag @{StartX=1;StartY=2;TargetSelectorJson='{}'} | Out-Null } catch { $failed=$true }
    if (-not $failed -or [PotatoMouseNative]::Events.Count) { throw 'Missing drop target dispatched mouse input.' }
    'Drag checks: 3 passed (release on failure, incomplete endpoint, missing target)'
}
