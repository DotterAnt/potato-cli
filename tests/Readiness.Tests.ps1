param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    $script:checks=0
    function Check($condition,$message) {if (-not $condition) {throw $message};$script:checks++}
    $script:probes=0
    function Get-PotatoGuardedForegroundWindow {
        param($json)
        $script:probes++
        if ($script:probes -lt 3) {throw (New-PotatoScopeFailure 'Expected dialog is still opening')}
        @{guard=$json}
    }
    $result=Wait-PotatoGuardedForegroundWindow @{WindowSelectorJson='exact identity';TimeoutMs=1000}
    Check ($result.guard -eq 'exact identity' -and $script:probes -eq 3) 'Readiness wait did not preserve the exact guard.'
    $script:probes=0
    try {Wait-PotatoGuardedForegroundWindow @{WindowSelectorJson='exact identity';TimeoutMs=0} | Out-Null;throw 'Unexpected success'}
    catch {Check ($_.Exception.Data['PotatoErrorType'] -eq 'ScopeNotReady' -and $script:probes -eq 1) 'Zero timeout hid scope mismatch or repeated the probe.'}
    function Get-PotatoGuardedForegroundWindow {$script:probes++;throw 'Invalid guard'}
    $script:probes=0
    try {Wait-PotatoGuardedForegroundWindow @{WindowSelectorJson='invalid';TimeoutMs=1000} | Out-Null;throw 'Unexpected success'}
    catch {Check ($_.Exception.Message -eq 'Invalid guard' -and $script:probes -eq 1) 'Invalid guard was retried as readiness.'}
    Initialize-PotatoAutomationTypes
    function Get-PotatoExplicitScope {$null}
    function Get-PotatoRootElement {throw 'Window wait must not traverse the desktop'}
    function Get-PotatoTopLevelWindows {param($selector,$timeout) $script:windowTimeout=$timeout;[pscustomobject]@{Name=$selector.Name}}
    function ConvertTo-PotatoElementInfo {param($Element,[switch]$Snapshot) @{name=$Element.Name}}
    $result=Invoke-PotatoWaitElement @{Name='Delayed dialog';ControlType='Window';TimeoutMs=3000}
    Check ($result.exists -and $result.elements[0].name -eq 'Delayed dialog' -and $script:windowTimeout -eq 3000) 'Window wait used full desktop descendants or lost its timeout.'
    "Readiness checks: $script:checks passed"
}
