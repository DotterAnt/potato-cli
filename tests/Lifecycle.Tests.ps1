param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
& $module {
    $script:checks=0
    function Check($value,$message) {if (-not $value) {throw $message};$script:checks++}
    function Reject($body,$message) {$caught=$false;try {& $body | Out-Null} catch {$caught=$true};Check $caught $message}
    foreach ($entry in @(
        @('cmd.exe','/c start "" "protocol:document" & timeout /t 60'),
        @('rundll32.exe','url.dll,FileProtocolHandler protocol:document'),
        @('powershell.exe','-Command Start-Process "protocol:document"'),
        @('mshta.exe','javascript:Shell.Run("document");'))) {
        Reject {Get-PotatoInteractionPolicy @{ProcessName=$entry[0];Arguments=$entry[1]} start} 'A GUI launch wrapper was allowed.'
    }
    Check ((Get-PotatoInteractionPolicy @{ProcessName='filemanager.exe';Arguments='--new-window'} start).mode -eq 'GuiNavigation') 'Ordinary executable launch was rejected.'
    $guard=@{Scope='ForegroundWindow';FallbackReason='Observed dialog';FallbackEvidence='Fixture receipt';TargetMode='Focused';ExpectedFocusJson='{"ClassName":"Edit"}'}
    Check ((Get-PotatoInteractionPolicy $guard type).opaqueTyping) 'Guarded focused input was rejected.'
    Reject {Get-PotatoInteractionPolicy @{Scope='ForegroundWindow';FallbackReason='x';FallbackEvidence='y';TargetMode='Focused'} type} 'External opaque input lacked a focus guard.'
    Reject {Get-PotatoInteractionPolicy ($guard+@{InteractionPolicy='VisibleControls'}) 'press-key'} 'Strict navigation policy was weakened.'
    $script:CurrentState=@{working=@{processId=91;nativeWindowHandle=12};windowCheckpoint=@{id='fixture';handles=@(12)}}
    Reject {Get-PotatoWindowCheckpoint 'wrong'} 'Wrong checkpoint accepted.'
    Check ((Get-PotatoWindowCheckpoint 'fixture').handles[0] -eq 12) 'Checkpoint lost its baseline.'
    function Save-PotatoState {}
    $script:CurrentState.windowCheckpoints=@(@{id='older';handles=@(9)},$script:CurrentState.windowCheckpoint)
    Check ((Get-PotatoWindowCheckpoint 'older').handles[0] -eq 9) 'A later diagnostic checkpoint invalidated the pre-action receipt.'
    $saved=New-PotatoWindowCheckpoint
    $serializedState=$script:CurrentState | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $script:CurrentState=$serializedState
    Check ((Get-PotatoWindowCheckpoint 'older').handles[0] -eq 9) 'A separate serialized client lost checkpoint history.'
    for ($i=0;$i -lt 17;$i++) {New-PotatoWindowCheckpoint | Out-Null}
    Check ($script:CurrentState.windowCheckpoints.Count -eq 16) 'Checkpoint history grew without a bound.'
    Reject {Get-PotatoWindowCheckpoint 'older'} 'An evicted checkpoint was silently accepted.'
    $script:CurrentState=@{working=@{processId=91;nativeWindowHandle=12};windowCheckpoint=@{id='fixture';handles=@(12)}}
    function New-PotatoWindowCheckpoint {return $script:CurrentState.windowCheckpoint}
    function Get-Process {param($Name,$Id) [pscustomobject]@{Id=91}}
    function Start-Process {[pscustomobject]@{Id=92;HasExited=$true}}
    function Save-PotatoState {}
    function Show-PotatoWindow {$true}
    $script:window=[pscustomobject]@{Current=@{ProcessId=91;NativeWindowHandle=13;IsOffscreen=$false}}
    function Get-PotatoTopLevelWindows {return $script:window}
    function Set-PotatoWorkingWindow { $script:CurrentState.working=@{processId=91;nativeWindowHandle=13;className='Fixture'};return $script:CurrentState.working }
    function New-PotatoOwnedWindow {param($Working) return @{processId=$Working.processId;nativeWindowHandle=$Working.nativeWindowHandle;processStartTime='100';className='Fixture'}}
    $result=Invoke-PotatoStart @{ProcessName='host.exe';RequireNewWindow=$true;TimeoutMs=0}
    Check ($result.windowFound -and -not $result.ownedProcessId -and $result.ownedWindow.processId -eq 91 -and $result.working.windowScoped) 'Fast-exit handoff did not claim only the new shared-host window.'
    $serialized=$result | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    Check ($null -eq $serialized.ownedProcessId -and $null -eq $serialized.ownedProcessStartTime) 'Empty ownership serialized as an object and became a phantom process receipt.'
    $script:attempts=0
    function Write-PotatoLog {}
    function Set-PotatoWorkingWindow {
        $script:attempts++
        if ($script:attempts -eq 1) {throw 'Splash disappeared'}
        $script:CurrentState.working=@{processId=91;nativeWindowHandle=13;className='Fixture'};return $script:CurrentState.working
    }
    $result=Invoke-PotatoStart @{ProcessName='host.exe';RequireNewWindow=$true;TimeoutMs=1000}
    Check ($result.windowFound -and $script:attempts -eq 2) 'New-window launch did not recover from a disappearing splash.'
    $script:window.Current.NativeWindowHandle=12
    Reject {Invoke-PotatoStart @{ProcessName='host.exe';RequireNewWindow=$true;TimeoutMs=0}} 'Launch reused a preexisting window.'
    Check ($script:CurrentState.working.nativeWindowHandle -eq 13) 'Failed launch erased recovery context.'
    Reject {Invoke-PotatoStart @{ProcessName='host.exe';RequireNewWindow=$true;RequireNewProcess=$true}} 'Conflicting ownership modes accepted.'
    Reject {Invoke-PotatoStart @{ProcessName='host.exe';RequireNewWindow=$true;KillExisting=$true}} 'Window launch allowed killing a shared host.'
    "Lifecycle checks: $script:checks passed"
}
