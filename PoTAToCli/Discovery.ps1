# Application-independent discovery helpers. Never activate a window while observing.
function Get-PotatoFocusedWindow {
    [void](Get-PotatoWorkingElement -Required)
    Initialize-PotatoWindowIdentity
    $handle = [PotatoWindowIdentity]::ForegroundRoot()
    if ($handle -eq [IntPtr]::Zero) { throw 'No foreground window to inspect.' }
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if (-not (Test-PotatoInputOwnership $element)) {
        throw 'FocusedWindow belongs to another application. Focus the owned application explicitly.'
    }
    return $element
}

function Get-PotatoExplicitScope {
    param([hashtable]$ArgsMap)
    $scope = [string](Get-PotatoArg $ArgsMap @('Scope') 'Working')
    if ($scope -eq 'FocusedWindow') { return Get-PotatoFocusedWindow }
    if ($scope -ne 'Working') { throw 'Scope must be Working or FocusedWindow.' }
    return $null
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
