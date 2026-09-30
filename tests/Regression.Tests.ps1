param()
$ErrorActionPreference = 'Stop'
$cliRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('potato-regression-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$module = Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
try {
    & $module {
        param($testRoot)
        $script:checks = 0
        function Check($condition, $message) { if (-not $condition) { throw $message }; $script:checks++ }
        Initialize-PotatoAutomationTypes
        Initialize-PotatoEnvironment -CliRoot $testRoot
        $state = $script:CurrentState
        $state.lastAction = @{ command='fixture'; ok=$true }
        Save-PotatoState $state
        Check ((Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json).lastAction.command -eq 'fixture') 'Atomic replacement of existing state failed.'
        $lockedLog = [IO.File]::Open((Get-PotatoLogPath), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $failure = Invoke-PotatoCliCommand -Command state -CliRoot $testRoot -AsObject
            Check (-not $failure.ok -and $failure.outcome -eq 'not-dispatched' -and $null -ne $failure.error) 'Log failure was hidden behind successful JSON.'
        }
        finally { $lockedLog.Dispose() }
        $map = ConvertTo-PotatoArgumentMap @('-OffsetX', '-12', '-Text=-literal', '-Arguments', '"a b"')
        Check ($map.OffsetX -eq '-12' -and $map.Text -eq '-literal' -and $map.Arguments -eq '"a b"') 'Argument values were altered.'
        Check ((ConvertTo-PotatoLiteralKeys 'x+^%~(){}[]') -ceq 'x{+}{^}{%}{~}{(}{)}{{}{}}{[}{]}') 'SendKeys metacharacters are not literal.'
        Check ((ConvertTo-PotatoLiteralKeys "one`r`ntwo`tthree") -ceq 'one{ENTER}two{TAB}three') 'Newline/tab escaping is wrong.'
        $condition = New-PotatoSearchCondition @{ Name = 'Submit'; AutomationId = 'submit' }
        Check ($condition -is [System.Windows.Automation.AndCondition]) 'Exact predicates were not pushed to UIA.'
        Check ($condition.GetConditions().Count -eq 2) 'Conjunction lost a predicate.'
        $condition = New-PotatoSearchCondition @{ Name = @('Submit', 'Apply') }
        Check ($condition -is [System.Windows.Automation.OrCondition]) 'Alternative names lost OR semantics.'
        $condition = New-PotatoSearchCondition @{ Name = '*item*' }
        Check ($condition -eq [System.Windows.Automation.Condition]::TrueCondition) 'Wildcard was incorrectly narrowed.'
        $threw = $false
        try { New-PotatoSearchCondition @{Name='*invalid';Regex=$true} | Out-Null } catch { $threw = $_.Exception.Message -like 'Invalid regex*' }
        Check $threw 'Invalid regex must fail before retries.'
        $file = Join-Path $testRoot 'changing.bin'
        [IO.File]::WriteAllText($file, '')
        $result = Invoke-PotatoWaitFile @{Path=$file;TimeoutMs=0;MinBytes=1}
        Check ($result.exists -and -not $result.conditionMet -and $result.timedOut) 'Empty file satisfied MinBytes.'
        $writer = [powershell]::Create()
        [void]$writer.AddScript('param($path) Start-Sleep -Milliseconds 120; [IO.File]::WriteAllText($path,"abc"); Start-Sleep -Milliseconds 180; [IO.File]::WriteAllText($path,"xyz")').AddArgument($file)
        $pending = $writer.BeginInvoke()
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-PotatoWaitFile @{Path=$file;TimeoutMs=3000;MinBytes=3;StableMs=400}
            $writer.EndInvoke($pending) | Out-Null
            Check ($result.conditionMet -and $result.length -eq 3 -and $watch.ElapsedMilliseconds -ge 650) ('Wait did not account for same-size rewrites: elapsed='+$watch.ElapsedMilliseconds+' result='+($result | ConvertTo-Json -Compress)+' msSinceLastWrite='+([datetime]::UtcNow-[IO.File]::GetLastWriteTimeUtc($file)).TotalMilliseconds)
        }
        finally { $writer.Dispose() }
        $result = Invoke-PotatoWaitFile @{Path=$testRoot;TimeoutMs=0}
        Check (-not $result.conditionMet) 'A directory was treated as a file.'
        $result = Invoke-PotatoWaitFile @{Path=(Join-Path $testRoot 'missing');TimeoutMs=0;WaitForNotExists=$true}
        Check $result.conditionMet 'Missing-file condition failed.'
        $threw = $false
        try { Invoke-PotatoWaitFile @{Path=$file;WaitForNotExists=$true;StableMs=100} | Out-Null } catch { $threw = $true }
        Check $threw 'Incompatible file conditions were accepted.'

        # UIA fixtures model a button that disappears immediately after Invoke.
        $script:removed = $false
        $script:CurrentState = [pscustomobject]@{working=$null;lastAction=$null}
        function Resolve-PotatoCommandTarget { @{ok=$true;element=[pscustomobject]@{};selector=@{Name='Submit'}} }
        function ConvertTo-PotatoElementInfo {
            if ($script:removed) { throw 'Element no longer available' }
            @{isEnabled=$true;isOffscreen=$false;boundingRectangle=@{width=50;height=20}}
        }
        function Invoke-PotatoElementDefaultAction { $script:removed=$true; 'InvokePattern' }
        function Get-PotatoClickPoint { throw 'Invoked element must not be read again.' }
        function Save-PotatoState { }
        $result = Invoke-PotatoClick @{Focus=$false;ElementFocus=$false}
        Check ($result.clicked -and $result.action -eq 'InvokePattern' -and $null -eq $result.verified -and -not $result.verificationPerformed) 'Dispatch was mistaken for verification, or stale element was read.'
        function Get-PotatoWorkingElement { [pscustomobject]@{Name='fixture'} }
        function Find-PotatoElement { param($Selector,$Parent,$TimeoutMs,[switch]$FindFirst) $script:pathSelector=$Selector; $script:pathTimeout=$TimeoutMs; [pscustomobject]@{Name='child'} }
        $result = Resolve-PotatoSelectorPath -Path @([pscustomobject]@{Name='child';Recurse=$false;TimeoutMs=0})
        Check ($result.ok -and -not $script:pathSelector.Recurse -and $script:pathTimeout -eq 0) 'Explicit false/zero path options were replaced with defaults.'
        $inputs = Get-PotatoSelectorInputs @{SelectorJson='{"path":[{"Name":"parent"}],"target":{"Name":"child"}}'}
        Check ($inputs.path.Count -eq 1) 'Case-insensitive path property was duplicated.'

        # These process mocks never launch or terminate an application.
        function Get-Process { [pscustomobject]@{ ProcessName='sample'; Path='C:\sample.exe' } }
        function Stop-Process { param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force) process { $script:stopped = $InputObject.ProcessName } }
        function Start-Process { param($FilePath,$ArgumentList,[switch]$PassThru) [pscustomobject]@{Id=123;ProcessName='sample'} }
        function Wait-PotatoProcessWindow { param($Process,$TimeoutMs) return $null }
        $script:stopped = $null
        $result = Invoke-PotatoStart @{ProcessName='sample.exe';KillExisting=$true}
        Check ($script:stopped -eq 'sample') 'Bare .exe name did not match the process name.'
        $script:processLookups = 0
        function Get-Process { param($Name) $script:processLookups++; if ($script:processLookups -eq 1) { [pscustomobject]@{Id=99;ProcessName='sample'} } }
        $result = Invoke-PotatoStart @{ProcessName='sample.exe';RequireNewProcess=$true;WaitForPreviousExitMs=500}
        Check ($script:processLookups -ge 2 -and $result.ownedProcessId -eq 123) 'New-process launch did not wait for a closing instance and retain its owned PID.'
        function Get-Process { param($Name) [pscustomobject]@{Id=99;ProcessName='sample'} }
        $threw=$false
        try { Invoke-PotatoStart @{ProcessName='sample.exe';RequireNewProcess=$true;WaitForPreviousExitMs=0} | Out-Null } catch { $threw=$_.Exception.Message -like 'Application is already running*' }
        Check $threw 'Strict start accepted a still-running prior instance.'

        $script:CurrentState = [pscustomobject]@{working=$null}
        function Get-PotatoTopLevelWindows { throw 'A selector-less close must not enumerate the desktop.' }
        function Get-PotatoWorkingElement { return $null }
        $result = Invoke-PotatoCloseWindow @{}
        Check ($result.matched -eq 0) 'Close without context should do nothing.'
        function Get-PotatoTopLevelWindows { return @() }
        function Get-PotatoWorkingElement { throw 'An explicit miss must not fall back to another working window.' }
        $result = Invoke-PotatoCloseWindow @{ProcessName='missing'}
        Check ($result.matched -eq 0) 'Explicit close selector miss was unsafe.'
        "CLI private regression checks: $script:checks passed"
    } $testRoot

    # Exercise the actual script binder against a harmless recording module.
    $mockRoot = Join-Path $testRoot 'entry'
    New-Item -ItemType Directory -Path (Join-Path $mockRoot 'PoTAToCli') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $cliRoot 'potato.ps1') -Destination $mockRoot
    @'
function Invoke-PotatoCliCommand {
    param($Command, $Arguments, $CliRoot, [switch]$AsObject)
    $value=@{ok=$true;command=$Command;arguments=@($Arguments)}
    if ($AsObject) { return $value }; $value | ConvertTo-Json -Compress
}
Export-ModuleMember -Function Invoke-PotatoCliCommand
'@ | Set-Content -LiteralPath (Join-Path $mockRoot 'PoTAToCli\PoTAToCli.psm1') -Encoding UTF8
    $entryResult = & (Join-Path $mockRoot 'potato.ps1') start -ProcessName sample.exe -Arguments '"folder with spaces\input.ext"' | ConvertFrom-Json
    if ($entryResult.arguments.Count -ne 4 -or $entryResult.arguments[2] -ne '-Arguments' -or $entryResult.arguments[3] -cne '"folder with spaces\input.ext"') { throw 'Entry script consumed process arguments.' }
    $help = & (Join-Path $cliRoot 'potato.ps1') help -Topic type | ConvertFrom-Json
    if (-not $help.ok -or $help.data.topic -ne 'type') { throw 'Command help failed.' }
    'CLI entry/help checks: 2 passed'

    $streamLines=@(
        '{"requestId":"help-1","command":"help","arguments":["-Topic","type"]}',
        '{"requestId":"help-2","command":"help","arguments":["-Topic","click"]}',
        '{"requestId":"end-1","command":"quit"}'
    )
    $streamResults=@($streamLines | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cliRoot 'potato-stream.ps1') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($LASTEXITCODE -ne 0 -or $streamResults.Count -ne 3 -or @($streamResults | Where-Object { -not $_.ok }).Count -ne 0 -or
        $streamResults[0].requestId -ne 'help-1' -or $streamResults[1].requestId -ne 'help-2' -or $streamResults[2].command -ne 'quit') {
        throw ("Sequential CLI stream failed: exit=$LASTEXITCODE count=$($streamResults.Count) ids=$(@($streamResults | ForEach-Object { $_.requestId }) -join ',') ok=$(@($streamResults | ForEach-Object { $_.ok }) -join ',') firstError=$($streamResults[0].error.message).")
    }
    'CLI stream checks: 1 passed'
    $badBatch=@('{"command":"help","arguments":["-Topic","missing"]}','{"command":"help","arguments":["-Topic","type"]}')
    $stopped=@($badBatch | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cliRoot 'potato-stream.ps1') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($LASTEXITCODE -ne 1 -or $stopped.Count -ne 1 -or $stopped[0].ok) { throw 'Stream continued a dependent batch after failure.' }
    'CLI stream failure-stop check: passed'
}
finally {
    # testRoot is an explicitly created unique temp directory; verify before recursion.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-regression-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
