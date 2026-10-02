# Isolated WPF ink fixture: verifies real strokes, sampled motion and release.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-ink-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null
try {
    $fixture=Join-Path $root 'ink.ps1';$output=Join-Path $root 'stroke.json'
    @'
param($Title,$Output)
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$window=New-Object Windows.Window
$window.Title=$Title;$window.Width=500;$window.Height=500;$window.Left=100;$window.Top=100
$canvas=New-Object Windows.Controls.InkCanvas
$canvas.Background=[Windows.Media.Brushes]::White
[Windows.Automation.AutomationProperties]::SetName($canvas,'Fixture ink surface')
$canvas.Add_StrokeCollected({
    $points=$_.Stroke.StylusPoints
    @{strokes=$canvas.Strokes.Count;points=$points.Count;firstX=$points[0].X;firstY=$points[0].Y;
      lastX=$points[$points.Count-1].X;lastY=$points[$points.Count-1].Y;
      canvasWidth=$canvas.ActualWidth;canvasHeight=$canvas.ActualHeight} | ConvertTo-Json -Compress | Set-Content -LiteralPath $Output
})
$window.Content=$canvas
[void]$window.ShowDialog()
'@ | Set-Content -LiteralPath $fixture
    $title='PoTATo ink '+[guid]::NewGuid().ToString('N')
    $arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$fixture+'" "'+$title+'" "'+$output+'"'
    $child=Start-Process powershell.exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    function Run($command,$arguments) {
        $result=Invoke-PotatoCliCommand $command $arguments -CliRoot $root -AsObject
        if (-not $result.ok) {throw ($result | ConvertTo-Json -Depth 8 -Compress)}
        return $result
    }
    Run focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000') | Out-Null
    $surface=Run select @('-Name','Fixture ink surface','-FindFirst','-TimeoutMs','3000')
    if ($surface.data.count -ne 1) {throw 'Ink fixture surface was not found.'}
    $bounds=$surface.data.elements[0].boundingRectangle
    $x1=[int]($bounds.x+80);$y1=[int]($bounds.y+90)
    $x2=[int]($bounds.x+320);$y2=[int]($bounds.y+200)
    $drag=Run drag @('-StartX',"$x1",'-StartY',"$y1",'-EndX',"$x2",'-EndY',"$y2",'-DurationMs','400')
    $ready=Run wait-file @('-Path',$output,'-TimeoutMs','3000','-MinBytes','1','-StableMs','100')
    if (-not $ready.data.conditionMet) {throw 'Injected drag did not produce a real ink stroke.'}
    $stroke=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    # WPF reports ink points in device-independent units; the CLI uses physical pixels.
    $scaleX=$stroke.canvasWidth/$bounds.width;$scaleY=$stroke.canvasHeight/$bounds.height
    if ($stroke.strokes -ne 1 -or $stroke.points -lt 10 -or [Math]::Abs($stroke.firstX-80*$scaleX) -gt 3 -or [Math]::Abs($stroke.lastX-320*$scaleX) -gt 3 -or [Math]::Abs($stroke.lastY-200*$scaleY) -gt 3) {throw ('Stroke sampling/physical endpoints were wrong: '+($stroke | ConvertTo-Json -Compress))}
    if (-not $drag.data.released -or $drag.data.verificationPerformed) {throw 'Drag release or verification contract was lost.'}
    & $module {
        if ([PotatoMouseNative]::NormalizeCoordinate(-1920,-1920,3840) -lt 0 -or [PotatoMouseNative]::NormalizeCoordinate(1919,-1920,3840) -gt 65535) {throw 'Negative-monitor normalization failed.'}
        $outside=$false;try {[PotatoMouseNative]::NormalizeCoordinate(1920,-1920,3840) | Out-Null} catch {$outside=$true}
        if (-not $outside) {throw 'Outside-desktop coordinate was accepted.'}
    }
    @{checks=4;strokePoints=$stroke.points;requestedMs=400;dragMs=$drag.durationMs;note='Real WPF ink stroke; physical endpoints, sampled motion and release verified.'} | ConvertTo-Json -Compress
} finally {
    if ($child -and -not $child.HasExited) {Stop-Process -Id $child.Id -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-ink-fixture-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
