# Real standard Win32 controls, without an application's server-side UIA provider.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-native-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null
$script:checks=0
function Check($condition,$message) {if (-not $condition) {throw $message};$script:checks++}
try {
    $fixture=Join-Path $root 'form.ps1'
    @'
param($Title,$Output)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class NativeControlFixture : Form {
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(int ex,string cls,string text,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr id,IntPtr instance,IntPtr param);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint msg,IntPtr param,string text);
    [DllImport("user32.dll")] static extern IntPtr GetFocus();
    public IntPtr Combo;
    public string Output;
    public NativeControlFixture() { Width=390; Height=240; }
    protected override bool ProcessDialogKey(Keys key) {
        // This raw HWND has no managed Control wrapper. Let its own window
        // procedure receive arrows instead of WinForms navigating to a button.
        if (GetFocus()==Combo && (key==Keys.Down || key==Keys.Up)) return false;
        return base.ProcessDialogKey(key);
    }
    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        if (Combo!=IntPtr.Zero) return;
        Combo=CreateWindowExW(0,"ComboBox","",0x50210003,20,30,280,130,Handle,new IntPtr(101),IntPtr.Zero,IntPtr.Zero);
        foreach (string s in new[]{"Alpha choice","Beta choice","Gamma choice"}) SendMessageW(Combo,0x143,IntPtr.Zero,s);
        SendMessageW(Combo,0x14e,IntPtr.Zero,null);
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg==0x111 && (m.WParam.ToInt64() & 0xffff)==101 && ((m.WParam.ToInt64() >> 16) & 0xffff)==1)
            System.IO.File.WriteAllText(Output,SendMessageW(Combo,0x147,IntPtr.Zero,null).ToInt64().ToString());
    }
}
"@
$form=New-Object NativeControlFixture
$form.Text=$Title; $form.Output=$Output
$open=New-Object Windows.Forms.Button
$open.Text='Open modal';$open.AccessibleName='Open modal';$open.SetBounds(20,110,120,30)
$open.Add_Click({
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Native fixture modal';$dialog.Width=310;$dialog.Height=160
    $field=New-Object Windows.Forms.TextBox
    $field.AccessibleName='Modal field';$field.SetBounds(15,20,260,25)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel';$cancel.AccessibleName='Modal cancel';$cancel.SetBounds(15,60,90,30)
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton=$cancel
    $dialog.Controls.AddRange(@($field,$cancel));$dialog.Add_Shown({$field.Focus()})
    try {[void]$dialog.ShowDialog($form)} finally {$dialog.Dispose()}
})
$form.Controls.Add($open)
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $title='PoTATo native fixture '+[guid]::NewGuid().ToString('N')
    $output=Join-Path $root 'selection.txt'
    $child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$title+'"'),'-Output',('"'+$output+'"'))
    Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force
    function Invoke-Fixture($command,$values) {
        $result=Invoke-PotatoCliCommand -Command $command -Arguments $values -CliRoot $root -AsObject
        if (-not $result.ok) {throw ($result | ConvertTo-Json -Depth 12 -Compress)}
        $result
    }
    function Wait-Selection($expected) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do {
            if ((Test-Path -LiteralPath $output) -and [IO.File]::ReadAllText($output) -eq $expected) {return $true}
            Start-Sleep -Milliseconds 50
        } while ($watch.ElapsedMilliseconds -lt 2000)
        return $false
    }
    Invoke-Fixture focus @('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000') | Out-Null
    $combo=Invoke-Fixture select @('-AutomationId','101','-ControlType','ComboBox')
    Check ($combo.data.count -eq 1 -and $combo.data.elements[0].supportedPatterns -contains 'ExpandCollapse') 'Standard native ComboBox still appears as an opaque Pane.'
    $opened=Invoke-Fixture click @('-AutomationId','101')
    Check ($opened.data.action -eq 'ExpandCollapsePattern') 'Native dropdown did not expand through its UIA pattern.'
    $option=Invoke-Fixture select @('-Name','Beta choice','-ControlType','ListItem')
    Check ($option.data.count -eq 1) 'Expanded native dropdown does not expose named choices.'
    Invoke-Fixture click @('-Name','Beta choice','-ControlType','ListItem') | Out-Null
    Check (Wait-Selection '1') 'Named dropdown selection did not change the actual GUI control.'
    $navigation=@('-FallbackReason','Navigate the observed fixture dropdown','-FallbackEvidence','Native ComboBox fixture observation')
    $down=Invoke-Fixture press-key (@('-Key','down','-ExpectedFocusJson','{"AutomationId":"101"}')+$navigation)
    if (-not (Wait-Selection '2')) {
        $down | ConvertTo-Json -Depth 10 -Compress
        (Invoke-Fixture observe @('-AutomationId','101','-Depth','3')).data | ConvertTo-Json -Depth 10 -Compress
        throw ('Guarded arrow-key input did not change the actual selection. Current selection: '+[IO.File]::ReadAllText($output))
    }
    $script:checks++
    Invoke-Fixture click @('-Name','Open modal','-ControlType','Button') | Out-Null
    $modal=Invoke-Fixture wait-element @('-Scope','FocusedWindow','-Name','Modal field','-TimeoutMs','3000')
    Check $modal.data.exists 'Modal fixture did not open.'
    $foreground=Invoke-Fixture windows @('-Foreground')
    $scope=@('-Scope','ForegroundWindow','-WindowSelectorJson',($foreground.data.foregroundSelector | ConvertTo-Json -Compress),'-FallbackReason','Interact with observed fixture modal','-FallbackEvidence','Foreground fixture window receipt')
    $observed=Invoke-Fixture observe ($scope+@('-Depth','3','-Format','Compact'))
    Check $observed.data.keyboardFocus.ready 'Guarded observation falsely reported foreign keyboard focus.'
    $tab=Invoke-Fixture press-key ($scope+@('-Key','Tab','-ExpectedFocusJson','{"Name":"Modal field"}'))
    Check ($tab.data.after.name -eq 'Modal cancel') 'Native Tab did not move focus to the cancel control.'
    $back=Invoke-Fixture press-key ($scope+@('-Key','ShiftTab','-ExpectedFocusJson','{"Name":"Modal cancel"}'))
    Check ($back.data.after.name -eq 'Modal field') 'Native ShiftTab did not return to the field.'
    Invoke-Fixture press-key ($scope+@('-Key','Escape','-ExpectedFocusJson','{"Name":"Modal field"}')) | Out-Null
    $gone=Invoke-Fixture windows @('-WindowTitle','Native fixture modal','-ProcessId',"$($child.Id)",'-TimeoutMs','0')
    Check ($gone.data.count -eq 0) 'Native Escape did not dismiss the modal.'
    "Native GUI checks: $script:checks passed"
} finally {
    if ($child -and -not $child.HasExited) { $child.Kill();$child.WaitForExit() }
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-native-fixture-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
