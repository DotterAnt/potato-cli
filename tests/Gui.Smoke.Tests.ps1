# Opt-in integration fixture: opens only a temporary test form and closes that process.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-gui-fixture-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$child=$null
try {
    $fixture=Join-Path $root 'form.ps1'
    @'
param($Title,$Output)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System.Windows.Forms;
public class OpaqueInputFixture : Control {
    public string OutputPath;
    public string Received = "";
    public OpaqueInputFixture() { SetStyle(ControlStyles.Selectable, true); TabStop=true; AccessibleRole=AccessibleRole.Pane; }
    protected override void OnMouseDown(MouseEventArgs e) { Focus(); base.OnMouseDown(e); }
    protected override void OnKeyPress(KeyPressEventArgs e) { Received+=e.KeyChar; System.IO.File.WriteAllText(OutputPath,Received); base.OnKeyPress(e); }
}
"@
$form=New-Object Windows.Forms.Form
$form.Text=$Title; $form.Width=440; $form.Height=340
$field=New-Object Windows.Forms.TextBox
$field.AccessibleName='Fixture input'; $field.Top=20; $field.Left=20; $field.Width=350
$button=New-Object Windows.Forms.Button
$button.AccessibleName='Fixture save'; $button.Text='Save'; $button.Top=70; $button.Left=20
$button.Add_Click({[IO.File]::WriteAllText($Output,$field.Text)})
$modalButton=New-Object Windows.Forms.Button
$modalButton.AccessibleName='Fixture modal opener'; $modalButton.Text='Open modal'; $modalButton.Top=70; $modalButton.Left=120; $modalButton.Width=110
$modalButton.Add_Click({
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Fixture modal'; $dialog.Width=260; $dialog.Height=120
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel'; $cancel.AccessibleName='Fixture cancel'; $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    try { [void]$dialog.ShowDialog($form) } finally { $dialog.Dispose() }
})
$field.TabIndex=0; $button.TabIndex=1; $modalButton.TabIndex=2
$source=New-Object Windows.Forms.Label
$source.Text='Drag source'; $source.AccessibleName='Fixture drag source'; $source.SetBounds(20,140,130,50)
$source.BorderStyle=[Windows.Forms.BorderStyle]::FixedSingle
$source.Add_MouseDown({ if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { [void]$source.DoDragDrop('fixture-drag-payload',[Windows.Forms.DragDropEffects]::Copy) } })
$drop=New-Object Windows.Forms.Label
$drop.Text='Drop target'; $drop.AccessibleName='Fixture drop target'; $drop.SetBounds(240,140,130,50)
$drop.BorderStyle=[Windows.Forms.BorderStyle]::FixedSingle; $drop.AllowDrop=$true
$drop.Add_DragEnter({ $_.Effect=[Windows.Forms.DragDropEffects]::Copy })
$drop.Add_DragDrop({ [IO.File]::WriteAllText(($Output+'.drop'),[string]$_.Data.GetData([string])); $drop.Text='Dropped' })
$opaque=New-Object OpaqueInputFixture
$opaque.AccessibleName='Fixture opaque editor'; $opaque.SetBounds(20,210,350,45); $opaque.OutputPath=$Output+'.opaque'
$form.Controls.AddRange(@($field,$button,$modalButton,$source,$drop,$opaque)); $form.Add_Shown({[IO.File]::WriteAllText(($Output+'.ready'),$form.Text); $field.Focus()})
# Consume the hidden process startup window state before displaying the test form.
$form.Show(); $form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content $fixture
    $title='PoTATo fixture '+[guid]::NewGuid().ToString('N')
    $output=Join-Path $root 'saved.txt'
    $child=Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-File',('"'+$fixture+'"'),'-Title',('"'+$title+'"'),'-Output',('"'+$output+'"')) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $root 'child-error.txt') -RedirectStandardOutput (Join-Path $root 'child-output.txt')
    $module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
    # State/logs are isolated under the temp root, not the user's CLI session.
    function Invoke-Fixture($command,$values) {
        $r=Invoke-PotatoCliCommand -Command $command -Arguments $values -CliRoot $root -AsObject
        if (-not $r.ok) { throw ($r | ConvertTo-Json -Depth 10 -Compress) }
        return $r
    }
    try { Invoke-Fixture focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000') | Out-Null }
    catch {
        Get-Content (Join-Path $root 'child-error.txt'); Get-Content (Join-Path $root 'child-output.txt')
        if (Test-Path ($output+'.ready')) { 'Shown title: '+[IO.File]::ReadAllText($output+'.ready') }
        $child.Refresh(); 'Child running: '+(-not $child.HasExited)+'; window handle: '+$child.MainWindowHandle
        $own=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ProcessId -eq $child.Id })
        foreach ($window in $own) { 'Owned UIA name: '+$window.Current.Name; & $module {param($element,$title,$processId) Test-PotatoElementMatch $element @{Name=$title;ProcessId=$processId}} $window $title $child.Id }
        throw
    }
    $owner=Invoke-Fixture wait-element @('-ProcessId',"$($child.Id)",'-ControlType','Window','-Name',$title,'-TimeoutMs','1000')
    if (-not $owner.data.exists) { throw 'Window lookup missed the working window itself.' }
    $selected=Invoke-Fixture select @('-Name','Fixture input','-ControlType','Edit')
    if ($selected.data.count -ne 1) { throw 'Editable fixture discovery failed.' }
    $unsupported=Invoke-PotatoCliCommand -Command click -Arguments @('-Name','Fixture input','-ControlType','Edit','-Method','Invoke') -CliRoot $root -AsObject
    if ($unsupported.ok -or $unsupported.error.message -notmatch 'InvokePattern is unavailable.*-Method Auto') { throw 'Unsupported InvokePattern did not produce an actionable error.' }
    $literal='Literal +^%~(){}[] text'
    try { $typed=Invoke-Fixture type @('-Name','Fixture input','-ControlType','Edit','-Text',$literal,'-Verify') }
    catch { (Invoke-Fixture read @('-Name','Fixture input')).data | ConvertTo-Json -Depth 5; throw }
    if ($typed.data.verified -ne $true) { throw 'Literal input did not verify.' }
    $literal='Replacement ^v{ENTER} '+[char]0x151+[char]0x171+[char]0x4e2d+[char]0x6587+[char]::ConvertFromUtf32(0x1f642)
    $typed=Invoke-Fixture type @('-Name','Fixture input','-ControlType','Edit','-Text',$literal,'-PreDelete','-Verify','-FocusMethod','Mouse')
    if ($typed.data.verified -ne $true -or $typed.data.clearMethod -ne 'Selection' -or $typed.data.focusMethod -ne 'Mouse') { throw 'Unicode/selection replacement with visible mouse focus failed.' }
    $relativeClick=Invoke-Fixture click @('-Name','Fixture input','-RelativeX','0.8','-RelativeY','0.5')
    if ($relativeClick.data.action -ne 'Mouse') { throw 'Relative element click did not use visible mouse input.' }
    $navigation=Invoke-Fixture press-key @('-Key','Tab','-FallbackReason','Move from observed field to next visible control','-FallbackEvidence','fixture-observation')
    if ($navigation.data.before.name -ne 'Fixture input' -or $navigation.data.after.name -ne 'Fixture save') { throw 'Tab navigation did not report its actual focus transition.' }
    Invoke-Fixture press-key @('-Key','ShiftTab','-FallbackReason','Return to observed input','-FallbackEvidence','fixture-observation') | Out-Null
    $focused=Invoke-Fixture type @('-TargetMode','Focused','-Text','!','-FallbackReason','Exercise existing focused input','-FallbackEvidence','fixture-observation')
    if ($focused.data.targetMode -ne 'Focused' -or $focused.data.verified -ne $null -or -not $focused.interactionPolicy.opaqueTyping) { throw 'Focused input audit/verification contract was lost.' }
    # Replace through the normal writable path so the fixture assertion is deterministic.
    Invoke-Fixture type @('-Name','Fixture input','-Text',$literal,'-PreDelete','-Verify') | Out-Null
    $shotPath=Join-Path $root 'new-evidence-folder\capture.png'
    Invoke-Fixture screenshot @('-Name','Fixture input','-OutFile',$shotPath) | Out-Null
    if (-not (Test-Path $shotPath)) { throw 'Screenshot did not create its destination directory.' }
    $saveClick=Invoke-Fixture click @('-Name','Fixture save','-ControlType','Button','-Method','Auto')
    if ($saveClick.data.action -ne 'InvokePattern') { throw 'Auto did not use the supported UIA action.' }
    $wait=Invoke-Fixture wait-file @('-Path',$output,'-TimeoutMs','3000','-MinBytes','1','-StableMs','100')
    if (-not $wait.data.conditionMet -or [IO.File]::ReadAllText($output) -cne $literal) { throw 'Visible save button did not persist literal content.' }
    $drag=Invoke-Fixture drag @('-SourceSelectorJson','{"Name":"Fixture drag source"}','-TargetSelectorJson','{"Name":"Fixture drop target"}','-DurationMs','350')
    if (-not $drag.data.released -or $drag.data.verified -ne $null) { throw 'Drag dispatch/verification semantics are incorrect.' }
    $dropWait=Invoke-Fixture wait-file @('-Path',($output+'.drop'),'-TimeoutMs','3000','-MinBytes','1')
    if (-not $dropWait.data.conditionMet -or [IO.File]::ReadAllText($output+'.drop') -cne 'fixture-drag-payload') { throw 'Selector drag did not deliver the actual GUI drop event/payload.' }
    Invoke-Fixture click @('-Name','Fixture opaque editor','-Method','Mouse') | Out-Null
    $normal=Invoke-PotatoCliCommand type @('-Text','must not send') -CliRoot $root -AsObject
    if ($normal.ok -or $normal.error.message -notmatch 'not a confirmed writable') { throw 'Opaque fixture did not reproduce the writable-pattern limitation.' }
    Invoke-Fixture type @('-TargetMode','Focused','-Text','Opaque','-FallbackReason','Observed custom canvas has keyboard focus but no writable UIA pattern','-FallbackEvidence','fixture-observation') | Out-Null
    $opaqueWait=Invoke-Fixture wait-file @('-Path',($output+'.opaque'),'-TimeoutMs','3000','-MinBytes','6','-StableMs','100')
    if (-not $opaqueWait.data.conditionMet -or [IO.File]::ReadAllText($output+'.opaque') -cne 'Opaque') { throw 'Focused fallback did not send literal text to the real opaque GUI control.' }
    Invoke-Fixture click @('-Name','Fixture modal opener','-ControlType','Button','-Method','Invoke') | Out-Null
    $modal=Invoke-Fixture select @('-Name','Fixture cancel','-ControlType','Button','-ProcessId',"$($child.Id)",'-ModalOnly','-TimeoutMs','2000')
    if ($modal.data.count -ne 1) { throw 'Modal selector did not cross the parent window boundary.' }
    $windows=Invoke-Fixture windows @('-ProcessId',"$($child.Id)")
    if (@($windows.data.windows | Where-Object {$_.isModal}).Count -ne 1) { $windows.data.windows | ConvertTo-Json -Depth 8; throw 'Modal window was not identified.' }
    Invoke-Fixture close-window @('-ProcessId',"$($child.Id)") | Out-Null
    if (-not $child.WaitForExit(3000)) { throw 'Fixture window did not close.' }
    'GUI smoke: literal/focused input, relative click, Tab/ShiftTab focus, screenshot directory, visible save, actual selector drag/drop payload, modal discovery, and scoped close passed.'
}
finally {
    if ($child -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    if ($child) {$child.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-gui-fixture-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
