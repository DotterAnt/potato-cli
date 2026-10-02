param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-visual-wait-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null;$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
try {
    $fixture=Join-Path $root 'fixture.ps1'
    Add-Type -AssemblyName System.Drawing
    $reference=Join-Path $root 'reference.png'
    $pattern=[Drawing.Bitmap]::new(150,200)
    try {
        for ($y=0;$y -lt 200;$y++) {for ($x=0;$x -lt 150;$x++) {$pattern.SetPixel($x,$y,[Drawing.Color]::FromArgb($x,$y,[int](($x+$y)%150)))}}
        $pattern.Save($reference,[Drawing.Imaging.ImageFormat]::Png)
        $pattern.Save((Join-Path $root 'reference.jpg'),[Drawing.Imaging.ImageFormat]::Jpeg)
    } finally {$pattern.Dispose()}
    @'
param($Title,$Reference)
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
$expected=New-Object Windows.Forms.Button
$expected.Text='Expected content';$expected.SetBounds(230,100,150,40)
$expected.Add_Click({
    $panel.BackColor=[Drawing.Color]::Blue;$script:phase=0
    $script:contentTimer=New-Object Windows.Forms.Timer
    $script:contentTimer.Interval=200
    $script:contentTimer.Add_Tick({
        $script:phase++
        if ($script:phase -eq 1) {$panel.BackColor=[Drawing.Color]::Yellow}
        if ($script:phase -eq 3) {
            $script:contentTimer.Stop();$script:contentTimer.Dispose()
            $panel.BackgroundImage=[Drawing.Bitmap]::new($Reference)
            $panel.BackgroundImage.RotateFlip([Drawing.RotateFlipType]::Rotate90FlipNone)
            $panel.Invalidate()
        }
    })
    $script:contentTimer.Start()
})
$form.Controls.Add($expected)
$menu=New-Object Windows.Forms.MenuStrip
$choices=New-Object Windows.Forms.ToolStripMenuItem('Choices')
[void]$choices.DropDownItems.Add('Fixture leaf')
[void]$menu.Items.Add($choices);$form.Controls.Add($menu)
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $title='PoTATo visual wait '+[guid]::NewGuid().ToString('N')
    $child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$title+'"'),'-Reference',('"'+$reference+'"'))
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
    # A changed/stable loading screen is insufficient: wait for the complete
    # requested orientation, including a JPEG reference, without another click.
    $hash=(Get-FileHash $reference).Hash
    $watch.Restart()
    Run click @('-Name','Expected content') | Out-Null
    $matched=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'matched.png'),'-WaitForImageMatch',$reference,'-ReferenceRotation','90','-MatchRegionJson',$comparison,'-TimeoutMs','3000'))
    $matchElapsed=$watch.ElapsedMilliseconds
    Check ($matched.data.conditionMet -and $matched.data.visualWait.mode -eq 'ExpectedImage' -and $matched.data.visualWait.samples -gt 1 -and $matchElapsed -ge 600 -and $matchElapsed -lt 3000) 'Expected-image wait accepted a blank/intermediate frame or spent its entire deadline.'
    Check ($matched.data.visualWait.meanError -le 8 -and $matched.data.visualWait.maxTileError -le 24) 'Expected-image wait lost measured content errors.'
    $jpegMatch=Run screenshot ($capture+@('-WaitForImageMatch',(Join-Path $root 'reference.jpg'),'-ReferenceRotation','90','-MatchRegionJson',$comparison,'-TimeoutMs','0'))
    Check $jpegMatch.data.conditionMet 'Expected content comparison rejected a legitimate compressed input reference.'
    $wrong=Run screenshot ($capture+@('-OutFile',(Join-Path $root 'wrong.png'),'-WaitForImageMatch',$reference,'-ReferenceRotation','270','-MatchRegionJson',$comparison,'-TimeoutMs','150'))
    Check (-not $wrong.data.conditionMet -and $wrong.data.visualWait.elapsedMs -ge 150 -and (Test-Path $wrong.data.path)) 'Wrong rotation passed or its final diagnostic frame was lost.'
    Check ((Get-FileHash $reference).Hash -eq $hash) 'Expected-image wait changed the source reference.'
    foreach ($args in @(
        @('-WaitForImageMatch',$reference),
        @('-WaitForImageMatch',$reference,'-MatchRegionJson',$comparison,'-ReferenceRotation','45'),
        @('-WaitForImageMatch',$reference,'-MatchRegionJson',$comparison,'-MatchMaxMeanError','135'),
        @('-WaitForImageMatch',$reference,'-MatchRegionJson',$comparison,'-MatchMaxTileError','180'),
        @('-WaitForImageMatch',$reference,'-MatchRegionJson',$comparison,'-WaitForChangeFrom',$before.data.path),
        @('-MatchRegionJson',$comparison),
        @('-ReferenceRotation','90')
    )) {
        $failure=Invoke-PotatoCliCommand screenshot ($capture+$args) -CliRoot $root -AsObject
        Check (-not $failure.ok) 'Invalid expected-content wait options survived validation.'
    }
    $foreground=Run windows @('-Foreground','-WindowTitle',$title,'-TimeoutMs','1000')
    $guard=$foreground.data.foregroundSelector | ConvertTo-Json -Compress
    $guardArgs=@('-Scope','ForegroundWindow','-WindowSelectorJson',$guard,'-FallbackReason','Inspect fixture dialog','-FallbackEvidence','Fresh fixture foreground window')
    $scoped=Run screenshot ($guardArgs+@('-OutFile',(Join-Path $root 'scoped.png')))
    $windowBounds=$foreground.data.windows[0].boundingRectangle
    Check ($scoped.data.region.width -eq $windowBounds.width -and $scoped.data.region.height -eq $windowBounds.height -and $scoped.data.region.x -eq $windowBounds.x -and $scoped.data.region.y -eq $windowBounds.y) 'Guarded foreground capture was rejected, ignored its window, or lost its physical origin.'
    $badGuard=$guard | ConvertFrom-Json;$badGuard.Name='Wrong observed window'
    $badPath=Join-Path $root 'bad-guard.png'
    $bad=Invoke-PotatoCliCommand screenshot @('-Scope','ForegroundWindow','-WindowSelectorJson',($badGuard | ConvertTo-Json -Compress),'-FallbackReason','Inspect fixture','-FallbackEvidence','Fixture','-TimeoutMs','0','-X',"$($area.x)",'-Y',"$($area.y)",'-Width','20','-Height','20','-OutFile',$badPath) -CliRoot $root -AsObject
    Check (-not $bad.ok -and $bad.error.type -eq 'ScopeNotReady' -and -not (Test-Path $badPath)) 'Explicit screenshot rectangle bypassed a mismatching foreground guard.'
    $opened=Run click @('-Name','Choices')
    $expectedAction=if ($opened.data.element.supportedPatterns -contains 'ExpandCollapse') {'ExpandCollapsePattern'} else {'InvokePattern'}
    Check ($opened.data.action -eq $expectedAction) 'Live submenu used the wrong available action.'
    Check ((Run select @('-Name','Fixture leaf','-TimeoutMs','1000')).data.count -eq 1) 'Live submenu expansion did not expose its child.'
    "Visual wait checks: $script:checks passed; changed capture=${elapsed}ms; expected content=${matchElapsed}ms, samples=$($matched.data.visualWait.samples)."
} finally {
    if ($child -and -not $child.HasExited) {$child.CloseMainWindow() | Out-Null;if (-not $child.WaitForExit(3000)) {$child.Kill();[void]$child.WaitForExit(3000)}}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-visual-wait-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
