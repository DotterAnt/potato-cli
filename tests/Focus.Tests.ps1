param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    $script:checks=0
    function Check($value,$message) { if (-not $value) {throw $message}; $script:checks++ }
    function Reject([scriptblock]$body,$message) { $caught=$false; try { & $body | Out-Null } catch {$caught=$true}; Check $caught $message }
    $canvas=[pscustomobject]@{Current=[pscustomobject]@{Name='Canvas';AutomationId='canvas';IsEnabled=$true;HasKeyboardFocus=$false}}
    $nativeField=[pscustomobject]@{Current=[pscustomobject]@{Name='Filename';AutomationId='filename';IsEnabled=$true;HasKeyboardFocus=$true}}
    $script:native=@{ready=$true;owned=$true;foregroundHandle=101;focusHandle=202}
    $script:reads=0
    function Get-PotatoInputFocus { $script:reads++; @{ready=($script:reads -gt 1);candidates=@($canvas,$nativeField);native=$script:native} }
    function Get-PotatoNativeInputState { $script:native }
    $focus=Wait-PotatoInputFocus '{"AutomationId":"canvas"}' 500
    Check ($focus.source -eq 'Win32' -and $script:reads -eq 2) 'False UIA focus or transient readiness blocked the native-confirmed canvas.'
    Assert-PotatoInputFocusUnchanged $focus; $script:checks++
    $field=Wait-PotatoInputFocus '{"AutomationId":"filename"}' 0
    Check ($field.element -eq $nativeField -and $field.source -eq 'UIAutomation+Win32') 'Guard failed to consider the native focus identity.'
    $mismatch=$null
    try { Wait-PotatoInputFocus '{"Name":"Absent"}' 0 | Out-Null } catch { $mismatch=$_.Exception }
    Check ($mismatch.Data['PotatoErrorType'] -eq 'InputFocusNotReady' -and $mismatch.Data['NoInputSent'] -and $mismatch.Data['focus'].focusHandle -eq 202) 'Focus mismatch lost structured diagnostics or claimed dispatch.'
    $script:native=@{ready=$true;owned=$true;foregroundHandle=101;focusHandle=303}
    Reject {Assert-PotatoInputFocusUnchanged $focus} 'Changed native keyboard target was accepted.'
    $script:native=@{ready=$false;owned=$false;foregroundHandle=404;focusHandle=202}
    Reject {Assert-PotatoInputFocusUnchanged $focus} 'Foreign foreground was accepted.'
    function Get-PotatoInputFocus { @{ready=$false;candidates=@($canvas);native=$script:native} }
    Reject {Wait-PotatoInputFocus '' 0} 'Unowned focus was accepted without an identity selector.'
    Reject {Wait-PotatoInputFocus '{}' 0} 'Empty expected identity accepted.'
    Reject {Wait-PotatoInputFocus '{"Name":"Canvas"}' 10001} 'Unbounded focus wait accepted.'
    function Test-PotatoNativeElementFocus {$false}
    $focusFailure=$null
    try {Assert-PotatoForegroundInput $nativeField} catch {$focusFailure=$_.Exception}
    Check ($focusFailure.Data['PotatoErrorType'] -eq 'InputFocusNotReady' -and $focusFailure.Data['NoInputSent'] -and $focusFailure.Data['focus'].foregroundHandle -eq 404 -and $focusFailure.Data['focus'].expectedTarget.name -eq 'Filename') 'Writable input lost expected/native focus diagnostics or claimed a dispatch.'
    try {Assert-PotatoForegroundInput $nativeField -NoInputSent:$false} catch {$focusFailure=$_.Exception}
    Check ($focusFailure.Data['NoInputSent'] -eq $false) 'Focus failure after clearing claimed no previous input.'
    Initialize-PotatoWindowIdentity
    foreach ($text in @(([string][char]0xd800+'x'),([string][char]0xdc00))) {
        $invalid=$null
        try {[PotatoLiteralInput]::SendText($text,5,0,0)} catch {
            $invalid=$_.Exception
            while ($invalid.InnerException) {$invalid=$invalid.InnerException}
        }
        Check ($invalid.Data['PotatoErrorType'] -eq 'InvalidText' -and $invalid.Data['NoInputSent']) 'Malformed Unicode was not rejected before dispatch.'
    }
    Reject {[PotatoLiteralInput]::SendNavigation('F12',0,0)} 'Navigation backend accepted an application shortcut.'
    Reject {[PotatoLiteralInput]::SendNavigation('Escape',0,0)} 'Navigation backend accepted missing foreground identity.'
    function Get-PotatoWorkingElement { $canvas }
    function Wait-PotatoInputFocus {
        @{element=$canvas;native=@{foregroundHandle=$(if ($script:sent -gt 0) {303} else {101});focusHandle=202}}
    }
    function Assert-PotatoInputFocusUnchanged { }
    function ConvertTo-PotatoElementInfo { @{name='Fixture focus'} }
    function Get-PotatoFocusedElement { $canvas }
    function Send-PotatoNavigationKey { $script:sent++ }
    $script:sent=0
    $changed=$null
    try { Invoke-PotatoPressKey @{Key='Down';Count=3} | Out-Null } catch { $changed=$_.Exception }
    Check ($script:sent -eq 1 -and $changed.Data['PotatoErrorType'] -eq 'InputFocusChanged' -and $changed.Data['NoInputSent'] -eq $false) 'Repeated navigation continued into a new modal or claimed no input after the first key.'
    "Focus checks: $script:checks passed"
}
