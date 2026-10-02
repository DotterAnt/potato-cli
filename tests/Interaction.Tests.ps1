param()
$ErrorActionPreference = 'Stop'
$cliRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    $script:checks = 0
    function Check($ok,$message) { if (-not $ok) { throw $message }; $script:checks++ }
    function Reject([scriptblock]$body,$message) { $thrown=$false; try { & $body | Out-Null } catch {$thrown=$true}; Check $thrown $message }
    Initialize-PotatoAutomationTypes
    Reject {Invoke-PotatoClick @{ClickCount='two'}} 'Invalid double-click count dispatched a default single click.'
    Reject {Invoke-PotatoClickCoordinate @{X=0;Y=0;ClickCount='two'}} 'Invalid coordinate double-click count moved or clicked the pointer.'
    Reject {Invoke-PotatoClick @{ClickCount=2;Method='Invoke'}} 'Double-click attempted an Invoke action.'
    Add-Type -AssemblyName WindowsBase
    Check ($null -eq (ConvertTo-PotatoRectangle ([Windows.Rect]::Empty))) 'Empty bounds must not throw.'
    foreach ($value in @([double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,1e30)) {
        Check ($null -eq (ConvertTo-PotatoRectangle @{X=$value;Y=0;Width=1;Height=1})) 'Invalid coordinate survived.'
    }
    Check ($null -eq (ConvertTo-PotatoRectangle @{X=0;Y=0;Width=0;Height=1})) 'Zero-area bounds survived.'
    Check ((ConvertTo-PotatoRectangle @{X=-20;Y=-10;Width=1;Height=2}).x -eq -20) 'Negative monitor coordinates were clamped.'
    $current = [pscustomobject]@{Name='Kept';AutomationId='fixture';ClassName='';LocalizedControlType='button';ProcessId=$PID;NativeWindowHandle=0;IsEnabled=$true;IsOffscreen=$true;BoundingRectangle=[Windows.Rect]::Empty;ControlType=[Windows.Automation.ControlType]::Button}
    $element = [pscustomobject]@{Current=$current}
    $element | Add-Member ScriptMethod GetSupportedPatterns { @() }
    $info = ConvertTo-PotatoElementInfo $element
    Check ($info.name -eq 'Kept' -and $info.boundsStatus -ne 'valid' -and $null -eq $info.boundingRectangle) 'Bad bounds erased identity.'
    Reject { Get-PotatoClickPoint $element } 'Physical input accepted empty bounds.'
    $current | Add-Member ScriptProperty ClassName { throw 'stale property' } -Force
    $info = ConvertTo-PotatoElementInfo $element
    Check ($info.name -eq 'Kept' -and $info.propertyErrors.Count -gt 0) 'One stale property erased others.'
    foreach ($keys in @('^s','{ENTER}','^a')) {
        Reject { Get-PotatoInteractionPolicy @{Keys=$keys} hotkey } 'Strict policy accepted hotkey.'
    }
    Reject { Get-PotatoInteractionPolicy @{PreDelete=$true;ClearMethod='Shortcut'} type } 'Strict policy accepted Ctrl+A clearing.'
    Reject { Get-PotatoInteractionPolicy @{InteractionPolicy='AllowShortcuts';Keys='^s'} hotkey } 'Unaudited fallback accepted.'
    $allow = @{InteractionPolicy='AllowShortcuts';Keys='^s';FallbackReason='Fixture authorization';FallbackEvidence='observation-1'}
    Check (Get-PotatoInteractionPolicy $allow hotkey).shortcutUsed 'Explicit shortcut lost audit.'
    foreach ($keys in @('^c','^{V}','+{INSERT}','^(s)','^s^s','+{DEL}')) {
        $allow.Keys=$keys
        Reject { Get-PotatoInteractionPolicy $allow hotkey } 'Clipboard/compound shortcut accepted.'
    }
    Reject { Get-PotatoInteractionPolicy @{ProcessName='example.document'} start } 'File association launch accepted.'
    foreach ($arguments in @('"C:\run folder\created.data"','C:/run/created.data','file:///C:/run/created.data','https://example.invalid/resource')) {
        Reject {Get-PotatoInteractionPolicy @{ProcessName='example.exe';Arguments=$arguments} start} 'Executable document/resource arguments bypassed the GUI Open route.'
    }
    Check ((Get-PotatoInteractionPolicy @{ProcessName='example.exe';Arguments='--new-window'} start).mode -eq 'GuiNavigation') 'Ordinary executable options were rejected as document arguments.'
    Reject { Get-PotatoInteractionPolicy @{Text=[string][char]22} type } 'Clipboard control character accepted as text.'
    Check ((Get-PotatoInteractionPolicy @{Text='^s literal'} type).mode -eq 'GuiNavigation') 'Literal text was treated as hotkey.'
    Reject { Get-PotatoInteractionPolicy @{InteractionPolicy='VisibleControls';Key='Enter'} press-key } 'Strict policy accepted navigation.'
    Reject { Get-PotatoInteractionPolicy @{TargetMode='Focused';Text='literal'} type } 'Opaque input lost its audit requirement.'
    $navigation=@{Key='Enter';FallbackReason='Commit observed editor';FallbackEvidence='fixture.png'}
    Check (Get-PotatoInteractionPolicy $navigation press-key).navigationUsed 'Navigation was not classified separately.'
    $opaque=@{TargetMode='Focused';Text='literal';FallbackReason='Opaque editor';FallbackEvidence='fixture.png'}
    Check (Get-PotatoInteractionPolicy $opaque type).opaqueTyping 'Opaque input was not recorded.'
    Reject { Invoke-PotatoPressKey @{Key='F4'} } 'Application key was accepted as navigation.'
    Reject { Invoke-PotatoPressKey @{Key='Enter';Count=2} } 'Repeated submission was accepted.'
    $script:expanded=0;$script:invoked=0
    $expand=[pscustomobject]@{Current=@{ExpandCollapseState=[Windows.Automation.ExpandCollapseState]::Collapsed}}
    $expand | Add-Member ScriptMethod Expand {$script:expanded++}
    $invoke=[pscustomobject]@{}
    $invoke | Add-Member ScriptMethod Invoke {$script:invoked++}
    $submenu=[pscustomobject]@{Current=@{ControlType=[Windows.Automation.ControlType]::MenuItem};expand=$expand;invoke=$invoke}
    $submenu | Add-Member ScriptMethod TryGetCurrentPattern {param($id,$value)
        if ($id -eq [Windows.Automation.ExpandCollapsePattern]::Pattern) {$value.Value=$this.expand;return $true}
        if ($id -eq [Windows.Automation.InvokePattern]::Pattern) {$value.Value=$this.invoke;return $true}
        return $false
    }
    Check ((Invoke-PotatoElementDefaultAction $submenu) -eq 'ExpandCollapsePattern' -and $script:expanded -eq 1 -and $script:invoked -eq 0) 'Auto invoked a submenu instead of expanding it.'
    $expand.Current.ExpandCollapseState=[Windows.Automation.ExpandCollapseState]::Expanded
    Check ((Invoke-PotatoElementDefaultAction $submenu) -eq 'ExpandCollapsePattern' -and $script:expanded -eq 1 -and $script:invoked -eq 0) 'Auto closed an already expanded submenu.'
    $expand.Current.ExpandCollapseState=[Windows.Automation.ExpandCollapseState]::LeafNode
    Check ((Invoke-PotatoElementDefaultAction $submenu) -eq 'InvokePattern' -and $script:invoked -eq 1) 'A leaf menu command did not retain Invoke.'
    $expand.Current.ExpandCollapseState=[Windows.Automation.ExpandCollapseState]::Collapsed
    $expand | Add-Member ScriptMethod Expand {throw 'Provider received expansion but failed'} -Force
    Reject {Invoke-PotatoElementDefaultAction $submenu} 'A failed expansion was hidden by a second action.'
    Check ($script:invoked -eq 1) 'A failed expansion fell through and invoked another action.'
    $script:CurrentState = [pscustomobject]@{working=@{processId=$PID}}
    $field = [pscustomobject]@{Current=[pscustomobject]@{IsEnabled=$true;HasKeyboardFocus=$true;ProcessId=$PID;ControlType=[Windows.Automation.ControlType]::Edit}}
    $field | Add-Member ScriptMethod TryGetCurrentPattern { param($id,$value) $value.Value=[pscustomobject]@{Current=@{IsReadOnly=$false}}; return $true }
    Assert-PotatoTextTarget $field 'literal'; $script:checks++
    Reject { Assert-PotatoTextTarget $field "submit`n" } 'Dialog Enter hidden in type was accepted.'
    $field.Current.HasKeyboardFocus=$false
    Reject { Assert-PotatoTextTarget $field 'literal' } 'Unfocused input accepted.'
    $field.Current.HasKeyboardFocus=$true; $field.Current.ProcessId=-1
    Reject { Assert-PotatoTextTarget $field 'literal' } 'Wrong-process input accepted.'
    $field.Current.ProcessId=$PID
    $field | Add-Member ScriptMethod TryGetCurrentPattern { param($id,$value) return $false } -Force
    Reject { Assert-PotatoTextTarget $field 'literal' } 'Opaque target silently bypassed writable checks.'
    Assert-PotatoTextTarget $field 'literal' -AllowOpaque $true; $script:checks++
    Reject { Assert-PotatoTextTarget $field "literal`n" -AllowOpaque $true } 'Focused input accepted hidden Enter.'
    $field | Add-Member ScriptMethod TryGetCurrentPattern { param($id,$value) $value.Value=[pscustomobject]@{Current=@{IsReadOnly=$true}}; return $true } -Force
    Reject { Assert-PotatoTextTarget $field 'literal' -AllowOpaque $true } 'Focused input bypassed explicit read-only.'
    $rectElement=[pscustomobject]@{Current=@{BoundingRectangle=@{X=-200;Y=30;Width=201;Height=101}}}
    $rectElement | Add-Member ScriptMethod GetClickablePoint { throw 'No point' }
    $point=Get-PotatoClickPoint $rectElement -RelativeX 0.5 -RelativeY 1
    Check ($point.x -eq -100 -and $point.y -eq 130) 'Relative click did not use live element bounds.'
    Reject { Get-PotatoClickPoint $rectElement -RelativeX 1.1 -RelativeY 0 } 'Relative click escaped element.'
    Reject { Get-PotatoClickPoint $rectElement -RelativeX ([double]::NaN) -RelativeY 0 } 'Relative click accepted NaN.'
    Reject { Get-PotatoClickPoint $rectElement -RelativeX 0 } 'Relative click accepted incomplete geometry.'
    $fakeWindow=[pscustomobject]@{Current=@{ProcessId=$PID}}
    Check (-not (Test-PotatoLaunchedWindow $fakeWindow '' @() ([datetime]::MinValue))) 'Empty launcher name matched a window.'
    Check (-not (Test-PotatoLaunchedWindow $fakeWindow 'unrelated-process' @() ([datetime]::MinValue))) 'Unrelated window accepted as launched app.'
    Check (-not (Test-PotatoLaunchedWindow $fakeWindow (Get-Process -Id $PID).ProcessName @($PID) ([datetime]::MinValue))) 'Pre-existing window accepted as owned launch.'
    Check (-not (Test-PotatoTypedTextMatch "first`r`nsecond" "first`nsecond" Exact)) 'Exact mode hid line-ending differences.'
    Check (Test-PotatoTypedTextMatch "first`r`nsecond" "first`nsecond" NormalizedExact) 'Normalized readback failed.'
    Check (Test-PotatoTypedTextMatch "prefix`r`nmarker`r`nend" "marker`nend" NormalizedContains) 'Normalized containment failed.'
    $valueOnly=[pscustomobject]@{Current=@{NativeWindowHandle=0;ProcessId=$PID};value=''}
    $valueOnly | Add-Member ScriptMethod TryGetCurrentPattern {param($id,$pattern)
        if ($id -eq [Windows.Automation.ValuePattern]::Pattern) {
            $pattern.Value=[pscustomobject]@{Current=@{Value=$this.value;IsReadOnly=$false}};return $true
        }
        return $false
    }
    $clear=Clear-PotatoEditableText $valueOnly
    Check ($clear.method -eq 'AlreadyEmpty' -and -not $clear.inputSent) 'An actually empty value-only field required unsupported selection or Backspace.'
    foreach ($value in @('Existing filename',' ')) {
        $valueOnly.value=$value
        $failure=$null
        try {Clear-PotatoEditableText $valueOnly | Out-Null} catch {$failure=$_.Exception}
        Check ($failure.Data['PotatoErrorType'] -eq 'TextSelectionUnavailable' -and $failure.Data['NoInputSent']) 'Nonempty value-only text was treated as empty or had an unknown input outcome.'
    }
    $valueOnly | Add-Member ScriptMethod TryGetCurrentPattern {param($id,$pattern) return $false} -Force
    $failure=$null
    try {Clear-PotatoEditableText $valueOnly | Out-Null} catch {$failure=$_.Exception}
    Check ($failure.Data['PotatoErrorType'] -eq 'TextSelectionUnavailable') 'Unavailable readback was treated as an empty field.'
    $script:readCount=0
    function Get-PotatoEditableText { param($Element) $script:readCount++; if ($script:readCount -lt 6) {return 'stale'}; return 'updated' }
    $eventual=Wait-PotatoTypedText -Element $field -Expected 'updated' -Mode Exact -TimeoutMs 1200
    Check ($eventual.verified -and $eventual.attempts -eq 6 -and $eventual.elapsedMs -ge 400) 'Delayed UIA readback was falsely failed.'
    $unmatched=Wait-PotatoTypedText -Element $field -Expected 'absent' -Mode Exact -TimeoutMs 120
    Check (-not $unmatched.verified -and $unmatched.observedLength -eq 7) 'Unmatched input was falsely verified.'

    # A separate runspace holds the desktop mutex; competing commands must not dispatch.
    $ready = New-Object Threading.ManualResetEvent($false)
    $release = New-Object Threading.ManualResetEvent($false)
    $worker = [powershell]::Create()
    [void]$worker.AddScript({param($ready,$release,$sessionId)
        $m=New-Object Threading.Mutex($false,"Local\PoTATo.Desktop.$sessionId")
        try { [void]$m.WaitOne(); [void]$ready.Set(); [void]$release.WaitOne(10000) }
        finally { $m.ReleaseMutex(); $m.Dispose() }
    }).AddArgument($ready).AddArgument($release).AddArgument([Diagnostics.Process]::GetCurrentProcess().SessionId)
    $pending=$worker.BeginInvoke()
    try {
        Check ($ready.WaitOne(5000)) 'Lease fixture did not start.'
        $busy = Invoke-PotatoCliCommand hotkey @('-Keys','^s','-LeaseTimeoutMs','0') -AsObject
        Check ($busy.error.type -eq 'DesktopLeaseError' -and $busy.outcome -eq 'not-dispatched') 'Competing command was not stopped.'
    }
    finally { [void]$release.Set(); $worker.EndInvoke($pending) | Out-Null; $worker.Dispose(); $ready.Dispose(); $release.Dispose() }
    $blocked = Invoke-PotatoCliCommand hotkey @('-Keys','^s') -AsObject
    Check ($blocked.error.type -eq 'InteractionPolicyViolation' -and $blocked.outcome -eq 'not-dispatched') 'Policy failure was not structured.'
    "Interaction checks: $script:checks passed"
}
