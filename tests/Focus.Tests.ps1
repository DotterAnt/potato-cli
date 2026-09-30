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
    "Focus checks: $script:checks passed"
}
