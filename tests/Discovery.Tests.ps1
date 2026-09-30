param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    $script:checks=0
    function Check($value,$message) {if (-not $value) {throw $message}; $script:checks++}
    function Reject([scriptblock]$body,$message) {$errorValue=$null;try {& $body | Out-Null} catch {$errorValue=$_.Exception};Check ([bool]$errorValue) $message;return $errorValue}
    Initialize-PotatoAutomationTypes
    function New-Node($name,$children=@(),$enabled=$true) {
        $node=[pscustomobject]@{children=$children;Current=@{Name=$name;ProcessId=123;IsEnabled=$enabled;IsOffscreen=$false;ControlType=[Windows.Automation.ControlType]::Button;LocalizedControlType='button'}}
        $node | Add-Member ScriptMethod FindFirst {param($scope,$condition) return $null}
        $node | Add-Member ScriptMethod FindAll {param($scope,$condition)
            if ($scope -eq [Windows.Automation.TreeScope]::Children -and $condition -eq [Windows.Automation.Condition]::TrueCondition) {return $this.children}
            return @()
        }
        return $node
    }
    $leaf=New-Node 'Observed target'
    $root=New-Node 'Scope' @((New-Node 'Container' @($leaf)))
    $found=@(Find-PotatoElement -Parent $root -Selector @{Name='Observed target'} -FindFirst -TimeoutMs 0)
    Check ($found.Count -eq 1 -and $found[0] -eq $leaf) 'Filtered provider miss did not use the observation traversal.'
    $found=@(Find-PotatoElement -Parent $root -Selector @{Name='Observed target';Recurse=$false} -TimeoutMs 0)
    Check (-not $found.Count) 'Shallow selector incorrectly searched descendants.'
    $dupes=New-Node 'Scope' @($leaf,(New-Node 'Observed target'),(New-Node 'Observed target' @() $false))
    $found=@(Find-PotatoElement -Parent $dupes -Selector (Get-PotatoUniqueSelector @{Name='Observed target'}) -MaxResults 8 -TimeoutMs 0)
    Check ($found.Count -eq 2) 'Fallback lost duplicates or included a disabled match.'
    $errorValue=Reject {Assert-PotatoUniqueMatches $found} 'Fallback bypassed uniqueness.'
    Check ($errorValue.Data['PotatoErrorType'] -eq 'AmbiguousTarget') 'Fallback ambiguity was not structured.'
    $errorValue=Reject {Find-PotatoObservedTreeMatches $dupes @{Name='Observed target'} -NodeLimit 1} 'Partial fallback claimed complete uniqueness.'
    Check ($errorValue.Data['PotatoErrorType'] -eq 'SearchIncomplete' -and $errorValue.Data['NoInputSent']) 'Traversal bound did not fail before input.'
    $root.Current.ProcessId=0
    $found=@(Find-PotatoElement -Parent $root -Selector @{Name='Observed target'} -TimeoutMs 0)
    Check (-not $found.Count) 'Fallback traversed the entire desktop.'
    foreach ($json in @('{}','{"Name":"Broker"}','{"Name":"Broker","ClassName":"Frame","Regex":true}','{"Name":"Broker","ClassName":"Frame","ProcessId":-1}','{"Name":"Broker","ClassName":"Frame","ProcessId":0}')) {
        Reject {Get-PotatoGuardedForegroundWindow $json} 'Invalid foreground guard accepted.' | Out-Null
    }
    $args=@{Scope='ForegroundWindow';FallbackReason='Observed broker';FallbackEvidence='fixture'}
    Check ((Get-PotatoInteractionPolicy $args click).mode -eq 'GuiNavigation') 'Guarded visible click was forbidden.'
    Reject {Get-PotatoInteractionPolicy @{Scope='ForegroundWindow'} observe} 'Broker scope accepted without evidence.' | Out-Null
    Reject {Get-PotatoInteractionPolicy $args type} 'Broker scope granted unscoped typing.' | Out-Null
    Reject {Get-PotatoInteractionPolicy ($args+@{Focus=$true}) click} 'Broker scope stole focus.' | Out-Null
    $script:reads=0
    function Invoke-PotatoSelect {param($ArgsMap)
        $script:reads++
        if ($script:reads -lt 3) {throw (New-PotatoScopeFailure 'Fixture broker is still foreground')}
        @{count=1;elements=@(@{name='Expected dialog'})}
    }
    $ready=Invoke-PotatoWaitElement @{Scope='FocusedWindow';Name='Expected dialog';TimeoutMs=1000}
    Check ($ready.exists -and $script:reads -eq 3) 'Wait did not survive the external-to-owned foreground transition.'
    $script:reads=0
    $absent=Invoke-PotatoWaitElement @{Scope='FocusedWindow';Name='Expected dialog';TimeoutMs=0}
    Check (-not $absent.exists -and $absent.lastScopeError -and $script:reads -eq 1) 'Bounded scoped wait hid its miss or retried forever.'
    function Invoke-PotatoSelect {throw 'Invalid selector'}
    Reject {Invoke-PotatoWaitElement @{Scope='FocusedWindow';TimeoutMs=100}} 'Scoped wait suppressed invalid input.' | Out-Null
    $script:resolved=0
    function Get-PotatoWorkingElement {$root}
    function Get-PotatoExplicitScope {$null}
    function Resolve-PotatoCommandTarget {$script:resolved++;@{ok=$false;error='Fixture selector not found'}}
    foreach ($selector in @(@{ClassName='Missing class'},@{WindowTitle='Other window';ProcessName='Other host'})) {
        $errorValue=Reject {Invoke-PotatoObserve $selector} 'Observe silently ignored a selector and returned the working tree.'
        Check ($errorValue.Data['PotatoErrorType'] -eq 'TargetNotFound') 'Observation scope mismatch did not identify the failed target.'
    }
    Check ($script:resolved -eq 2) 'Observation selectors did not reach resolution.'
    "Discovery checks: $script:checks passed"
}
