param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -PassThru
# Fake native backend: tests never press a real mouse button.
Add-Type @'
using System.Collections.Generic;
public static class PotatoMouseNative {
    public static List<int> Events=new List<int>();
    public static bool RejectDown;
    public static void MouseEvent(int flags,int x,int y,int data,int extra) {
        if (RejectDown && flags==2) {
            var failure=new System.InvalidOperationException("Rejected mouse down");
            failure.Data["PotatoErrorType"]="MouseInputRejected";failure.Data["NoInputSent"]=true;
            throw failure;
        }
        Events.Add(flags);
    }
}
'@
& $module {
    $script:moves=0
    function Move-PotatoMouse { param($X,$Y)
        $script:moves++
        if ($script:moves -eq 2) {
            $failure=[InvalidOperationException]::new('Simulated movement failure')
            $failure.Data['PotatoErrorType']='MouseInputRejected';$failure.Data['NoInputSent']=$true
            throw [Management.Automation.MethodInvocationException]::new('Native call wrapper',$failure)
        }
    }
    $failed=$false
    try { Invoke-PotatoDrag @{StartX=1;StartY=2;EndX=3;EndY=4;Smooth=$false} | Out-Null } catch {
        $diagnostic=$_.Exception
        while (-not $diagnostic.Data['PotatoErrorType'] -and $diagnostic.InnerException) {$diagnostic=$diagnostic.InnerException}
        $failed=$diagnostic.Message -eq 'Simulated movement failure' -and $diagnostic.Data['NoInputSent'] -eq $false
    }
    if (-not $failed -or [PotatoMouseNative]::Events.Count -ne 2 -or [PotatoMouseNative]::Events[0] -ne 2 -or [PotatoMouseNative]::Events[1] -ne 4) { throw 'Drag error did not release the held mouse button.' }
    [PotatoMouseNative]::Events.Clear()
    [PotatoMouseNative]::RejectDown=$true
    $failed=$false
    try {Invoke-PotatoDrag @{StartX=1;StartY=2;EndX=3;EndY=4;Smooth=$false} | Out-Null} catch {
        $diagnostic=$_.Exception
        while (-not $diagnostic.Data['PotatoErrorType'] -and $diagnostic.InnerException) {$diagnostic=$diagnostic.InnerException}
        $failed=$diagnostic.Data['NoInputSent'] -eq $true
    }
    if (-not $failed -or [PotatoMouseNative]::Events.Count) {throw 'A rejected press sent an unrelated release or lost its known outcome.'}
    [PotatoMouseNative]::RejectDown=$false
    $failed=$false
    try { Invoke-PotatoDrag @{StartX=1;StartY=2;EndX=3} | Out-Null } catch { $failed=$true }
    if (-not $failed -or [PotatoMouseNative]::Events.Count) { throw 'Invalid endpoint dispatched mouse input.' }
    function Resolve-PotatoCommandTarget { param($ArgsMap,[switch]$AllowPathAsTarget) @{ok=$false;error='Missing target'} }
    $failed=$false
    try { Invoke-PotatoDrag @{StartX=1;StartY=2;TargetSelectorJson='{}'} | Out-Null } catch { $failed=$_.Exception.Data['PotatoErrorType'] -eq 'TargetNotFound' -and $_.Exception.Data['NoInputSent'] }
    if (-not $failed -or [PotatoMouseNative]::Events.Count) { throw 'Missing drop target dispatched mouse input or lost the known not-dispatched outcome.' }
    'Drag checks: 4 passed (partial motion, rejected press, incomplete endpoint, missing target)'
}
