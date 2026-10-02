# Real Windows file dialog with shell autocomplete; only an owned fixture is used.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-common-dialog-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null
try {
    $fixture=Join-Path $root 'form.ps1'
    @'
param($Title,$Root)
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text=$Title;$form.Width=360;$form.Height=160
$button=New-Object Windows.Forms.Button
$button.Text='Open fixture save';$button.AccessibleName=$button.Text;$button.SetBounds(20,20,240,30)
$button.Add_Click({
    $dialog=New-Object Windows.Forms.SaveFileDialog
    $dialog.Title='Fixture output path';$dialog.InitialDirectory=$Root
    $dialog.Filter='Fixture PDF|*.pdf';$dialog.FileName=''
    try {[void]$dialog.ShowDialog($form)} finally {$dialog.Dispose()}
})
$form.Controls.Add($button)
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $title='PoTATo common dialog '+[guid]::NewGuid().ToString('N')
    $child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$title+'"'),'-Root',('"'+$root+'"')) -RedirectStandardError (Join-Path $root 'fixture-error.txt')
    Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force
    function Invoke-Fixture($command,$values) {
        $r=Invoke-PotatoCliCommand $command $values -CliRoot $root -AsObject
        if (-not $r.ok) {Get-Content -LiteralPath (Join-Path $root 'fixture-error.txt') -ErrorAction SilentlyContinue | Write-Host;throw ($r | ConvertTo-Json -Depth 14 -Compress)}
        $r
    }
    Invoke-Fixture focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000') | Out-Null
    Invoke-Fixture click @('-Name','Open fixture save','-ControlType','Button') | Out-Null
    $dialog=Invoke-Fixture windows @('-ProcessId',"$($child.Id)",'-WindowTitle','Fixture output path','-TimeoutMs','5000')
    if ($dialog.data.count -ne 1) {throw 'Owned fixture dialog did not open.'}
    $window=$dialog.data.windows[0]
    $guard=@{Name=$window.name;ClassName=$window.className;ProcessId=$window.processId;NativeWindowHandle=$window.nativeWindowHandle} | ConvertTo-Json -Compress
    $scope=@('-Scope','ForegroundWindow','-WindowSelectorJson',$guard,'-FallbackReason','Exercise the owned Windows file-dialog fixture','-FallbackEvidence','Fixture output path window')
    $folder=Join-Path $root 'long output parent with spaces\evidence\20261003_000000_0000\Output'
    [void][IO.Directory]::CreateDirectory($folder)
    # Existing sibling prefixes exercise the Shell completion worker during input.
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'long output parent with spaces\another'))
    $times=@()
    foreach ($index in 1..10) {
        $path=Join-Path $folder ('Unicode '+[char]0x151+' output '+$index+'.pdf')
        $typed=Invoke-Fixture type ($scope+@('-AutomationId','1001','-ControlType','Edit','-Text',$path,'-PathKind','SaveFile','-PreDelete','-Verify'))
        $read=Invoke-Fixture read ($scope+@('-AutomationId','1001','-ControlType','Edit'))
        if (-not $typed.data.consumptionAcknowledged -or -not $typed.data.verified -or $read.data.text -cne $path) {throw 'File-dialog input failed actual exact readback.'}
        $times+=,$typed.durationMs
    }
    Invoke-Fixture click ($scope+@('-AutomationId','2','-ControlType','Button','-Method','Mouse')) | Out-Null
    "Common dialog: 10 exact Unicode paths passed; ms: $($times -join ', ')"
} finally {
    if ($child -and -not $child.HasExited) {$child.Kill();$child.WaitForExit()}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-common-dialog-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
