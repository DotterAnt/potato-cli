param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    $script:checks=0
    function Check($value,$message) {if (-not $value) {throw $message};$script:checks++}
    Initialize-PotatoAutomationTypes
    function Find-ProviderEligibilityFilter($condition) {
        if ($condition -is [Windows.Automation.PropertyCondition]) {return $condition.Property -in @([Windows.Automation.AutomationElement]::IsOffscreenProperty,[Windows.Automation.AutomationElement]::IsEnabledProperty)}
        if ($condition -is [Windows.Automation.AndCondition] -or $condition -is [Windows.Automation.OrCondition]) {
            foreach ($child in $condition.GetConditions()) {if (Find-ProviderEligibilityFilter $child) {return $true}}
        }
        return $false
    }
    $script:items=@(foreach ($pair in @(@($true,$false),@($true,$true),@($false,$false))) {
        [pscustomobject]@{Current=@{Name='Choice';IsEnabled=$pair[0];IsOffscreen=$pair[1];ControlType=[Windows.Automation.ControlType]::ListItem;LocalizedControlType='list item'}}
    })
    $parent=[pscustomobject]@{}
    $parent | Add-Member ScriptMethod FindAll {param($scope,$condition)
        # Models a custom provider whose compound eligibility query disagrees
        # with its own visible/enabled property getters.
        if (Find-ProviderEligibilityFilter $condition) {return @()}
        return $script:items
    }
    $found=@(Find-PotatoElement -Parent $parent -Selector @{Name='Choice';ControlType='ListItem';InteractiveOnly=$true} -TimeoutMs 0)
    Check ($found.Count -eq 1 -and $found[0].Current.IsEnabled -and -not $found[0].Current.IsOffscreen) 'Provider query hid a visible item or accepted disabled/offscreen items.'
    $fake=[pscustomobject]@{}
    $fake | Add-Member ScriptMethod SetFocus {throw 'Popup would be dismissed by SetFocus'}
    function Resolve-PotatoCommandTarget { @{ok=$true;element=$fake;selector=@{Name='Choice'}} }
    function ConvertTo-PotatoElementInfo { @{isEnabled=$true;supportedPatterns=@('SelectionItem')} }
    function Get-PotatoWorkingElement {throw 'Popup would be dismissed by focusing its parent'}
    function Invoke-PotatoElementDefaultAction {'SelectionItemPattern'}
    function Save-PotatoState {}
    $script:CurrentState=@{}
    $result=Invoke-PotatoClick @{Name='Choice'}
    Check ($result.clicked -and $result.action -eq 'SelectionItemPattern') 'Default semantic click changed focus before selecting a popup item.'
    $script:mouseClicks=0
    $script:semanticClicks=0
    $script:info=@{isEnabled=$true;isOffscreen=$false;controlType='Button';nativeWindowHandle=123;
        supportedPatterns=@('Invoke');boundingRectangle=@{width=80;height=25}}
    function ConvertTo-PotatoElementInfo { $script:info }
    function Invoke-PotatoElementDefaultAction { $script:semanticClicks++; 'InvokePattern' }
    function Get-PotatoClickPoint { @{x=20;y=20} }
    function Move-PotatoMouse { }
    function Invoke-PotatoMouseClick { $script:mouseClicks++ }
    $result=Invoke-PotatoClick @{Name='Any native push button';Focus=$false}
    Check ($result.action -eq 'Mouse' -and $script:mouseClicks -eq 1 -and $script:semanticClicks -eq 0) 'Auto invoked a native button synchronously before falling back to mouse.'
    $script:info.nativeWindowHandle=0
    $result=Invoke-PotatoClick @{Name='Windowless action';Focus=$false}
    Check ($result.action -eq 'InvokePattern' -and $script:semanticClicks -eq 1 -and $script:mouseClicks -eq 1) 'Windowless UIA action lost its semantic activation.'
    $script:info.nativeWindowHandle=123;$script:info.controlType='MenuItem'
    $result=Invoke-PotatoClick @{Name='Menu action';Focus=$false}
    Check ($result.action -eq 'InvokePattern' -and $script:semanticClicks -eq 2 -and $script:mouseClicks -eq 1) 'Menu item was incorrectly classified as a native push button.'
    $script:info.controlType='Button'
    $pattern=[pscustomobject]@{}
    $pattern | Add-Member ScriptMethod Invoke {$script:semanticClicks++}
    $fake | Add-Member ScriptMethod TryGetCurrentPattern {param($id,$value) $value.Value=$pattern; return $true}
    $result=Invoke-PotatoClick @{Name='Explicit action';Focus=$false;Method='Invoke'}
    Check ($result.action -eq 'InvokePattern' -and $script:semanticClicks -eq 3 -and $script:mouseClicks -eq 1) 'Explicit Invoke was silently replaced or double-dispatched.'
    function Resolve-PotatoCommandTarget { @{ok=$false;error='Fixture target absent'} }
    $failure=$null
    try {Invoke-PotatoClick @{Name='Absent'} | Out-Null} catch {$failure=$_.Exception}
    Check ($failure.Data['PotatoErrorType'] -eq 'TargetNotFound' -and $failure.Data['NoInputSent']) 'Selector miss was reported as possible input dispatch.'
    "Provider checks: $script:checks passed"
}
