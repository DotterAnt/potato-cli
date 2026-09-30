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
    if ($Info.name) { $selector.Name = $Info.name }
    if ($Info.automationId) { $selector.AutomationId = $Info.automationId }
    # Names containing wildcard metacharacters need an exact regex selector.
    if ($Info.name -match '[*?\[]' -or $Info.automationId -match '[*?\[]') {
        foreach ($key in @($selector.Keys)) { $selector[$key] = '^' + [regex]::Escape([string]$selector[$key]) + '$' }
        $selector.Regex = $true
    }
    $value = [ordered]@{name=$Info.name; id=$Info.automationId; role=$Info.controlType;
        enabled=$Info.isEnabled; offscreen=$Info.isOffscreen; focused=$Info.hasKeyboardFocus;
        patterns=@($Info.supportedPatterns); bounds=$Info.boundingRectangle; selector=$selector}
    if ($Info.propertyErrors.Count) { $value.propertyErrors = $Info.propertyErrors }
    if ($Info.controlType -eq 'Pane' -and -not $Info.supportedPatterns.Count) {
        $value.hint = 'Opaque UIA node. Do not assume Pane is a stable role; inspect focus/screenshot if input is needed.'
    }
    return $value
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
