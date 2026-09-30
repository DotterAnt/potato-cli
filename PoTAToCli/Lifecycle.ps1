# Window ownership is separate from the process hosting the GUI. Never own a
# shell/broker process merely because it created a new test window.
function New-PotatoWindowCheckpoint {
    Initialize-PotatoWindowIdentity
    $value=@{id=[guid]::NewGuid().ToString('N');createdAt=(Get-Date).ToString('o');handles=@([PotatoWindowIdentity]::WindowHandles())}
    if ($script:CurrentState -is [Collections.IDictionary]) { $script:CurrentState.windowCheckpoint=$value }
    else { $script:CurrentState | Add-Member NoteProperty windowCheckpoint $value -Force }
    Save-PotatoState $script:CurrentState
    return $value
}

function Get-PotatoWindowCheckpoint {
    param([string]$Id)
    $checkpoint=$script:CurrentState.windowCheckpoint
    if (-not $Id -or -not $checkpoint -or $checkpoint.id -cne $Id) { throw 'SinceCheckpoint must identify the latest windows -Checkpoint receipt. Take it immediately before the GUI action that opens the new window.' }
    return $checkpoint
}

function New-PotatoOwnedWindow {
    param($Working)
    $process=Get-Process -Id $Working.processId -ErrorAction Stop
    Initialize-PotatoWindowIdentity
    if ([PotatoWindowIdentity]::ProcessId([IntPtr][long]$Working.nativeWindowHandle) -ne $process.Id) { throw 'Window disappeared before ownership could be recorded.' }
    $token=[guid]::NewGuid().ToString('N')
    [PotatoWindowIdentity]::TagWindow([IntPtr][long]$Working.nativeWindowHandle,$token)
    return [ordered]@{nativeWindowHandle=[long]$Working.nativeWindowHandle;processId=$process.Id;
        processStartTime=$process.StartTime.ToUniversalTime().Ticks.ToString();className=$Working.className;title=$Working.title;windowToken=$token}
}

function Get-PotatoTicketWindow {
    param([string]$Json)
    $ticket=ConvertFrom-PotatoJsonArgument $Json
    if (-not $ticket.nativeWindowHandle -or -not $ticket.processId -or -not $ticket.processStartTime -or -not $ticket.className -or $ticket.windowToken -notmatch '^[a-f0-9]{32}$') { throw 'WindowIdentityJson needs the complete ownedWindow receipt, including handle, process ID/start time, class and window token.' }
    Initialize-PotatoWindowIdentity
    if ([PotatoWindowIdentity]::ProcessId([IntPtr][long]$ticket.nativeWindowHandle) -ne [int]$ticket.processId) { return $null }
    if (-not [PotatoWindowIdentity]::HasWindowTag([IntPtr][long]$ticket.nativeWindowHandle,$ticket.windowToken)) { return $null }
    $process=Get-Process -Id $ticket.processId -ErrorAction SilentlyContinue
    if (-not $process -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne [string]$ticket.processStartTime) { return $null }
    $window=[Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$ticket.nativeWindowHandle)
    if ($window.Current.ClassName -cne $ticket.className) { return $null }
    return $window
}

function Invoke-PotatoStartWindow {
    param([hashtable]$ArgsMap,[string]$FilePath,[string]$Arguments,[string]$ProcessName,[int]$TimeoutMs,[bool]$Maximize)
    if ($TimeoutMs -lt 0 -or $TimeoutMs -gt 60000) { throw 'WaitForWindowMs must be 0..60000.' }
    $checkpoint=New-PotatoWindowCheckpoint
    $existingIds=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {$_.Id})
    $parameters=@{FilePath=$FilePath;PassThru=$true}
    if ($Arguments) { $parameters.ArgumentList=$Arguments }
    $started=Start-Process @parameters
    $previousWorking=$script:CurrentState.working
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        # A launcher may exit immediately after handing off to an existing host.
        # Match the actual new GUI window; its process need not be newly born.
        $windows=@(Get-PotatoTopLevelWindows -Selector @{ProcessName=$ProcessName} -TimeoutMs 0 | Where-Object {
            try { $_.Current.NativeWindowHandle -and $checkpoint.handles -notcontains [long]$_.Current.NativeWindowHandle -and -not $_.Current.IsOffscreen } catch {$false}
        })
        if ($windows.Count -gt 1) { throw 'Launch produced multiple new windows. Inspect windows, then focus the intended one with SinceCheckpoint; no process was adopted.' }
        if ($windows.Count -eq 1) {
            try {
                $working=Set-PotatoWorkingWindow $windows[0]
                $sharedHost=$existingIds -contains $working.processId
                $working['windowScoped']=$sharedHost
                $owned=New-PotatoOwnedWindow $working
                Save-PotatoState $script:CurrentState
                [void](Show-PotatoWindow -Handle $working.nativeWindowHandle -Maximize:$Maximize)
                return @{process=@{id=$(if ($started) {$started.Id} else {$null});processName=$ProcessName;started=$true};working=$working;
                    windowFound=$true;ownedProcessId=$(if (-not $sharedHost) {$working.processId} else {$null});
                    ownedProcessStartTime=$(if (-not $sharedHost) {$owned.processStartTime} else {$null});ownedWindow=$(if ($sharedHost) {$owned} else {$null});checkpointId=$checkpoint.id}
            } catch {
                $script:CurrentState.working=$previousWorking
                Save-PotatoState $script:CurrentState
                $cause=$_.Exception
                while ($cause.InnerException) {$cause=$cause.InnerException}
                if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 5) {throw}
                Write-PotatoLog -Level Warning -Message $_.Exception.Message
            }
        }
        if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds 100
    } while ($true)
    # Keep the previous interaction context and the checkpoint for explicit
    # recovery. Never silently reuse an old document or claim the launcher PID.
    throw 'No new visible window appeared for the launched executable. Inspect windows; use focus for an intentionally reused window, or focus -SinceCheckpoint for an observed new GUI handoff. Do not wrap the launch in a shell.'
}
