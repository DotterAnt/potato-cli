param([string]$OutFile)
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-observation-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null
$script:checks=0
function Check($condition,$message) {if (-not $condition) {throw $message}; $script:checks++}
try {
    $fixture=Join-Path $root 'form.ps1'
    @'
param($Title)
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text=$Title; $form.Width=650; $form.Height=650
for ($i=0;$i -lt 100;$i++) {
    $button=New-Object Windows.Forms.Button
    $button.Text="Control $i"; $button.AccessibleName=$button.Text
    $button.SetBounds(10+($i%10)*60,10+[int][Math]::Floor($i/10)*50,58,40)
    $form.Controls.Add($button)
}
$open=New-Object Windows.Forms.Button
$open.Text='Open delayed dialog';$open.AccessibleName=$open.Text;$open.SetBounds(10,520,180,35)
$open.Add_Click({
    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=350
    $timer.Add_Tick({
        $script:activeTimer.Stop()
        $dialog=New-Object Windows.Forms.Form
        $dialog.Text='PoTATo delayed dialog';$dialog.Width=350;$dialog.Height=150
        $field=New-Object Windows.Forms.TextBox
        $field.Name='DialogFilename';$field.AccessibleName='Dialog filename';$field.SetBounds(10,10,300,30)
        $cancel=New-Object Windows.Forms.Button
        $cancel.Text='Cancel';$cancel.AccessibleName='Cancel';$cancel.SetBounds(10,50,100,30)
        $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
        $dialog.Controls.AddRange(@($field,$cancel)); $dialog.Add_Shown({$field.Focus()})
        try {[void]$dialog.ShowDialog($form)} finally {$dialog.Dispose();$script:activeTimer.Dispose()}
    })
    $script:activeTimer=$timer
    $timer.Start()
})
$form.Controls.Add($open)
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $title='PoTATo observation '+[guid]::NewGuid().ToString('N')
    $child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$title+'"'))
    $module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
    function Run($command,$values) {
        $result=Invoke-PotatoCliCommand $command $values -CliRoot $root -AsObject
        if (-not $result.ok) {throw ($result | ConvertTo-Json -Depth 10 -Compress)}
        return $result
    }
    Run focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000') | Out-Null
    $measurement=& $module {
        $e=Get-PotatoWorkingElement -Required
        $nodes=@($e)+@($e.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition))
        $live=@();$cached=@()
        # Warm the provider and both paths before timing.
        ConvertTo-PotatoElementInfo $e | Out-Null
        ConvertTo-PotatoElementInfo $e -Snapshot | Out-Null
        if (-not (Get-PotatoObservationSnapshot $e)) {throw 'UIA snapshot unavailable'}
        $watch=[Diagnostics.Stopwatch]::StartNew()
        foreach ($node in $nodes) {$live+=,(ConvertTo-PotatoElementInfo $node)}
        $liveMs=$watch.Elapsed.TotalMilliseconds; $watch.Restart()
        foreach ($node in $nodes) {$cached+=,(ConvertTo-PotatoElementInfo $node -Snapshot)}
        $cachedMs=$watch.Elapsed.TotalMilliseconds
        for ($i=0;$i -lt $live.Count;$i++) {
            foreach ($key in @('name','automationId','controlType','className','isEnabled','isOffscreen','processId','nativeWindowHandle','isModal')) {
                if ($live[$i][$key] -cne $cached[$i][$key]) {throw "Snapshot changed $key at $i"}
            }
            if ((@($live[$i].supportedPatterns | Sort-Object) -join ',') -cne (@($cached[$i].supportedPatterns | Sort-Object) -join ',')) {throw "Snapshot patterns changed at $i"}
            if (($live[$i].boundingRectangle | ConvertTo-Json -Compress) -cne ($cached[$i].boundingRectangle | ConvertTo-Json -Compress)) {throw "Snapshot geometry changed at $i"}
        }
        @{nodes=$nodes.Count;liveMs=[Math]::Round($liveMs,1);snapshotMs=[Math]::Round($cachedMs,1)}
    }
    Check ($measurement.nodes -ge 100) 'Observation benchmark did not inspect the control tree.'
    $observe=Run observe @('-Depth','2','-MaxElements','140','-Format','Compact')
    Check (@($observe.data.elements | Where-Object {$_.name -eq 'Control 99'}).Count -eq 1) 'Snapshot observation lost the last visible control.'
    Run click @('-Name','Open delayed dialog') | Out-Null
    $ready=Run windows @('-Foreground','-WindowTitle','PoTATo delayed dialog','-TimeoutMs','3000')
    Check ($ready.data.count -eq 1 -and $ready.data.foregroundSelector.Name -eq 'PoTATo delayed dialog') 'Foreground wait ignored the expected title.'
    $guard=$ready.data.foregroundSelector | ConvertTo-Json -Compress
    $scope=@('-Scope','ForegroundWindow','-WindowSelectorJson',$guard,'-FallbackReason','Observed fixture dialog','-FallbackEvidence','Exact foreground window receipt')
    $focused=Run observe ($scope+@('-Depth','0','-MaxElements','1','-Format','Compact'))
    Check ($focused.data.focusedElement.id -eq 'DialogFilename' -and $focused.data.elements.Count -eq 1 -and $focused.data.depthBoundaryReached) 'Focus-only observation lost the actual editor or claimed full discovery.'
    $typed=Run type ($scope+@('-AutomationId','DialogFilename','-Text','literal test','-Verify','-TimeoutMs','1000'))
    Check $typed.data.verified 'Guarded dialog typing failed readback.'
    Run click ($scope+@('-Name','Cancel')) | Out-Null
    $absent=Run windows @('-Foreground','-WindowTitle','PoTATo absent dialog','-TimeoutMs','100')
    Check ($absent.data.count -eq 0 -and -not $absent.data.foregroundSelector) 'Foreground filtering returned the previous window.'
    Run click @('-Name','Open delayed dialog') | Out-Null
    $typed=Run type ($scope+@('-AutomationId','DialogFilename','-Text','transition test','-Verify','-TimeoutMs','3000'))
    Check $typed.data.verified 'Exact guarded typing did not wait for a delayed dialog.'
    $window=Run wait-element @('-Name','PoTATo delayed dialog','-ControlType','Window','-TimeoutMs','1000')
    Check ($window.data.exists -and $window.data.count -eq 1) 'Window wait missed the native owned dialog.'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $blocked=Invoke-PotatoCliCommand wait-element @('-Name','Fixture control absent behind modal','-TimeoutMs','10000') -CliRoot $root -AsObject
    Check (-not $blocked.ok -and $blocked.error.type -eq 'WaitBlockedByDialog' -and $blocked.error.blockingDialog.foregroundSelector.Name -eq 'PoTATo delayed dialog' -and $clock.ElapsedMilliseconds -lt 5000) "An actual owned modal did not stop the blocked readiness wait with a usable guard: $($blocked | ConvertTo-Json -Depth 8 -Compress)"
    Run click ($scope+@('-Name','Cancel')) | Out-Null
    $result=@{checks=$script:checks;measurement=$measurement;boundedTreeObserveMs=$observe.durationMs;focusOnlyObserveMs=$focused.durationMs;
        note='Full bounded tree and focus-only observe inspect different states/data; focus-only is sufficient only when the current target is the needed observation.'}
    if ($OutFile) {$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutFile -Encoding UTF8}
    $result | ConvertTo-Json -Depth 5 -Compress
} finally {
    if ($child -and -not $child.HasExited) {Stop-Process -Id $child.Id -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-observation-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
