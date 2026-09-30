# Native keyboard focus supplements providers whose FocusedElement contradicts
# HasKeyboardFocus. It never activates, selects, or edits a control.
function Get-PotatoNativeInputState {
    Initialize-PotatoWindowIdentity
    $native=[PotatoWindowIdentity]::ReadFocus()
    $working=$script:CurrentState.working
    $owned=$working -and ($native.foregroundProcessId -eq $working.processId -or
        [PotatoWindowIdentity]::IsOwnedBy([IntPtr]$native.foregroundHandle,[IntPtr]$working.nativeWindowHandle))
    [ordered]@{ready=[bool]($owned -and $native.stable -and $native.enabled -and $native.withinForeground);
        owned=[bool]$owned;stable=$native.stable;enabled=$native.enabled;withinForeground=$native.withinForeground;
        foregroundHandle=$native.foregroundHandle;focusHandle=$native.focusHandle;
        foregroundProcessId=$native.foregroundProcessId;focusProcessId=$native.focusProcessId;
        caretHandle=$native.caretHandle;menuActive=$native.menuActive}
}

function Test-PotatoNativeElementFocus {
    param($Element,$Native)
    if (-not $Element -or -not $Native.ready -or -not (Test-PotatoInputOwnership $Element)) { return $false }
    $node=$Element
    for ($i=0;$i -lt 32 -and $node;$i++) {
        $handle=[IntPtr]$node.Current.NativeWindowHandle
        if ($handle -ne [IntPtr]::Zero) {
            $focus=[IntPtr]$Native.focusHandle
            if ($handle -eq $focus) { return $true }
            # A stale, false-focus UIA node cannot authorize arbitrary siblings
            # merely because they share the same application frame.
            if (-not $Element.Current.HasKeyboardFocus) { return $false }
            return [PotatoWindowIdentity]::IsChild($handle,$focus) -or [PotatoWindowIdentity]::IsChild($focus,$handle)
        }
        $node=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($node)
    }
    return $false
}

function Get-PotatoInputFocus {
    $native=Get-PotatoNativeInputState
    if (-not $native.ready) { return @{ready=$false;native=$native;candidates=@()} }
    $candidates=@()
    try {
        $uia=Get-PotatoFocusedElement
        if ($uia -and $uia.Current.IsEnabled -and (Test-PotatoNativeElementFocus $uia $native)) { $candidates+=,$uia }
    } catch {}
    try {
        $nativeElement=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]$native.focusHandle)
        if ($nativeElement -and $nativeElement.Current.IsEnabled -and (Test-PotatoInputOwnership $nativeElement)) { $candidates+=,$nativeElement }
    } catch {}
    return @{ready=($candidates.Count -gt 0);native=$native;candidates=$candidates}
}

function New-PotatoFocusFailure {
    param([string]$Message,$Native,[string]$Type='InputFocusNotReady')
    $failure=New-Object InvalidOperationException($Message)
    $failure.Data['PotatoErrorType']=$Type
    $failure.Data['NoInputSent']=$true
    $failure.Data['focus']=$Native
    return $failure
}

function Wait-PotatoInputFocus {
    param([string]$SelectorJson,[int]$TimeoutMs=2000)
    if ($TimeoutMs -lt 0 -or $TimeoutMs -gt 10000) { throw 'FocusTimeoutMs must be 0..10000.' }
    $selector=$null
    if ($SelectorJson) {
        $selector=ConvertFrom-PotatoJsonArgument $SelectorJson
        if (-not $selector -or (-not $selector.Name -and -not $selector.AutomationId -and -not $selector.ClassName -and -not $selector.ControlType) -or $selector.path -or $selector.target) { throw 'ExpectedFocusJson needs a simple identity selector, not a path or empty selector.' }
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $focus=$null
    do {
        try {
            $focus=Get-PotatoInputFocus
            foreach ($element in $focus.candidates) {
                if ($focus.ready -and (-not $selector -or (Test-PotatoElementMatch $element $selector))) {
                    return @{element=$element;native=$focus.native;
                        source=$(if ($element.Current.HasKeyboardFocus) {'UIAutomation+Win32'} else {'Win32'});
                        waitMs=$watch.ElapsedMilliseconds}
                }
            }
        } catch {}
        if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(50,$TimeoutMs-$watch.ElapsedMilliseconds)))
    } while ($true)
    throw (New-PotatoFocusFailure 'The expected owned keyboard target is not ready. No input was sent. Inspect error.focus and observe the visible target once; do not retry different guessed selectors or steal focus from a dialog.' $focus.native)
}

function Assert-PotatoInputFocusUnchanged {
    param($Focus)
    $current=Get-PotatoNativeInputState
    if (-not $current.ready -or $current.foregroundHandle -ne $Focus.native.foregroundHandle -or $current.focusHandle -ne $Focus.native.focusHandle -or
        ($Focus.source -eq 'UIAutomation+Win32' -and -not $Focus.element.Current.HasKeyboardFocus)) {
        throw (New-PotatoFocusFailure 'Keyboard focus changed before input; observe before retrying. No input was sent.' $current 'InputFocusChanged')
    }
}
