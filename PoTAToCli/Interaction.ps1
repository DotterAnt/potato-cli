# Application-independent policy and desktop coordination. No GUI input here.
function Get-PotatoInteractionPolicy {
    param([hashtable] $ArgsMap, [string] $Command)
    $mode = [string](Get-PotatoArg $ArgsMap @('InteractionPolicy') 'GuiNavigation')
    if ($mode -notin @('VisibleControls', 'GuiNavigation', 'AllowShortcuts')) { throw 'Unknown InteractionPolicy. Use VisibleControls, GuiNavigation, or AllowShortcuts.' }
    $shortcut = $Command -eq 'hotkey' -or ($Command -eq 'type' -and
        (ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('PreDelete')) $false) -and
        (Get-PotatoArg $ArgsMap @('ClearMethod') 'Selection') -eq 'Shortcut')
    $reason = [string](Get-PotatoArg $ArgsMap @('FallbackReason') '')
    $evidence = [string](Get-PotatoArg $ArgsMap @('FallbackEvidence') '')
    if ((Get-PotatoArg $ArgsMap @('Scope')) -eq 'ForegroundWindow') {
        if ($Command -notin @('observe','select','read','wait-element','click','type','press-key')) { throw 'Guarded ForegroundWindow supports observation, selector clicks and guarded text/navigation; it never grants process ownership.' }
        if ($Command -eq 'type' -and (Get-PotatoArg $ArgsMap @('TargetMode') 'Writable') -eq 'Focused' -and -not (Get-PotatoArg $ArgsMap @('ExpectedFocusJson'))) { throw 'Focused typing in ForegroundWindow requires ExpectedFocusJson for the observed input control.' }
        if ([string]::IsNullOrWhiteSpace($reason) -or [string]::IsNullOrWhiteSpace($evidence)) { throw 'ForegroundWindow requires FallbackReason and FallbackEvidence for the observed system-hosted GUI route.' }
        if ((ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('Focus')) $false) -or
            (ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('ElementFocus')) $false)) { throw 'Guarded ForegroundWindow preserves focus; Focus/ElementFocus overrides are not allowed.' }
    }
    if ($Command -eq 'type') {
        $text = Get-PotatoArg $ArgsMap @('Text')
        if ($null -eq $text -and $ArgsMap._.Count) { $text = $ArgsMap._[0] }
        if ([string]$text -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]') { throw 'type rejects control characters that could invoke commands or clipboard operations.' }
    }
    if ($shortcut -and $mode -ne 'AllowShortcuts') { throw "InteractionPolicy $mode forbids hotkey and Shortcut clearing. Use visible controls or, under GuiNavigation, press-key for bounded navigation." }
    $opaque = $Command -eq 'type' -and (Get-PotatoArg $ArgsMap @('TargetMode') 'Writable') -eq 'Focused'
    if ($Command -eq 'press-key' -and $mode -eq 'VisibleControls') { throw 'InteractionPolicy VisibleControls forbids press-key. Preserve the explicitly requested strict policy.' }
    if (($opaque -or $Command -eq 'press-key') -and ([string]::IsNullOrWhiteSpace($reason) -or [string]::IsNullOrWhiteSpace($evidence))) {
        throw 'Focused typing and navigation require -FallbackReason and -FallbackEvidence describing the observed focused GUI surface.'
    }
    if ($shortcut -and ([string]::IsNullOrWhiteSpace($reason) -or [string]::IsNullOrWhiteSpace($evidence))) {
        throw 'Permitted shortcuts require -FallbackReason and -FallbackEvidence identifying the observed limitation. User authorization for AllowShortcuts is required.'
    }
    if ($Command -eq 'hotkey') {
        $keys = [string](Get-PotatoArg $ArgsMap @('Keys','Text'))
        if (-not $keys -and $ArgsMap._.Count) { $keys = [string]$ArgsMap._[0] }
        # One chord only: no grouped/repeated SendKeys expressions that hide clipboard input.
        if ($keys -notmatch '^([+^%]*)([a-z0-9]|\{[a-z0-9]+\})$') { throw 'hotkey accepts one chord, for example ^s, %{F4}, or {ENTER}; grouped sequences are not supported.' }
        $mods = $Matches[1]; $key = $Matches[2].Trim('{}').ToUpperInvariant()
        if (($mods.Contains('^') -and $key -in @('C','V','X','INSERT','INS')) -or
            ($mods.Contains('+') -and $key -in @('INSERT','INS','DELETE','DEL'))) { throw 'Clipboard shortcuts are not supported by this GUI testing CLI.' }
    }
    if ($Command -eq 'start') {
        $launch = [string](Get-PotatoArg $ArgsMap @('ProcessName','FilePath','Path'))
        if (-not $launch -and $ArgsMap._.Count) { $launch = [string]$ArgsMap._[0] }
        if ($launch -and ([IO.Path]::GetExtension($launch) -notin @('', '.exe'))) { throw 'start launches executables only. Open documents through the application GUI.' }
        $launcher=[IO.Path]::GetFileNameWithoutExtension($launch)
        $launchArgs=[string](Get-PotatoArg $ArgsMap @('Arguments','ArgumentList'))
        # Starting the executable with a bare document/resource still bypasses
        # the testcase's GUI Open route, even though ProcessName itself is valid.
        $firstArgument=$null
        if ($launchArgs -match '^\s*(?:"([^"]+)"|(\S+))') {
            $firstArgument=if ($Matches[1]) {$Matches[1]} else {$Matches[2]}
        }
        if ($firstArgument -and ($firstArgument -match '^(?:[A-Za-z]:[\\/]|\\\\|[A-Za-z][A-Za-z0-9+.-]*://)' -or [IO.File]::Exists($firstArgument))) {
            throw 'start Arguments begins with a document/path/URL. Start the executable without that resource, then use its observed GUI Open route; launch arguments are not a substitute for a tested open step.'
        }
        if (($launcher -eq 'cmd' -and $launchArgs -match '(?i)/[ck]\b.*\bstart\b') -or
            ($launcher -in @('powershell','pwsh') -and $launchArgs -match '(?i)\bStart-Process\b|-(?:enc|encodedcommand)\b') -or
            ($launcher -eq 'rundll32' -and $launchArgs -match '(?i)FileProtocolHandler|ShellExec_RunDLL') -or
            ($launcher -eq 'mshta' -and $launchArgs -match '(?i)javascript:|vbscript:|\.Run\s*\(')) {
            throw 'Shell/protocol launch wrappers bypass the recorded GUI file-opening route. Start the file manager with RequireNewWindow, navigate its visible UI, then focus the observed viewer window. Do not keep a launcher alive to manufacture ownership.'
        }
    }
    return [ordered]@{ mode=$mode; shortcutUsed=[bool]$shortcut; navigationUsed=($Command -eq 'press-key'); opaqueTyping=$opaque; fallbackReason=$reason; fallbackEvidence=$evidence }
}

function Enter-PotatoDesktopLease {
    param([int] $TimeoutMs = 5000)
    if ($TimeoutMs -lt 0 -or $TimeoutMs -gt 60000) { throw 'LeaseTimeoutMs must be between 0 and 60000.' }
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $mutex = New-Object System.Threading.Mutex($false, "Local\PoTATo.Desktop.$sessionId")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'DesktopBusy: another CLI command owns this desktop; no action was dispatched.' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Assert-PotatoTextTarget {
    param([object] $Element, [string] $Text, [bool] $RequireFocus = $true, [bool] $AllowOpaque = $false)
    if (-not $Element -or -not $Element.Current.IsEnabled -or ($RequireFocus -and -not $Element.Current.HasKeyboardFocus)) {
        throw 'Text input requires an enabled control with confirmed keyboard focus.'
    }
    if (-not (Test-PotatoInputOwnership $Element)) {
        throw 'Focused text control does not belong to the working application. Resolve a scoped selector before typing.'
    }
    $role = Get-PotatoControlTypeName $Element
    $pattern = $null
    $writable = $false
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        if ($pattern.Current.IsReadOnly) { throw 'Target explicitly reports read-only; focused fallback cannot override it.' }
        $writable = -not $pattern.Current.IsReadOnly
    }
    elseif ($role -in @('Document','Edit') -and $Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
        $readOnly = $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::IsReadOnlyAttribute)
        if ($readOnly -is [bool] -and $readOnly) { throw 'Target explicitly reports read-only; focused fallback cannot override it.' }
        $writable = $readOnly -is [bool] -and -not $readOnly
    }
    if (-not $writable -and $Element.Current.NativeWindowHandle) {
        Initialize-PotatoWindowIdentity
        $writable=[PotatoWindowIdentity]::IsStandardEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId,$true)
        if (-not $writable -and [PotatoWindowIdentity]::IsStandardEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId,$false)) {throw 'Target explicitly reports read-only; focused fallback cannot override it.'}
    }
    if (-not $writable -and -not $AllowOpaque) { throw 'Target is not a confirmed writable text control. For an observed opaque editor, use type -TargetMode Focused with FallbackReason/FallbackEvidence after visibly focusing it; assert the committed result separately.' }
    if ($Text -match '[\r\n\t]' -and ($role -ne 'Document' -or $AllowOpaque)) {
        throw 'Newline/tab typing is limited to Document controls. Use visible controls for dialog submission and navigation.'
    }
}

function Test-PotatoTypedPath {
    param([string]$Text, [string]$Kind)
    try {
        if ($Kind -notin @('SaveFile','OpenFile','Directory')) { throw 'PathKind must be SaveFile, OpenFile, or Directory.' }
        # File dialogs interpret relative paths against their own location, not the shell's.
        # Check the literal string; never expand environment variables, trim, or rewrite input.
        if ($Text -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/? .][^\\/?]*\\[^\\/?]+(?:\\|$))') {
            throw 'Provide an absolute drive or UNC filename, not a relative or drive-relative path.'
        }
        if ($Text.Contains('/')) {
            throw "GUI filename paths require backslash separators. Use: $($Text.Replace('/','\'))"
        }
        if ($Text -match '[<>"|?*\x00-\x1f]') { throw 'The filename contains invalid path characters or surrounding quotes.' }
        $fullPath=[IO.Path]::GetFullPath($Text)
        if ($Kind -eq 'Directory') {
            if (-not [IO.Directory]::Exists($fullPath)) { throw "Directory does not exist: $Text" }
        } else {
            if (-not [IO.Path]::GetFileName($fullPath) -or [IO.Directory]::Exists($fullPath)) { throw 'Provide a file path, not a directory.' }
            $parent=[IO.Path]::GetDirectoryName($fullPath)
            if (-not [IO.Directory]::Exists($parent)) { throw "Destination directory does not exist: $parent. Use a prepared output folder or create the required folder before entering the filename." }
            if ($Kind -eq 'OpenFile' -and -not [IO.File]::Exists($fullPath)) { throw "File to open does not exist: $Text" }
        }
        return [ordered]@{kind=$Kind;path=$Text;parentPath=[IO.Path]::GetDirectoryName($fullPath);validated=$true}
    } catch {
        $failure=New-Object System.ArgumentException("Path validation failed before typing: $($_.Exception.Message) No input was sent; no file or directory was created.")
        $failure.Data['PotatoErrorType']='PathValidationFailed'
        $failure.Data['NoInputSent']=$true
        throw $failure
    }
}

function Clear-PotatoEditableText {
    param([object]$Element, [string]$Method='Selection')
    # A real empty readback needs no selection or Backspace. Value-only providers
    # can still accept keyboard input even when they cannot select existing text.
    $existing=$null
    try { $existing=Get-PotatoEditableText -Element $Element } catch { }
    if ($null -ne $existing -and ([string]$existing).Length -eq 0) {
        return @{method='AlreadyEmpty';inputSent=$false}
    }
    if ($Method -eq 'Shortcut') {
        [System.Windows.Forms.SendKeys]::SendWait('^a')
    } else {
        $selection=$null
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$selection)) {
            $selection.DocumentRange.Select()
        } else {
            Initialize-PotatoWindowIdentity
            if ([PotatoWindowIdentity]::IsStandardEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId,$true)) {
                [PotatoWindowIdentity]::SelectEditText([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId)
            } else {
                $failure=New-Object InvalidOperationException('PreDelete cannot select existing text. Inspect the field and use a tested visible selection route, or explicit -ClearMethod Shortcut only if permitted by the testcase.')
                $failure.Data['PotatoErrorType']='TextSelectionUnavailable'
                $failure.Data['NoInputSent']=$true
                throw $failure
            }
        }
    }
    [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')
    return @{method=$Method;inputSent=$true}
}

# Same-process fields and UIA descendants/Win32-owned dialogs of the actual working
# window are accepted. Matching executable names alone never establishes ownership.
function Test-PotatoInputOwnership {
    param([object] $Element)
    $working = if ($script:InputScope) {$script:InputScope} else {$script:CurrentState.working}
    if (-not $Element -or -not $working) { return $false }
    if (-not $working.windowScoped -and $Element.Current.ProcessId -eq $working.processId) { return $true }
    $node = $Element
    for ($i=0; $i -lt 32 -and $node; $i++) {
        if ($working.nativeWindowHandle -and $node.Current.NativeWindowHandle -eq $working.nativeWindowHandle) { return $true }
        if ($node.Current.NativeWindowHandle) {
            Initialize-PotatoWindowIdentity
            if ([PotatoWindowIdentity]::IsOwnedBy([IntPtr]$node.Current.NativeWindowHandle, [IntPtr]$working.nativeWindowHandle)) { return $true }
        }
        try { $node = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($node) } catch { return $false }
    }
    return $false
}

function Initialize-PotatoWindowIdentity {
    if (-not ('PotatoWindowIdentity' -as [type])) {
        $paths=@((Join-Path $PSScriptRoot 'WindowIdentity.cs'))
        if (-not ('PotatoLiteralInput' -as [type])) { $paths += Join-Path $PSScriptRoot 'LiteralInput.cs' }
        Add-Type -Path $paths
    }
}

function Assert-PotatoForegroundInput {
    param([object] $Element,[bool] $NoInputSent=$true)
    $native=Get-PotatoNativeInputState
    if (-not $Element -or -not $Element.Current.IsEnabled -or -not (Test-PotatoNativeElementFocus $Element $native)) {
        try {
            if ($Element) {$native.expectedTarget=@{name=$Element.Current.Name;automationId=$Element.Current.AutomationId;
                nativeWindowHandle=$Element.Current.NativeWindowHandle;processId=$Element.Current.ProcessId;
                hasKeyboardFocus=$Element.Current.HasKeyboardFocus;isEnabled=$Element.Current.IsEnabled}}
        } catch { } # A stale provider must not replace the original focus failure.
        $failure=New-PotatoFocusFailure 'Input requires enabled keyboard focus in the working application or its owned dialog. Inspect error.focus and visibly focus the observed target before retrying.' $native
        $failure.Data['NoInputSent']=$NoInputSent
        throw $failure
    }
    Initialize-PotatoWindowIdentity
    $handle = [PotatoWindowIdentity]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) {
        $failure=New-PotatoFocusFailure 'No foreground window; inspect error.focus before retrying.' $native
        $failure.Data['NoInputSent']=$NoInputSent
        throw $failure
    }
    $foreground = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if (-not (Test-PotatoInputOwnership $foreground)) {
        $failure=New-PotatoFocusFailure 'Foreground changed to another application; inspect error.focus before retrying.' $native 'InputFocusChanged'
        $failure.Data['NoInputSent']=$NoInputSent
        throw $failure
    }
}

function Invoke-PotatoPressKey {
    param([hashtable] $ArgsMap)
    $key = [string](Get-PotatoArg $ArgsMap @('Key'))
    $keys = @{Tab='{TAB}';ShiftTab='+{TAB}';Enter='{ENTER}';Escape='{ESC}';Left='{LEFT}';Right='{RIGHT}';Up='{UP}';Down='{DOWN}'}
    if (-not $keys.ContainsKey($key)) { throw 'press-key accepts Tab, ShiftTab, Enter, Escape, Left, Right, Up, or Down only; application shortcuts are not navigation.' }
    $count = ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('Count')) 1
    if ($count -lt 1 -or $count -gt 20 -or ($key -in @('Enter','Escape') -and $count -ne 1)) { throw 'Count must be 1..20; Enter and Escape must be sent once and followed by an observation.' }
    # Refresh a replaced splash/working window without activating it or stealing
    # focus from a menu or modal dialog.
    if (-not $script:InputScope) { [void](Get-PotatoWorkingElement -Required) }
    $before = $null
    $initialFocus = $null
    for ($i=0; $i -lt $count; $i++) {
        try {
            $inputFocus=Wait-PotatoInputFocus (Get-PotatoArg $ArgsMap @('ExpectedFocusJson')) (ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('FocusTimeoutMs')) 2000)
            $focused=$inputFocus.element
            Assert-PotatoInputFocusUnchanged $inputFocus
            if ($i -eq 0) { $initialFocus=$inputFocus.native }
            elseif ($inputFocus.native.foregroundHandle -ne $initialFocus.foregroundHandle -or
                ($key -in @('Left','Right','Up','Down') -and $inputFocus.native.focusHandle -ne $initialFocus.focusHandle)) {
                throw (New-PotatoFocusFailure 'Navigation changed its window or arrow-key target. Remaining keys were not sent; inspect the new state.' $inputFocus.native 'InputFocusChanged')
            }
            if ($i -eq 0) { $before = ConvertTo-PotatoElementInfo $focused }
            Send-PotatoNavigationKey $key $inputFocus.native
        } catch {
            if ($i -gt 0) { $_.Exception.Data['NoInputSent']=$false }
            throw
        }
        # Allow the GUI to consume queued input before checking the next target.
        Start-Sleep -Milliseconds 30
    }
    # Committing a control can invalidate its provider after input was delivered.
    # Optional focus readback must not turn that delivery into a failed command.
    $after=$null; $afterError=$null
    try {
        $after=Get-PotatoFocusedElement
        if ($after) { $after=ConvertTo-PotatoElementInfo $after }
    } catch { $afterError=@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message};$after=$null }
    [ordered]@{ sent=$true; key=$key; count=$count; before=$before; after=$after; afterError=$afterError; verified=$null; verificationPerformed=$false }
}

function Send-PotatoNavigationKey {
    param([string]$Key,$Native)
    Initialize-PotatoWindowIdentity
    [PotatoLiteralInput]::SendNavigation($Key,$Native.foregroundHandle,$Native.focusHandle)
}

function Test-PotatoModalAncestor {
    param([object] $Element)
    $node = $Element
    for ($i=0; $i -lt 32 -and $node; $i++) {
        $pattern = $null
        if ($node.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern) -and $pattern.Current.IsModal) { return $true }
        $node = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
    }
    return $false
}
