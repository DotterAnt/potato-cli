# Opt-in integration fixture: opens only a temporary test form and closes that process.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-gui-fixture-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$child=$null
$broker=$null
try {
    $fixture=Join-Path $root 'form.ps1'
    @'
param($Title,$Output)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,Accessibility -TypeDefinition @"
using System.Windows.Forms;
public class OpaqueInputFixture : Control {
    public string OutputPath;
    public string Received = "";
    public OpaqueInputFixture() { SetStyle(ControlStyles.Selectable, true); TabStop=true; AccessibleRole=AccessibleRole.Pane; }
    protected override void OnMouseDown(MouseEventArgs e) { Focus(); base.OnMouseDown(e); }
    protected override void OnKeyPress(KeyPressEventArgs e) { Received+=e.KeyChar; System.IO.File.WriteAllText(OutputPath,Received); base.OnKeyPress(e); }
}
public class MisreportedFocusFixture : OpaqueInputFixture {
    protected override AccessibleObject CreateAccessibilityInstance() { return new InconsistentFocus(this); }
    private class InconsistentFocus : ControlAccessibleObject {
        public InconsistentFocus(Control owner) : base(owner) {}
        public override AccessibleStates State { get { return base.State & ~AccessibleStates.Focused; } }
    }
}
public class PacedInputFixture : OpaqueInputFixture {
    System.Diagnostics.Stopwatch clock=System.Diagnostics.Stopwatch.StartNew();
    long previous=-100; bool high;
    protected override void OnKeyPress(KeyPressEventArgs e) {
        if (e.KeyChar=='\r') {System.IO.File.WriteAllText(OutputPath,Received);Received="";previous=-100;high=false;return;}
        long now=clock.ElapsedMilliseconds;
        if (now-previous>=18 || (high && char.IsLowSurrogate(e.KeyChar))) {Received+=e.KeyChar;high=char.IsHighSurrogate(e.KeyChar);previous=now;}
    }
}
public class SwitchingInputFixture : OpaqueInputFixture {
    public Control Next;
    protected override void OnKeyPress(KeyPressEventArgs e) {base.OnKeyPress(e);Next.Focus();}
}
"@
$form=New-Object Windows.Forms.Form
$form.Text=$Title; $form.Width=440; $form.Height=575
$field=New-Object Windows.Forms.TextBox
$field.AccessibleName='Fixture input'; $field.Top=20; $field.Left=20; $field.Width=350
$button=New-Object Windows.Forms.Button
$button.AccessibleName='Fixture save'; $button.Text='Save'; $button.Top=70; $button.Left=20
$button.Add_Click({[IO.File]::WriteAllText($Output,$field.Text)})
$modalButton=New-Object Windows.Forms.Button
$modalButton.AccessibleName='Fixture modal opener'; $modalButton.Text='Open modal'; $modalButton.Top=70; $modalButton.Left=120; $modalButton.Width=110
$modalButton.Add_Click({
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Fixture modal'; $dialog.Width=260; $dialog.Height=160
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel'; $cancel.AccessibleName='Fixture cancel'; $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $filename=New-Object Windows.Forms.TextBox
    $filename.AccessibleName='Fixture filename'; $filename.Text='default.ext'; $filename.SetBounds(10,40,210,25)
    $dialog.Controls.Add($filename)
    $dialog.Add_Shown({$filename.Focus(); $filename.SelectAll()})
    try { [void]$dialog.ShowDialog($form) } finally { $dialog.Dispose() }
})
$closePrompt=New-Object Windows.Forms.Button
$closePrompt.AccessibleName='Fixture arm close prompt'; $closePrompt.Text='Arm close prompt'; $closePrompt.SetBounds(245,70,145,30)
$closePrompt.Add_Click({$form.Tag='prompt'})
$form.Controls.Add($closePrompt)
$form.Add_FormClosing({
    if ($form.Tag -eq 'prompt') {
        $_.Cancel=$true
        [void][Windows.Forms.MessageBox]::Show($form,'Fixture still has unsaved content.','Fixture close confirmation',[Windows.Forms.MessageBoxButtons]::OK)
        $form.Tag='ready'
    }
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
$misreported=New-Object MisreportedFocusFixture
$misreported.AccessibleName='Fixture native focus editor'; $misreported.SetBounds(20,325,350,45); $misreported.OutputPath=$Output+'.native'; $misreported.TabIndex=30
$form.Controls.Add($misreported)
$paced=New-Object PacedInputFixture
$paced.AccessibleName='Fixture paced editor'; $paced.SetBounds(20,380,350,40); $paced.OutputPath=$Output+'.paced'
$switcher=New-Object SwitchingInputFixture
$switcher.AccessibleName='Fixture switching editor'; $switcher.SetBounds(20,430,350,40); $switcher.OutputPath=$Output+'.switch'; $switcher.Next=$field
$form.Controls.AddRange(@($paced,$switcher))
$duplicateButton=New-Object Windows.Forms.Button
$duplicateButton.AccessibleName='Shared action'; $duplicateButton.Text='Shared'; $duplicateButton.SetBounds(20,275,120,30)
$duplicateButton.Add_Click({[IO.File]::WriteAllText(($Output+'.unique'),'clicked')})
$duplicateLabel=New-Object Windows.Forms.Label
$duplicateLabel.AccessibleName='Shared action'; $duplicateLabel.Text='Shared'; $duplicateLabel.SetBounds(240,275,120,30)
$form.Controls.AddRange(@($duplicateButton,$duplicateLabel))
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
    $ambiguous=Invoke-PotatoCliCommand click @('-Name','Shared action') -CliRoot $root -AsObject
    if ($ambiguous.ok -or $ambiguous.error.type -ne 'AmbiguousTarget' -or $ambiguous.outcome -ne 'not-dispatched' -or $ambiguous.error.candidates.Count -ne 2 -or (Test-Path ($output+'.unique'))) { throw 'Ambiguous click dispatched input or failed to return candidates.' }
    foreach ($values in @(@('-SelectorJson','{"Name":"Shared action","FindFirst":true}'),@('-PathJson','[{"Name":"Shared action"}]'))) {
        $ambiguous=Invoke-PotatoCliCommand click $values -CliRoot $root -AsObject
        if ($ambiguous.ok -or $ambiguous.error.type -ne 'AmbiguousTarget' -or (Test-Path ($output+'.unique'))) { throw 'JSON selector/path bypassed click uniqueness.' }
    }
    Invoke-Fixture click @('-SelectorJson','{"Name":"Shared action","ControlType":"Button"}') | Out-Null
    if (-not (Test-Path ($output+'.unique'))) { throw 'Observed unique role did not resolve the ambiguous action.' }
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
    if ($saveClick.data.action -ne 'Mouse') { throw 'Auto did not use physical input for the native push button.' }
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
    Invoke-Fixture click @('-Name','Fixture native focus editor','-Method','Mouse') | Out-Null
    $nativeObserved=Invoke-Fixture select @('-Name','Fixture native focus editor')
    if ($nativeObserved.data.elements[0].hasKeyboardFocus) { throw 'Fixture did not reproduce false UIA focus reporting.' }
    $nativeTyped=Invoke-Fixture type @('-TargetMode','Focused','-ExpectedFocusJson','{"Name":"Fixture native focus editor"}','-Text','Native focus','-FallbackReason','Visible opaque fixture has inconsistent UIA focus','-FallbackEvidence','fixture-native-focus-observation')
    if ($nativeTyped.data.inputFocus.source -ne 'Win32' -or -not $nativeTyped.data.inputFocus.native.ready) { throw 'Opaque typing did not corroborate focus through Windows.' }
    Invoke-Fixture press-key @('-Key','Enter','-FallbackReason','Observed opaque multiline fixture accepts Enter','-FallbackEvidence','fixture-native-focus-observation') | Out-Null
    Invoke-Fixture wait-file @('-Path',($output+'.native'),'-MinBytes','13','-StableMs','100','-TimeoutMs','3000') | Out-Null
    if ([IO.File]::ReadAllText($output+'.native') -cne "Native focus`r") { throw 'Native focus fallback did not deliver literal text and navigation to the real control.' }
    Invoke-Fixture click @('-Name','Fixture paced editor','-Method','Mouse') | Out-Null
    $pacedText=('abcdefghij'*8)+[char]::ConvertFromUtf32(0x1f642)
    $fast=Invoke-Fixture type @('-TargetMode','Focused','-Text',$pacedText,'-InputDelayMs','5','-FallbackReason','Reproduce rate-sensitive character loss','-FallbackEvidence','fixture')
    Invoke-Fixture press-key @('-Key','Enter','-FallbackReason','Commit fixture input','-FallbackEvidence','fixture') | Out-Null
    Invoke-Fixture wait-file @('-Path',($output+'.paced'),'-TimeoutMs','2000','-MinBytes','1') | Out-Null
    if ([IO.File]::ReadAllText($output+'.paced') -ceq $pacedText) {throw 'Rate-sensitive fixture did not reproduce the old 5 ms character loss.'}
    $paced=Invoke-Fixture type @('-TargetMode','Focused','-Text',$pacedText,'-FallbackReason','Observed rate-sensitive custom editor','-FallbackEvidence','fixture')
    Invoke-Fixture press-key @('-Key','Enter','-FallbackReason','Commit fixture input','-FallbackEvidence','fixture') | Out-Null
    Invoke-Fixture wait-file @('-Path',($output+'.paced'),'-TimeoutMs','2000','-MinBytes','1') | Out-Null
    if ($paced.data.inputDelayMs -ne 20 -or [IO.File]::ReadAllText($output+'.paced') -cne $pacedText) {throw 'Default pacing lost characters in the rate-sensitive GUI fixture.'}
    $legacy=Invoke-Fixture type @('-TargetMode','Focused','-Text',$pacedText,'-TypeByCharacter','-FallbackReason','Compare legacy pacing','-FallbackEvidence','fixture')
    Invoke-Fixture press-key @('-Key','Enter','-FallbackReason','Commit fixture input','-FallbackEvidence','fixture') | Out-Null
    if ($legacy.data.inputDelayMs -ne 50 -or [IO.File]::ReadAllText($output+'.paced') -cne $pacedText) {throw 'Legacy pacing split Unicode scalars or lost text.'}
    "Pacing fixture ($($pacedText.Length) UTF-16 units): default=$($paced.durationMs) ms; legacy=$($legacy.durationMs) ms."
    Invoke-Fixture type @('-Name','Fixture input','-Text','','-PreDelete','-Verify') | Out-Null
    Invoke-Fixture click @('-Name','Fixture switching editor','-Method','Mouse') | Out-Null
    $switched=Invoke-PotatoCliCommand type @('-TargetMode','Focused','-Text','stop after focus changes','-InputDelayMs','30','-FallbackReason','Observe focus change mid-input','-FallbackEvidence','fixture') -CliRoot $root -AsObject
    $other=Invoke-Fixture read @('-Name','Fixture input')
    if ($switched.ok -or $switched.error.type -ne 'InputFocusChanged' -or $switched.outcome -ne 'unknown' -or $other.data.text) {throw 'Paced typing continued into a different control or concealed partial dispatch.'}
    Invoke-Fixture click @('-Name','Fixture modal opener','-ControlType','Button','-Method','Invoke') | Out-Null
    $compact=Invoke-Fixture observe @('-Scope','FocusedWindow','-Format','Compact','-Depth','4','-MaxElements','40')
    if ($compact.data.root.name -ne 'Fixture modal' -or @($compact.data.elements | Where-Object {$_.name -eq 'Fixture cancel'}).Count -ne 1 -or @($compact.data.elements | Where-Object {$_.name -eq 'Fixture input'}).Count) { throw 'FocusedWindow compact observation escaped the owned dialog.' }
    $dialogRoot=Invoke-Fixture wait-element @('-Scope','FocusedWindow','-Name','Fixture modal','-ControlType','Window','-TimeoutMs','0')
    if (-not $dialogRoot.data.exists) { throw 'Scoped window wait searched only children and missed the dialog itself.' }
    $wrongRoot=Invoke-Fixture wait-element @('-Scope','FocusedWindow','-Name',$title,'-ControlType','Window','-TimeoutMs','0')
    if ($wrongRoot.data.exists) { throw 'Scoped window wait escaped to the parent application.' }
    $shallow=Invoke-Fixture observe @('-Scope','FocusedWindow','-Format','Compact','-Depth','0','-MaxElements','40')
    if (-not $shallow.data.depthBoundaryReached -or $shallow.data.limitReached) { throw 'Shallow observation hid its depth boundary or confused it with the element limit.' }
    $guard=@('-TargetMode','Focused','-FallbackReason','Observed selected filename is already focused','-FallbackEvidence','fixture-observation')
    $wrong=Invoke-PotatoCliCommand type ($guard+@('-Text','must not send','-ExpectedFocusJson','{"Name":"Absent"}','-FocusTimeoutMs','0')) -CliRoot $root -AsObject
    $before=Invoke-Fixture read @('-Scope','FocusedWindow','-Name','Fixture filename')
    if ($wrong.ok -or $before.data.text -ne 'default.ext' -or $before.data.textSource -notin @('ValuePattern','TextPattern')) { throw 'Wrong focus guard sent input or readback lost its text source.' }
    $invalid=Invoke-PotatoCliCommand type ($guard+@('-Text',(Join-Path $root 'missing\output.ext'),'-PathKind','SaveFile')) -CliRoot $root -AsObject
    $unchanged=Invoke-Fixture read @('-Scope','FocusedWindow','-Name','Fixture filename')
    if ($invalid.ok -or $invalid.outcome -ne 'not-dispatched' -or $invalid.error.type -ne 'PathValidationFailed' -or $unchanged.data.text -ne 'default.ext') { throw 'Missing-parent path validation changed the filename field.' }
    $pathFolder=Join-Path $root ('literal [folder] '+[char]0x151+[char]0x4e2d)
    [void][IO.Directory]::CreateDirectory($pathFolder)
    $filenamePath=Join-Path $pathFolder ('literal +^%{} '+('x'*90)+'.ext')
    $replacement=Invoke-Fixture type ($guard+@('-Text',$filenamePath,'-PathKind','SaveFile','-ExpectedFocusJson','{"Name":"Fixture filename"}','-Verify'))
    if (-not $replacement.data.verified -or $replacement.data.pathValidation.path -cne $filenamePath -or (Test-Path -LiteralPath $filenamePath)) { throw 'Guarded filename typing changed the literal path, lost selection, or created output.' }
    $scoped=Invoke-Fixture select @('-Scope','FocusedWindow','-Name','Fixture cancel','-TimeoutMs','0')
    if ($scoped.data.count -ne 1) { throw 'FocusedWindow select did not find the dialog control.' }
    $modal=Invoke-Fixture select @('-Name','Fixture cancel','-ControlType','Button','-ProcessId',"$($child.Id)",'-ModalOnly','-TimeoutMs','2000')
    if ($modal.data.count -ne 1) { throw 'Modal selector did not cross the parent window boundary.' }
    $windows=Invoke-Fixture windows @('-ProcessId',"$($child.Id)")
    if (@($windows.data.windows | Where-Object {$_.isModal}).Count -ne 1) { $windows.data.windows | ConvertTo-Json -Depth 8; throw 'Modal window was not identified.' }
    Invoke-Fixture click @('-Scope','FocusedWindow','-Name','Fixture cancel') | Out-Null
    $unrelated=& $module {param($root)
        $statePath=Join-Path $root '.state\default.json'
        $original=Get-Content $statePath -Raw
        try {
            $s=$original | ConvertFrom-Json
            $s.working.processId=-1; $s.working.nativeWindowHandle=0
            $s | ConvertTo-Json -Depth 10 | Set-Content $statePath
            Invoke-PotatoCliCommand observe @('-Scope','FocusedWindow','-Format','Compact') -CliRoot $root -AsObject
        } finally { $original | Set-Content $statePath }
    } $root
    if ($unrelated.ok) { throw 'FocusedWindow accepted a foreground window outside the recorded owner.' }
    $foreignInput=& $module {param($root)
        $statePath=Join-Path $root '.state\default.json'
        $original=Get-Content $statePath -Raw
        try {
            $s=$original | ConvertFrom-Json; $s.working.processId=-1; $s.working.nativeWindowHandle=0
            $s | ConvertTo-Json -Depth 10 | Set-Content $statePath
            Invoke-PotatoCliCommand type @('-TargetMode','Focused','-Text','wrong owner','-FocusTimeoutMs','0','-FallbackReason','Fixture ownership rejection','-FallbackEvidence','fixture') -CliRoot $root -AsObject
        } finally { $original | Set-Content $statePath }
    } $root
    if ($foreignInput.ok -or $foreignInput.outcome -ne 'not-dispatched' -or $foreignInput.error.focus.owned) {throw 'Native focus fallback bypassed working application ownership.'}
    $brokerTitle=$title+' broker'
    $broker=Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-File',('"'+$fixture+'"'),'-Title',('"'+$brokerTitle+'"'),'-Output',('"'+$output+'.broker"')) -PassThru -WindowStyle Hidden
    $brokerReady=Invoke-Fixture wait-file @('-Path',($output+'.broker.ready'),'-TimeoutMs','10000','-MinBytes','1')
    if (-not $brokerReady.data.conditionMet) {throw 'Broker fixture did not start.'}
    $foreign=Invoke-PotatoCliCommand observe @('-Scope','FocusedWindow','-Format','Compact') -CliRoot $root -AsObject
    if ($foreign.ok -or $foreign.error.type -ne 'ScopeNotReady') {throw 'External broker was implicitly adopted.'}
    $brokerWindows=Invoke-Fixture windows @('-ProcessId',"$($broker.Id)")
    $windowJson=@{Name=$brokerTitle;ClassName=$brokerWindows.data.windows[0].className;ProcessId=$broker.Id} | ConvertTo-Json -Compress
    $scopeArgs=@('-Scope','ForegroundWindow','-WindowSelectorJson',$windowJson,'-FallbackReason','Observed system-hosted dialog fixture','-FallbackEvidence','fixture-window-observation')
    $brokerView=Invoke-Fixture observe ($scopeArgs+@('-Format','Compact','-Depth','3','-MaxElements','60'))
    if ($brokerView.data.root.name -ne $brokerTitle) {throw 'Explicit broker scope inspected the wrong window.'}
    $foreground=Invoke-Fixture windows @('-Foreground')
    if ($foreground.data.foregroundSelector.Name -ne $brokerTitle) {throw 'Foreground discovery missed the external window identity.'}
    $brokerText='Guarded path-like literal C:\folder with spaces\image.png'
    $brokerTyped=Invoke-Fixture type ($scopeArgs+@('-Name','Fixture input','-Text',$brokerText,'-Verify'))
    if (-not $brokerTyped.data.verified) {throw 'Guarded writable typing did not verify.'}
    Invoke-Fixture press-key ($scopeArgs+@('-Key','Tab','-ExpectedFocusJson','{"Name":"Fixture input"}')) | Out-Null
    Invoke-Fixture press-key ($scopeArgs+@('-Key','ShiftTab','-ExpectedFocusJson','{"Name":"Fixture save"}')) | Out-Null
    $brokerTyped=Invoke-Fixture type ($scopeArgs+@('-TargetMode','Focused','-ExpectedFocusJson','{"Name":"Fixture input"}','-PreDelete','-Text',$brokerText,'-Verify'))
    if (-not $brokerTyped.data.verified) {throw 'Guarded focused selection replacement did not verify.'}
    Invoke-Fixture click ($scopeArgs+@('-Name','Fixture save')) | Out-Null
    if (-not (Test-Path ($output+'.broker'))) {throw 'Guarded broker selector did not invoke the visible control.'}
    if ([IO.File]::ReadAllText($output+'.broker') -cne $brokerText) {throw 'Guarded input did not reach the broker field.'}
    $state=Invoke-Fixture state @()
    if ($state.data.state.working.processId -ne $child.Id) {throw 'Guarded scope changed the working process for cleanup.'}
    $wrongScope=$scopeArgs.Clone(); $wrongScope[3]='{"Name":"wrong window","ClassName":"wrong class"}'
    $mismatch=Invoke-PotatoCliCommand click ($wrongScope+@('-Name','Fixture save')) -CliRoot $root -AsObject
    if ($mismatch.ok -or $mismatch.outcome -ne 'not-dispatched') {throw 'Mismatched foreground guard dispatched a click.'}
    [void]$broker.CloseMainWindow(); if (-not $broker.WaitForExit(3000)) {throw 'Broker fixture did not close.'}
    Invoke-Fixture focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title) | Out-Null
    Invoke-Fixture click @('-Name','Fixture arm close prompt') | Out-Null
    $close=Invoke-Fixture close-window @('-ProcessId',"$($child.Id)")
    if ($close.data.closeRequested -ne 1 -or $close.data.requests[0].method -ne 'WM_CLOSE') {throw 'Close did not return an asynchronous request receipt.'}
    $confirmation=Invoke-Fixture wait-element @('-Scope','FocusedWindow','-Name','Fixture close confirmation','-ControlType','Window','-TimeoutMs','3000')
    if (-not $confirmation.data.exists -or $child.HasExited) {throw 'Close suppressed the application confirmation or claimed exit prematurely.'}
    Invoke-Fixture click @('-Scope','FocusedWindow','-Name','OK','-ControlType','Button') | Out-Null
    Invoke-Fixture close-window @('-ProcessId',"$($child.Id)") | Out-Null
    if (-not $child.WaitForExit(3000)) { throw 'Fixture window did not close.' }
    'GUI smoke: paced Unicode, focus-change abort, guarded external scope without adoption, literal/focused input, false UIA focus, ownership, paths, relative click, navigation, drag/drop, modal discovery and close prompts passed.'
}
finally {
    if ($broker -and -not $broker.HasExited) {$broker.Kill();$broker.WaitForExit()}
    if ($broker) {$broker.Dispose()}
    if ($child -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    if ($child) {$child.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-gui-fixture-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
