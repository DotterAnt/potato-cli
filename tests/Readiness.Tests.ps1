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
    $actual=@(Get-PotatoTopLevelWindows -Selector @{ProcessId=$PID} -TimeoutMs 0 -RequireComplete)
    Check ($null -ne $actual) 'Native window enumeration still queried the unused desktop root.'
    $initialize=(Get-Command Initialize-PotatoWindowIdentity).ScriptBlock
    function Initialize-PotatoWindowIdentity {throw 'Fixture native enumeration failure'}
    $incomplete=$null
    try {Get-PotatoTopLevelWindows -Selector @{ProcessId=$PID} -TimeoutMs 0 -RequireComplete | Out-Null} catch {$incomplete=$_.Exception}
    Check ($incomplete.Data['PotatoErrorType'] -eq 'WindowEnumerationIncomplete') 'Failed enumeration became proof of absence.'
    Set-Item Function:\Initialize-PotatoWindowIdentity $initialize
    function Get-PotatoTopLevelWindows {param($selector,$timeout) $script:windowTimeout=$timeout;[pscustomobject]@{Name=$selector.Name}}
    function ConvertTo-PotatoElementInfo {param($Element,[switch]$Snapshot) @{name=$Element.Name}}
    $result=Invoke-PotatoWaitElement @{Name='Delayed dialog';ControlType='Window';TimeoutMs=3000}
    Check ($result.exists -and $result.elements[0].name -eq 'Delayed dialog' -and $script:windowTimeout -eq 3000) 'Window wait used full desktop descendants or lost its timeout.'
    $script:probes=0
    $script:remaining=2
    function Get-PotatoTopLevelWindows {
        param($Selector,$TimeoutMs,[switch]$RequireComplete)
        $script:probes++;$script:complete=$RequireComplete.IsPresent;$script:windowTimeout=$TimeoutMs
        if ($script:probes -le $script:remaining) {[pscustomobject]@{Name='Observed window'}}
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $gone=Invoke-PotatoWindows @{WindowTitle='Observed window';WaitForNotExists=$true;TimeoutMs=1000}
    Check ($gone.count -eq 0 -and $gone.conditionMet -and -not $gone.timedOut -and $script:probes -eq 3 -and $script:complete -and $script:windowTimeout -eq 0 -and $watch.ElapsedMilliseconds -lt 900) 'Disappearance wait waited for appearance or used incomplete enumeration.'
    $script:probes=0;$script:remaining=1
    $stillOpen=Invoke-PotatoWindows @{WindowTitle='Observed window';WaitForNotExists=$true;TimeoutMs=0}
    Check ($stillOpen.count -eq 1 -and -not $stillOpen.conditionMet -and $stillOpen.timedOut -and $script:probes -eq 1) 'Unclosed window passed a zero-time disappearance wait.'
    $script:probes=0
    $legacy=Invoke-PotatoWindows @{WindowTitle='Observed window';TimeoutMs=1000}
    Check ($legacy.count -eq 1 -and -not $legacy.Contains('conditionMet') -and -not $script:complete -and $script:windowTimeout -eq 1000) 'New disappearance flag changed legacy appearance semantics.'
    foreach ($invalid in @(@{WaitForNotExists=$true},@{WindowTitle='Observed window';WaitForNotExists=$true;Foreground=$true},@{WindowTitle='Observed window';WaitForNotExists=$true;Checkpoint=$true},@{WindowTitle='Observed window';WaitForNotExists=$true;TimeoutMs=60001})) {
        $caught=$false;try {Invoke-PotatoWindows $invalid | Out-Null} catch {$caught=$true}
        Check $caught 'Invalid/unscoped disappearance wait was accepted.'
    }
    "Readiness checks: $script:checks passed"
}
