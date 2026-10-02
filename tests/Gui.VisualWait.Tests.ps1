param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-visual-wait-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null;$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
try {
    $fixture=Join-Path $root 'fixture.ps1'
    @'
param($Title)
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text=$Title;$form.Width=500;$form.Height=300;$form.StartPosition='CenterScreen'
$panel=New-Object Windows.Forms.Panel
$panel.Name='VisualPanel';$panel.AccessibleName='Visual area';$panel.BackColor=[Drawing.Color]::Blue;$panel.SetBounds(10,45,200,150)
$button=New-Object Windows.Forms.Button
$button.Text='Delayed change';$button.SetBounds(230,45,150,40)
$button.Add_Click({
    $script:timer=New-Object Windows.Forms.Timer
    $script:timer.Interval=600
    $script:timer.Add_Tick({$script:timer.Stop();$panel.BackColor=[Drawing.Color]::Red;$script:timer.Dispose()})
    $script:timer.Start()
})
$form.Controls.AddRange(@($panel,$button))
$menu=New-Object Windows.Forms.MenuStrip
$choices=New-Object Windows.Forms.ToolStripMenuItem('Choices')
[void]$choices.DropDownItems.Add('Fixture leaf')
[void]$menu.Items.Add($choices);$form.Controls.Add($menu)
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $title='PoTATo visual wait '+[guid]::NewGuid().ToString('N')
    $child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$title+'"'))
    $module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
    function Run($command,$values) {
        $result=Invoke-PotatoCliCommand $command $values -CliRoot $root -AsObject
        if (-not $result.ok) {throw ($result | ConvertTo-Json -Depth 10 -Compress)}
        return $result
    }
    Run focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000') | Out-Null
    $area=& $module {param($root)
        $target=Resolve-PotatoCommandTarget @{Name='Visual area';TimeoutMs=1000}
        if (-not $target.ok) {throw $target.error}
        ConvertTo-PotatoRectangle $target.element.Current.BoundingRectangle
    } $root
    $capture=@('-X',"$($area.x)",'-Y',"$($area.y)",'-Width',"$($area.width)",'-Height',"$($area.height)")
    $comparison=@{x=0;y=0;width=$area.width;height=$area.height} | ConvertTo-Json -Compress
    $before=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'before.png')))
    $baselineHash=(Get-FileHash $before.data.path).Hash
    # Warm compilation before timing/dispatch and prove an unchanged region
    # cannot satisfy a wait merely because capture was successful.
    $unchanged=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'unchanged.png'),'-WaitForChangeFrom',$before.data.path,'-ChangeRegionJson',$comparison,'-TimeoutMs','0'))
    Check (-not $unchanged.data.conditionMet -and -not $unchanged.data.visualWait.changed -and $unchanged.data.visualWait.samples -eq 1) 'Unchanged pixels satisfied the visual wait.'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Run click @('-Name','Delayed change') | Out-Null
    $after=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'after.png'),'-WaitForChangeFrom',$before.data.path,'-ChangeRegionJson',$comparison,'-TimeoutMs','3000','-StableMs','150'))
    $elapsed=$watch.ElapsedMilliseconds
    Check ($after.data.conditionMet -and $after.data.visualWait.changed -and $after.data.visualWait.samples -gt 1) 'Delayed rendered update was not awaited.'
    Check ($elapsed -ge 600 -and $elapsed -lt 3000) 'Visual wait returned before the delayed change or spent its entire deadline.'
    $bitmap=[Drawing.Bitmap]::new($after.data.path)
    try {Check ($bitmap.GetPixel(50,50).R -eq 255 -and $bitmap.GetPixel(50,50).B -eq 0) 'Returned screenshot was a stale frame captured before readiness.'} finally {$bitmap.Dispose()}
    $timeout=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'timeout.png'),'-WaitForChangeFrom',$after.data.path,'-ChangeRegionJson',$comparison,'-TimeoutMs','200','-StableMs','50'))
    Check (-not $timeout.data.conditionMet -and $timeout.data.visualWait.elapsedMs -ge 200 -and (Test-Path $timeout.data.path)) 'Unmet visual wait did not retain the final frame/timeout result.'
    Check ((Get-FileHash $before.data.path).Hash -eq $baselineHash) 'Visual wait modified the reference image.'
    $jpeg=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'lossy-reference.jpg'),'-EncoderType','JPEG'))
    $lossy=Invoke-PotatoCliCommand screenshot ($capture+@('-WaitForChangeFrom',$jpeg.data.path,'-ChangeRegionJson',$comparison,'-TimeoutMs','0')) -CliRoot $root -AsObject
    Check (-not $lossy.ok -and $lossy.error.message -match 'lossless PNG') 'JPEG compression noise was allowed to masquerade as a visual transition.'
    foreach ($args in @(
        @('-WaitForChangeFrom',$before.data.path),
        @('-WaitForChangeFrom',$before.data.path,'-ChangeRegionJson','{"x":0,"y":0,"width":99999,"height":1}'),
        @('-WaitForChangeFrom',$before.data.path,'-ChangeRegionJson',$comparison,'-TimeoutMs','5','-StableMs','50'),
        @('-WaitForChangeFrom',$before.data.path,'-ChangeRegionJson',$comparison,'-OutFile',$before.data.path),
        @('-StableMs','100')
    )) {
        $failure=Invoke-PotatoCliCommand screenshot ($capture+$args) -CliRoot $root -AsObject
        Check (-not $failure.ok) 'Invalid visual wait geometry/options survived validation.'
    }
    $opened=Run click @('-Name','Choices')
    $expectedAction=if ($opened.data.element.supportedPatterns -contains 'ExpandCollapse') {'ExpandCollapsePattern'} else {'InvokePattern'}
    Check ($opened.data.action -eq $expectedAction) 'Live submenu used the wrong available action.'
    Check ((Run select @('-Name','Fixture leaf','-TimeoutMs','1000')).data.count -eq 1) 'Live submenu expansion did not expose its child.'
    "Visual wait checks: $script:checks passed; delayed update capture=${elapsed}ms, samples=$($after.data.visualWait.samples)."
} finally {
    if ($child -and -not $child.HasExited) {$child.CloseMainWindow() | Out-Null;if (-not $child.WaitForExit(3000)) {$child.Kill();[void]$child.WaitForExit(3000)}}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-visual-wait-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
