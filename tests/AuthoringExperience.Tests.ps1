param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    param($cliRoot)
    $script:checks=0
    function Check($value,$message) { if (-not $value) { throw $message }; $script:checks++ }
    function Reject([scriptblock]$body,$message) { $caught=$false; try {& $body | Out-Null} catch {$caught=$true}; Check $caught $message }
    $help=Invoke-PotatoCliCommand help @('-Topics','start,click,type,observe') -CliRoot $cliRoot -AsObject
    Check ($help.ok -and $help.data.commands.Count -eq 4 -and $help.data.commands.click.notes -match 'default Auto') 'Combined help lost a topic or guidance.'
    Check (-not (Invoke-PotatoCliCommand help @('-Topics','click,missing') -CliRoot $cliRoot -AsObject).ok) 'Combined help silently ignored an invalid topic.'
    $info=@{name='Question? [draft]';automationId='id*';controlType='Button';isEnabled=$true;isOffscreen=$false;hasKeyboardFocus=$true;supportedPatterns=@('Invoke');boundingRectangle=@{x=1;y=2;width=50;height=20};propertyErrors=@()}
    $compact=ConvertTo-PotatoCompactElement $info
    Check ($compact.selector.Regex -and $info.name -match $compact.selector.Name -and 'QuestionA [draft]' -notmatch $compact.selector.Name -and $info.automationId -match $compact.selector.AutomationId) 'Compact selector broadened literal wildcard characters.'
    Check (-not $compact.selector.Contains('ControlType') -and $compact.bounds.width -eq 50 -and $compact.focused) 'Candidate selector froze role or lost coordinates/focus.'
    $tree=@{element=@{name='';supportedPatterns=@()};children=@(@{element=$info;children=@()})}
    $flat=@(ConvertTo-PotatoCompactTree $tree)
    Check ($flat.Count -eq 1 -and $flat[0].depth -eq 1) 'Compact tree lost actionable descendants beneath unnamed containers.'
    Reject { Get-PotatoExplicitScope @{Scope='Desktop'} } 'Unknown scope was silently ignored.'
    # A disappearing window cannot replace the last valid identity.
    $script:CurrentState=@{working=@{processId=123;nativeWindowHandle=456}}
    function ConvertTo-PotatoElementInfo { @{processId=0;nativeWindowHandle=0;name='Vanished splash'} }
    Reject { Set-PotatoWorkingWindow ([pscustomobject]@{}) } 'Partial window identity was persisted.'
    Check ($script:CurrentState.working.processId -eq 123) 'Rejected window destroyed the valid prior identity.'
    # Unsupported Invoke must not reach either focus operation.
    Initialize-PotatoAutomationTypes
    $script:focused=$false
    $fake=[pscustomobject]@{}
    $fake | Add-Member ScriptMethod TryGetCurrentPattern {param($id,$value) return $false}
    $fake | Add-Member ScriptMethod SetFocus {$script:focused=$true}
    function Resolve-PotatoCommandTarget { @{ok=$true;element=$fake;selector=@{Name='Fixture'}} }
    function ConvertTo-PotatoElementInfo { @{isEnabled=$true;supportedPatterns=@('SelectionItem')} }
    function Get-PotatoWorkingElement { $script:focused=$true; throw 'Unexpected focus access' }
    Reject { Invoke-PotatoClick @{Method='Invoke'} } 'Unsupported Invoke was accepted.'
    Check (-not $script:focused) 'Unsupported Invoke changed focus before failing.'
    $script:parentReads=0
    $stale=[pscustomobject]@{}
    $stale | Add-Member ScriptMethod FindFirst { param($scope,$condition) throw 'Splash disappeared' }
    $live=[pscustomobject]@{}
    $live | Add-Member ScriptMethod FindFirst { param($scope,$condition) [pscustomobject]@{Name='Ready control'} }
    function Get-PotatoWorkingElement { $script:parentReads++; return $live }
    function Test-PotatoElementMatch { return $true }
    function Write-PotatoLog { }
    $found=@(Find-PotatoElement -Selector @{Name='Ready control'} -Parent $stale -TimeoutMs 1000 -FindFirst -RefreshWorkingParent)
    Check ($found.Count -eq 1 -and $found[0].Name -eq 'Ready control' -and $script:parentReads -eq 1) 'Wait retried a dead splash instead of rediscovering the working window.'
    # Startup retries a stale identity; ownership is read from the validated
    # snapshot, not from another potentially stale Element.Current access.
    function Get-Process { return @() }
    function Start-Process { [pscustomobject]@{Id=123} }
    function Save-PotatoState { }
    function Wait-PotatoProcessWindow { [pscustomobject]@{Current=@{ProcessId=0}} }
    $script:identities=0
    function Set-PotatoWorkingWindow { $script:identities++; if ($script:identities -eq 1) {throw 'Transient stale provider'}; return @{processId=124;nativeWindowHandle=999} }
    function Show-PotatoWindow { return $true }
    function Write-PotatoLog { }
    $result=Invoke-PotatoStart @{ProcessName='fixture.exe';WaitForWindowMs=1000}
    Check ($result.windowFound -and $result.ownedProcessId -eq 124 -and $script:identities -eq 2) 'Launch did not retry stale identity or lost the validated owner.'
    function Set-PotatoWorkingWindow { throw 'Always stale' }
    $result=Invoke-PotatoStart @{ProcessName='fixture.exe';WaitForWindowMs=0}
    Check (-not $result.windowFound -and $result.ownedProcessId -eq 123 -and -not $script:CurrentState.working) 'Exhausted startup pretended to have a usable window or lost cleanup ownership.'
    "Authoring experience checks: $script:checks passed"
} $cliRoot
