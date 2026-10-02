# Opt-in integration: synthetic shared GUI host, never Explorer or user documents.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-lifecycle-fixture-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$child=$null
try {
    $fixture=Join-Path $root 'host.ps1'
    @'
param($Root)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FixtureEdit {
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(int ex,string cls,string text,int style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr window);
}
"@
$form=New-Object Windows.Forms.Form
$form.Text='Preexisting fixture '+(Split-Path $Root -Leaf);$form.Width=450;$form.Height=220
$form.Add_Shown({[IO.File]::WriteAllText((Join-Path $Root 'ready'),'ready')})
$timer=New-Object Windows.Forms.Timer
$timer.Interval=50
$timer.Add_Tick({
    if (Test-Path (Join-Path $Root 'duplicate')) {
        Remove-Item -LiteralPath (Join-Path $Root 'duplicate')
        $script:duplicate=New-Object Windows.Forms.Form
        $script:duplicate.Text=$script:shared.Text;$script:duplicate.Width=450;$script:duplicate.Height=220
        $script:duplicate.Show()
        [IO.File]::WriteAllText((Join-Path $Root 'duplicate-ready'),'ready')
    }
    if (Test-Path (Join-Path $Root 'open')) {
        Remove-Item -LiteralPath (Join-Path $Root 'open')
        $script:shared=New-Object Windows.Forms.Form
        $script:shared.Text='New fixture '+(Split-Path $Root -Leaf);$script:shared.Width=500;$script:shared.Height=220
        $script:shared.Add_Shown({
            $script:edit=[FixtureEdit]::CreateWindowExW(0,'Edit','selected default',0x50010080,20,30,430,30,$script:shared.Handle,[IntPtr]1001,[IntPtr]::Zero,[IntPtr]::Zero)
            [void][FixtureEdit]::SetFocus($script:edit)
        })
        $script:shared.Show()
    }
})
$timer.Start()
$form.Show(); $form.Hide()
[Windows.Forms.Application]::Run($form)
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $launcher=Join-Path $root 'handoff.ps1'
    'param($Root); [IO.File]::WriteAllText((Join-Path $Root ''open''),''fixture handoff'')' | Set-Content -LiteralPath $launcher
    $child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-File',('"'+$fixture+'"'),'-Root',('"'+$root+'"')) -RedirectStandardError (Join-Path $root 'host-errors.txt')
    $module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
    function Invoke-Fixture($Command,$Arguments) {
        $r=Invoke-PotatoCliCommand $Command $Arguments -CliRoot $root -AsObject
        if (-not $r.ok) {
            Get-Content -LiteralPath (Join-Path $root 'host-errors.txt') -ErrorAction SilentlyContinue | Write-Host
            Write-Host ($Arguments -join ' ')
            $child.Refresh(); Write-Host ('Host title: '+$child.MainWindowTitle)
            Get-ChildItem -LiteralPath $root | Select-Object Name,Length | Out-Host
            throw ($r | ConvertTo-Json -Depth 8 -Compress)
        }
        return $r
    }
    $ready=Invoke-Fixture wait-file @('-Path',(Join-Path $root 'ready'),'-MinBytes','1','-TimeoutMs','10000')
    if (-not $ready.data.conditionMet) {throw 'Fixture host failed to start.'}
    $originalTitle='Preexisting fixture '+(Split-Path $root -Leaf)
    $newTitle='New fixture '+(Split-Path $root -Leaf)
    Invoke-Fixture focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$originalTitle) | Out-Null
    $launch=Invoke-Fixture start @('-ProcessName','powershell.exe',('-Arguments=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$launcher+'" -Root "'+$root+'"'),'-RequireNewWindow','-WaitForWindowMs','10000')
    if (-not $launch.data.windowFound -or $launch.data.ownedProcessId -or $launch.data.ownedWindow.processId -ne $child.Id) {throw 'Launch claimed the short-lived launcher or adopted the shared host.'}
    $ticket=$launch.data.ownedWindow | ConvertTo-Json -Compress
    $oldClaim=Invoke-PotatoCliCommand focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$originalTitle,'-SinceCheckpoint',$launch.data.checkpointId,'-TimeoutMs','0') -CliRoot $root -AsObject
    if ($oldClaim.ok) {throw 'Checkpoint claimed a preexisting window.'}
    if ($oldClaim.outcome -ne 'not-dispatched' -or $oldClaim.error.type -ne 'TargetNotFound' -or $oldClaim.error.message -notmatch 'already present') {throw 'Preexisting-window rejection obscured the checkpoint cause or reported uncertain input.'}
    $ambiguous=Invoke-PotatoCliCommand focus @('-ProcessId',"$($child.Id)",'-TimeoutMs','0') -CliRoot $root -AsObject
    if ($ambiguous.ok -or $ambiguous.outcome -ne 'not-dispatched' -or $ambiguous.error.type -ne 'AmbiguousTarget' -or $ambiguous.error.candidates.Count -lt 2) {throw 'Ambiguous focus dispatched input or omitted observed candidates.'}
    $foreground=Invoke-Fixture windows @('-Foreground')
    $guard=$foreground.data.foregroundSelector | ConvertTo-Json -Compress
    if (-not $foreground.data.foregroundSelector.NativeWindowHandle) {throw 'Foreground receipt omitted its exact observed handle.'}
    [IO.File]::WriteAllText((Join-Path $root 'duplicate'),'create same-title sibling')
    $ready=Invoke-Fixture wait-file @('-Path',(Join-Path $root 'duplicate-ready'),'-MinBytes','1','-TimeoutMs','3000')
    if (-not $ready.data.conditionMet) {throw 'Same-title sibling fixture did not start.'}
    $sameTitle=Invoke-PotatoCliCommand focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$newTitle,'-TimeoutMs','0') -CliRoot $root -AsObject
    if ($sameTitle.ok -or $sameTitle.error.type -ne 'AmbiguousTarget') {throw 'Same-title sibling windows were not detected as ambiguous.'}
    $selected=Invoke-Fixture focus @('-WindowSelectorJson',$guard,'-Maximize')
    if ($selected.data.working.nativeWindowHandle -ne $foreground.data.foregroundSelector.NativeWindowHandle -or $selected.data.ownedWindow) {throw 'Guarded focus ignored its handle or granted cleanup ownership.'}
    $unowned=Invoke-PotatoCliCommand focus @('-WindowIdentityJson',$guard) -CliRoot $root -AsObject
    if ($unowned.ok) {throw 'A selection guard became an ownership receipt.'}
    $identity=Invoke-Fixture windows @('-WindowIdentityJson',$ticket)
    if ($identity.data.count -ne 1 -or $identity.data.windows[0].identitySource -ne 'Win32WindowLifetime') {throw 'Owned lifetime observation still relied on the UIA provider.'}
    # Diagnostic snapshot includes the new window, but its earlier baseline
    # must remain usable through serialized state in the next CLI call.
    Invoke-Fixture windows @('-Checkpoint') | Out-Null
    $claimed=Invoke-Fixture focus @('-WindowSelectorJson',$guard,'-SinceCheckpoint',$launch.data.checkpointId)
    if ($claimed.data.ownedWindow.nativeWindowHandle -ne $launch.data.ownedWindow.nativeWindowHandle -or $claimed.data.ownedProcessId) {throw 'GUI handoff did not register only its new window.'}
    $stale=$ticket | ConvertFrom-Json
    $stale.processStartTime=([long]$stale.processStartTime+1).ToString()
    $staleClosed=Invoke-Fixture close-window @('-WindowIdentityJson',($stale | ConvertTo-Json -Compress))
    if ($staleClosed.data.closeRequested -ne 0) {throw 'Stale process identity closed a window.'}
    $stale=$ticket | ConvertFrom-Json
    $stale.windowToken=[guid]::NewGuid().ToString('N')
    $staleClosed=Invoke-Fixture close-window @('-WindowIdentityJson',($stale | ConvertTo-Json -Compress))
    if ($staleClosed.data.closeRequested -ne 0) {throw 'Wrong window-lifetime token closed a window.'}
    $args=@('-TargetMode','Focused','-ExpectedFocusJson','{"ClassName":"Edit"}','-FallbackReason','Synthetic native field','-FallbackEvidence','Visible fixture field')
    # Exact native Edit readback still works with a deliberately deficient UIA provider.
    $info=Invoke-Fixture observe @('-Format','Compact','-Depth','3')
    Invoke-Fixture click @('-ClassName','Edit','-Mode','Mouse','-TimeoutMs','1000') | Out-Null
    $path=Join-Path $root ('long literal [path] +^%{} '+[char]0x151+' image.png')
    $typed=Invoke-Fixture type ($args+@('-Text',$path,'-PathKind','SaveFile','-PreDelete'))
    if (-not $typed.data.verified -or -not $typed.data.verificationPerformed) {throw 'Path typing did not require and pass exact field readback.'}
    if (-not $typed.data.consumptionAcknowledged) {throw 'Standard Edit path replacement did not acknowledge actual consumption.'}
    if ($typed.data.inputDelayMs -ne 0) {throw 'Acknowledged standard Edit path retained an unnecessary blind default delay.'}
    Write-Output ('Acknowledged native path: '+$path.Length+' characters, '+$typed.durationMs+' ms, verified.')
    $repeatTimes=@()
    for ($repeat=0;$repeat -lt 3;$repeat++) {
        $again=Invoke-Fixture type ($args+@('-Text',$path,'-PathKind','SaveFile','-PreDelete'))
        if (-not $again.data.verified -or -not $again.data.consumptionAcknowledged -or $again.data.inputDelayMs -ne 0) {throw 'Repeated acknowledged replacement lost content or added a blind delay.'}
        $repeatTimes+=,$again.durationMs
    }
    Write-Output ('Repeated verified path replacement ms: '+($repeatTimes -join ', '))
    & $module {
        param($handle,$processId,$expected)
        $element=[pscustomobject]@{Current=@{NativeWindowHandle=[long]$handle;ProcessId=$processId}}
        $element | Add-Member ScriptMethod TryGetCurrentPattern {param($pattern,$result) return $false}
        if ((Get-PotatoEditableText $element) -cne $expected) {throw 'Native fallback used a caption or lost path text.'}
        $read=Get-PotatoElementText $element -WithSource
        if ($read.source -ne 'Win32Edit' -or $read.text -cne $expected) {throw 'Read hid native field text behind a Name fallback.'}
    } $typed.data.target.nativeWindowHandle $child.Id $path
    # A sibling in the same PID must not be a keyboard target for a selected window.
    Invoke-Fixture focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$originalTitle) | Out-Null
    & $module {param($handle) [void](Show-PotatoWindow -Handle $handle)} $launch.data.ownedWindow.nativeWindowHandle
    $foreign=Invoke-PotatoCliCommand type ($args+@('-Text','must not send','-FocusTimeoutMs','0')) -CliRoot $root -AsObject
    if ($foreign.ok) {throw 'Window-scoped input typed into a sibling in the same process.'}
    Invoke-Fixture focus @('-WindowIdentityJson',$ticket) | Out-Null
    # Framework cleanup uses the ticket; it must not close the original form/PID.
    . (Join-Path (Split-Path $cliRoot) 'automated-gui-testing-agent-framework\Framework\GeneratedScriptRuntime.ps1')
    # A real exploration manifest must reject this live window and later allow
    # completion while the preexisting shared host is still running.
    Copy-Item -LiteralPath (Join-Path $cliRoot 'PoTAToCli') -Destination (Join-Path $root 'PoTAToCli') -Recurse
    $isolatedEntry=Join-Path $root 'potato.ps1'
    '# Synthetic entrypoint location for isolated state' | Set-Content -LiteralPath $isolatedEntry
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result', 'Open fixture,,Native field verified' | Set-Content -LiteralPath $csv
    $walkthrough=Join-Path $root 'walkthrough'
    Initialize-AGTAExploration $walkthrough $csv GuiNavigation $isolatedEntry | Out-Null
    Add-AGTAExplorationCommand $walkthrough 1 start @('-ProcessName','fixture.exe') $launch | Out-Null
    $receipt=Add-AGTAExplorationCommand $walkthrough 1 type @() $typed
    Complete-AGTAExplorationStep $walkthrough 1 'Open synthetic window and type a literal path' 'Native field verified' $receipt | Out-Null
    $blocked=$false
    try {Complete-AGTAExploration $walkthrough $csv GuiNavigation | Out-Null} catch {
        $blocked=$_.Exception.Message -like '*owned window is still open*'
        if (-not $blocked) {throw}
    }
    if (-not $blocked) {throw 'Exploration completed while its owned window remained open.'}
    $script:AGTAGeneratedTestContext=[pscustomobject]@{RunRoot=$root;Timing=@{cleanupMs=0}}
    $script:AGTAOpenedWindows=@($launch.data.ownedWindow)
    $script:AGTAOpenedProcessNames=@();$script:AGTACreatedExternalPaths=@()
    function Invoke-PotatoJson {param($Command,$Arguments) Invoke-Fixture $Command $Arguments}
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 2500)
    if (@($cleanup | Where-Object {-not $_.ok}).Count) {throw ($cleanup | ConvertTo-Json -Depth 6)}
    $original=Invoke-Fixture windows @('-ProcessId',"$($child.Id)",'-WindowTitle',$originalTitle)
    if ($original.data.count -ne 1 -or $child.HasExited) {throw 'Cleanup closed the shared host or the preexisting window.'}
    $remaining=Invoke-Fixture windows @('-WindowIdentityJson',$ticket)
    if ($remaining.data.count) {throw 'Owned window survived cleanup.'}
    $complete=Complete-AGTAExploration $walkthrough $csv GuiNavigation
    if (-not $complete.ok -or $child.HasExited) {throw 'Exploration required shared-host exit after its window closed.'}
    'GUI lifecycle: immediate-exit handoff, shared-host/GUI-handoff ownership, stale/preexisting-window rejection, native Edit path readback/selection, sibling input rejection, framework window-only cleanup and exploration completion passed.'
} finally {
    if ($child -and -not $child.HasExited) {$child.Kill();$child.WaitForExit()}
    if ($child) {$child.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-lifecycle-fixture-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
