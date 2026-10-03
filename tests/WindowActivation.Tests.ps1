param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    Initialize-PotatoWindowIdentity
    $script:checks=0
    function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
    Check (-not [PotatoWindowIdentity]::Activate([IntPtr]::Zero,$false)) 'Invalid native window activation claimed success.'
    $script:CurrentState=@{working=@{title='Previous';nativeWindowHandle=456;processId=42}}
    $script:updates=0;$script:ownership=0;$script:mouseInput=0
    $activationFixtureWindow=[pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=123;ProcessId=42}}
    function Get-PotatoTopLevelWindows {param($Selector,$TimeoutMs);,$activationFixtureWindow}
    function Show-PotatoWindow {param($Handle,[switch]$Maximize);$false}
    function Set-PotatoWorkingWindow {$script:updates++;throw 'Must not update working context.'}
    function New-PotatoOwnedWindow {$script:ownership++;throw 'Must not claim ownership.'}
    $failure=$null
    try {Invoke-PotatoFocus @{ProcessId=42;FocusTimeoutMs=0} | Out-Null} catch {$failure=$_.Exception}
    Check ($failure -and $failure.Data['PotatoErrorType'] -eq 'WindowActivationFailed' -and $failure.Data['NoInputSent']) ('Failed activation was swallowed instead of returning a structured failure: '+$failure.Message)
    Check ($script:updates -eq 0 -and $script:ownership -eq 0 -and $script:CurrentState.working.title -ceq 'Previous') 'Failed activation changed working state or cleanup ownership.'
    function Resolve-PotatoCommandTarget {@{ok=$true;element=$activationFixtureWindow;selector=@{Name='Fixture'}}}
    function ConvertTo-PotatoElementInfo {@{controlType='Button';nativeWindowHandle=123;isEnabled=$true;isOffscreen=$false;boundingRectangle=@{x=0;y=0;width=30;height=20};supportedPatterns=@('Invoke')}}
    function Move-PotatoMouse {$script:mouseInput++}
    function Invoke-PotatoMouseClick {$script:mouseInput++}
    $failure=$null
    try {Invoke-PotatoClick @{Name='Fixture';Method='Mouse'} | Out-Null} catch {$failure=$_.Exception}
    Check ($failure -and $failure.Data['PotatoErrorType'] -eq 'WindowActivationFailed' -and $script:mouseInput -eq 0) 'A denied activation sent a mouse click into the wrong foreground.'
    $failure=$null
    try {Invoke-PotatoClick @{Name='Fixture';Method='Mouse';Focus=$false} | Out-Null} catch {$failure=$_.Exception}
    Check ($failure -and $failure.Data['PotatoErrorType'] -eq 'WindowActivationFailed' -and $script:mouseInput -eq 0) 'Focus false permitted mouse input into a background target.'
    'Window activation: '+$script:checks+' checks passed.'
}
