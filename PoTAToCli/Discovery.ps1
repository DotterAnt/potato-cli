# Application-independent discovery helpers. Never activate a window while observing.
function New-PotatoScopeFailure {
    param([string]$Message)
    $failure=New-Object InvalidOperationException($Message)
    $failure.Data['PotatoErrorType']='ScopeNotReady'; $failure.Data['NoInputSent']=$true
    return $failure
}

function Get-PotatoGuardedForegroundWindow {
    param([string]$WindowSelectorJson)
    $selector=ConvertFrom-PotatoJsonArgument $WindowSelectorJson
    # A broker is a per-command GUI scope, never an adopted process or cleanup target.
    $keys=if ($selector -is [Collections.IDictionary]) {@($selector.Keys)} else {@($selector.PSObject.Properties.Name)}
    if (-not $selector -or -not ($selector.Name -is [string]) -or [string]::IsNullOrWhiteSpace($selector.Name) -or
        -not ($selector.ClassName -is [string]) -or [string]::IsNullOrWhiteSpace($selector.ClassName) -or
        @($keys | Where-Object {$_ -notin @('Name','ClassName','ProcessId')}).Count -or
        ($keys -contains 'ProcessId' -and ($selector.ProcessId -notmatch '^\d+$' -or [int]$selector.ProcessId -lt 1))) {
        throw 'ForegroundWindow requires WindowSelectorJson with an exact observed Name and ClassName, and optional ProcessId only.'
    }
    Initialize-PotatoWindowIdentity
    $handle=[PotatoWindowIdentity]::ForegroundRoot()
    if ($handle -eq [IntPtr]::Zero) { throw (New-PotatoScopeFailure 'No foreground window matches the guarded scope.') }
    $element=[Windows.Automation.AutomationElement]::FromHandle($handle)
    if ($element.Current.Name -cne $selector.Name -or $element.Current.ClassName -cne $selector.ClassName -or
        ($selector.ProcessId -and $element.Current.ProcessId -ne [int]$selector.ProcessId)) {
        throw (New-PotatoScopeFailure 'Foreground window does not match WindowSelectorJson. No action was dispatched; inspect the current window instead of guessing coordinates.')
    }
    return $element
}

function Get-PotatoFocusedWindow {
    [void](Get-PotatoWorkingElement -Required)
    Initialize-PotatoWindowIdentity
    $handle = [PotatoWindowIdentity]::ForegroundRoot()
    if ($handle -eq [IntPtr]::Zero) { throw (New-PotatoScopeFailure 'No foreground window to inspect.') }
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if (-not (Test-PotatoInputOwnership $element)) {
        throw (New-PotatoScopeFailure 'FocusedWindow belongs to another application. For an observed system-hosted dialog, use Scope ForegroundWindow with an exact WindowSelectorJson and fallback evidence; this does not adopt its process.')
    }
    return $element
}

function Assert-PotatoGuardedTarget {
    param($Element,[hashtable]$ArgsMap)
    $root=Get-PotatoGuardedForegroundWindow (Get-PotatoArg $ArgsMap @('WindowSelectorJson'))
    $node=$Element
    for ($i=0;$i -lt 32 -and $node;$i++) {
        if ($node.Current.NativeWindowHandle -eq $root.Current.NativeWindowHandle -and $node.Current.ProcessId -eq $root.Current.ProcessId) {return}
        $node=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($node)
    }
    throw (New-PotatoScopeFailure 'Click target is no longer inside the guarded foreground window. No input was sent.')
}

function Get-PotatoExplicitScope {
    param([hashtable]$ArgsMap)
    $scope = [string](Get-PotatoArg $ArgsMap @('Scope') 'Working')
    if ($scope -eq 'FocusedWindow') { return Get-PotatoFocusedWindow }
    if ($scope -eq 'ForegroundWindow') { return Get-PotatoGuardedForegroundWindow (Get-PotatoArg $ArgsMap @('WindowSelectorJson')) }
    if ($scope -ne 'Working') { throw 'Scope must be Working, FocusedWindow or guarded ForegroundWindow.' }
    return $null
}

function Find-PotatoObservedTreeMatches {
    param($Parent,$Selector,[bool]$Recurse=$true,[int]$MaxResults=0,[int]$NodeLimit=1500,[int]$BudgetMs=1500)
    # Match through the same unfiltered child traversal used by observe. Some
    # hybrid providers omit descendants only when a search predicate is pushed down.
    $queue=New-Object Collections.Queue
    $queue.Enqueue(@{element=$Parent;depth=0})
    $watch=[Diagnostics.Stopwatch]::StartNew(); $visited=0; $found=@()
    $complete=$true
    while ($queue.Count) {
        if ($visited -ge $NodeLimit -or $watch.ElapsedMilliseconds -ge $BudgetMs) {$complete=$false;break}
        $node=$queue.Dequeue()
        try { $children=$node.element.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition) }
        catch { $complete=$false;continue }
        foreach ($child in $children) {
            $visited++
            if ($visited -gt $NodeLimit -or $watch.ElapsedMilliseconds -ge $BudgetMs) {$complete=$false;break}
            try { $matches=Test-PotatoElementMatch $child $Selector } catch { $complete=$false;continue }
            if ($matches) {
                $found+=,$child
                if ($MaxResults -gt 0 -and $found.Count -ge $MaxResults) { return @{matches=$found;complete=$true} }
            }
            if ($Recurse) {
                if ($node.depth -ge 31) {$complete=$false} else {$queue.Enqueue(@{element=$child;depth=$node.depth+1})}
            }
        }
    }
    if (-not $complete) {
        $failure=New-Object InvalidOperationException('Scoped provider traversal is incomplete. Narrow PathJson to an observed container; do not infer absence or uniqueness from a partial tree.')
        $failure.Data['PotatoErrorType']='SearchIncomplete'; $failure.Data['NoInputSent']=$true
        throw $failure
    }
    return @{matches=$found;complete=$true}
}

function ConvertTo-PotatoCompactElement {
    param($Info)
    if (-not $Info) { return $null }
    $selector = [ordered]@{}
    # Editable controls often expose their changing contents as Name.
    $mutableName=$Info.automationId -and ($Info.controlType -eq 'Edit' -or $Info.className -eq 'Edit' -or $Info.supportedPatterns -contains 'Value')
    if ($Info.name -and -not $mutableName) { $selector.Name = $Info.name }
    if ($Info.automationId) { $selector.AutomationId = $Info.automationId }
    # Names containing wildcard metacharacters need an exact regex selector.
    if ($Info.name -match '[*?\[]' -or $Info.automationId -match '[*?\[]') {
        foreach ($key in @($selector.Keys)) { $selector[$key] = '^' + [regex]::Escape([string]$selector[$key]) + '$' }
        $selector.Regex = $true
    }
    $value = [ordered]@{name=$Info.name; id=$Info.automationId; role=$Info.controlType;
        className=$Info.className;
        enabled=$Info.isEnabled; offscreen=$Info.isOffscreen; focused=$Info.hasKeyboardFocus;
        patterns=@($Info.supportedPatterns); bounds=$Info.boundingRectangle; selector=$selector}
    if ($Info.propertyErrors.Count) { $value.propertyErrors = $Info.propertyErrors }
    if ($Info.controlType -eq 'Pane' -and -not $Info.supportedPatterns.Count) {
        $value.hint = 'Opaque UIA node. Do not assume Pane is a stable role; inspect focus/screenshot if input is needed.'
    }
    if ($Info.controlType -eq 'Edit') { $value.typingHint='Use type with a writable selector. Multiline literals currently require a Document target; do not submit a single-line field with embedded newlines.' }
    if ($Info.controlType -eq 'Document' -and $Info.supportedPatterns -contains 'Text') { $value.typingHint='Candidate for multiline literal typing; type checks read-only status before input.' }
    return $value
}

function Get-PotatoUniqueSelector {
    param($Selector)
    $copy=@{}
    if ($Selector -is [System.Collections.IDictionary]) {
        foreach ($key in $Selector.Keys) { $copy[$key]=$Selector[$key] }
    } else {
        foreach ($property in $Selector.PSObject.Properties) { $copy[$property.Name]=$property.Value }
    }
    $copy.FindFirst=$false
    $copy.InteractiveOnly=$true
    return $copy
}

function Assert-PotatoUniqueMatches {
    param([object[]]$Matches)
    if ($Matches.Count -le 1) { return }
    $failure=New-Object InvalidOperationException('Ambiguous target: multiple visible enabled controls match. Use the returned candidates to add an observed ID, role, class or parent scope. No input was sent.')
    $failure.Data['PotatoErrorType']='AmbiguousTarget'
    $failure.Data['NoInputSent']=$true
    $failure.Data['candidates']=@($Matches | ForEach-Object { ConvertTo-PotatoCompactElement (ConvertTo-PotatoElementInfo $_) })
    throw $failure
}

function Get-PotatoFocusedElement { [System.Windows.Automation.AutomationElement]::FocusedElement }

function Wait-PotatoExpectedFocus {
    param([string]$SelectorJson, [int]$TimeoutMs=2000)
    return (Wait-PotatoInputFocus $SelectorJson $TimeoutMs).element
}

function Get-PotatoCompactElements {
    param($Tree)
    $items=@(ConvertTo-PotatoCompactTree $Tree)
    $groups=@{}
    foreach ($item in $items) {
        $key=$item.selector | ConvertTo-Json -Compress
        if (-not $groups.ContainsKey($key)) { $groups[$key]=New-Object System.Collections.ArrayList }
        [void]$groups[$key].Add($item)
    }
    foreach ($same in $groups.Values) {
        if ($same.Count -le 1) { continue }
        $roles=@{}; $classes=@{}
        foreach ($item in $same) {
            if ($item.role) { $roles[$item.role]++ }
            if ($item.className) { $classes[$item.className]++ }
        }
        foreach ($item in $same) {
            $item.ambiguous=$true
            if ($item.role -and $item.role -ne 'Pane' -and $roles[$item.role] -eq 1) {
                $item.selector.ControlType=if ($item.selector.Regex) {'^'+[regex]::Escape($item.role)+'$'} else {$item.role}
                $item.ambiguous=$false
            } elseif ($item.className -and $classes[$item.className] -eq 1) {
                $item.selector.ClassName=if ($item.selector.Regex) {'^'+[regex]::Escape($item.className)+'$'} else {$item.className}
                $item.ambiguous=$false
            }
        }
    }
    return $items
}

function ConvertTo-PotatoCompactTree {
    param($Node, [int]$Depth=0)
    if (-not $Node) { return }
    $info=$Node.element
    # Structural unnamed panes are not actionable, but still traverse children.
    if ($info.name -or $info.automationId -or $info.hasKeyboardFocus -or $info.supportedPatterns.Count) {
        $item=ConvertTo-PotatoCompactElement $info
        $item.depth=$Depth
        $item
    }
    foreach ($child in $Node.children) { ConvertTo-PotatoCompactTree $child ($Depth+1) }
}
