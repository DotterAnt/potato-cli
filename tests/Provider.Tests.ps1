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
    function Resolve-PotatoCommandTarget { @{ok=$false;error='Fixture target absent'} }
    $failure=$null
    try {Invoke-PotatoClick @{Name='Absent'} | Out-Null} catch {$failure=$_.Exception}
    Check ($failure.Data['PotatoErrorType'] -eq 'TargetNotFound' -and $failure.Data['NoInputSent']) 'Selector miss was reported as possible input dispatch.'
    "Provider checks: $script:checks passed"
}
