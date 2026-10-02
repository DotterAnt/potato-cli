. (Join-Path $PSScriptRoot 'Interaction.ps1')
. (Join-Path $PSScriptRoot 'Pdf.ps1')
. (Join-Path $PSScriptRoot 'Discovery.ps1')
. (Join-Path $PSScriptRoot 'Focus.ps1')
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
$script:CliRoot = $null
$script:StateRoot = $null
$script:StatePath = $null
$script:RunsRoot = $null
$script:CurrentState = $null

function Initialize-PotatoEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CliRoot
    )

    $script:CliRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CliRoot)
    $script:StateRoot = Join-Path -Path $script:CliRoot -ChildPath '.state'
    $script:StatePath = Join-Path -Path $script:StateRoot -ChildPath 'default.json'
    $script:RunsRoot = Join-Path -Path $script:CliRoot -ChildPath 'runs'

    foreach ($path in @($script:StateRoot, $script:RunsRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    Initialize-PotatoAutomationTypes
    $script:CurrentState = Get-PotatoState
    Initialize-PotatoRun -State $script:CurrentState | Out-Null
}

function Initialize-PotatoAutomationTypes {
    [CmdletBinding()]
    param()

    if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
        Add-Type -AssemblyName @('UIAutomationClient', 'UIAutomationTypes')
    }
    if (-not $script:StandardProvidersRegistered) {
        # PowerShell's assembly loading can leave the managed default proxy table
        # empty: native Edit/ComboBox/menu controls then appear as opaque Panes.
        Add-Type -AssemblyName UIAutomationClientsideProviders
        $providers=[UIAutomationClientsideProviders.UIAutomationClientSideProviders]::ClientSideProviderDescriptionTable
        try { [System.Windows.Automation.ClientSettings]::RegisterClientSideProviders($providers) }
        catch {
            # .NET Framework's first LoadDefaultProxies can dereference the
            # absent entry assembly in a PowerShell host. Retry that one lazy-
            # initialization failure; all other registration errors stay fatal.
            $cause=$_.Exception
            while ($cause.InnerException) { $cause=$cause.InnerException }
            if ($cause -isnot [NullReferenceException] -or $cause.StackTrace -notmatch 'ProxyManager.LoadDefaultProxies') { throw }
            [System.Windows.Automation.ClientSettings]::RegisterClientSideProviders($providers)
        }
        $script:StandardProvidersRegistered=$true
    }
    if (-not ('System.Windows.Forms.Cursor' -as [type])) {
        Add-Type -AssemblyName System.Windows.Forms
    }
    if (-not ('System.Drawing.Bitmap' -as [type])) {
        Add-Type -AssemblyName System.Drawing
    }

}

function Initialize-PotatoNativeMouse {
    [CmdletBinding()]
    param()

    if ('PotatoMouseNative' -as [type]) { return $true }

    try {
        Add-Type -Path (Join-Path $PSScriptRoot 'MouseInput.cs')
        return $true
    }
    catch {
        Write-PotatoLog -Level Warning -Message "Native mouse input could not be initialized: $($_.Exception.Message)"
        return $false
    }
}

function New-PotatoStateObject {
    [CmdletBinding()]
    param()

    [ordered]@{
        version = 1
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        runId = (New-Guid).Guid
        working = $null
        lastAction = $null
        lastReport = $null
    }
}

function Get-PotatoState {
    [CmdletBinding()]
    param()

    if ($script:StatePath -and (Test-Path -LiteralPath $script:StatePath)) {
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if (-not $state.runId) {
                $state | Add-Member -NotePropertyName runId -NotePropertyValue ((New-Guid).Guid) -Force
            }
            return $state
        }
        catch {
            return New-PotatoStateObject
        }
    }

    $newState = New-PotatoStateObject
    Save-PotatoState -State $newState
    return Get-PotatoState
}

function Save-PotatoState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $State
    )

    if (-not $script:StateRoot) {
        throw 'PoTATo CLI environment is not initialized.'
    }
    if (-not (Test-Path -LiteralPath $script:StateRoot)) {
        New-Item -Path $script:StateRoot -ItemType Directory -Force | Out-Null
    }

    $State.updatedAt = (Get-Date).ToString('o')
    $temp = $script:StatePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($script:StatePath)) { [IO.File]::Replace($temp, $script:StatePath, [NullString]::Value) }
        else { [IO.File]::Move($temp, $script:StatePath) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    $script:CurrentState = $State
}

function Initialize-PotatoRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $State
    )

    if (-not $State.runId) {
        $State | Add-Member -NotePropertyName runId -NotePropertyValue ((New-Guid).Guid) -Force
        Save-PotatoState -State $State
    }

    $runPath = Get-PotatoRunPath -RunId $State.runId
    foreach ($path in @($runPath, (Join-Path $runPath 'screenshots'))) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
    return $runPath
}

function Get-PotatoRunPath {
    [CmdletBinding()]
    param(
        [string] $RunId = $script:CurrentState.runId
    )

    Join-Path -Path $script:RunsRoot -ChildPath $RunId
}

function Get-PotatoLogPath {
    [CmdletBinding()]
    param()

    Join-Path -Path (Get-PotatoRunPath) -ChildPath 'potato.log'
}

function Get-PotatoMetricsPath {
    [CmdletBinding()]
    param()

    Join-Path -Path (Get-PotatoRunPath) -ChildPath 'metrics.jsonl'
}

function Write-PotatoLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string] $Level = 'Info',

        [string] $Command = ''
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        command = $Command
        message = $Message
    }
    $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath (Get-PotatoLogPath) -Encoding UTF8 -ErrorAction Stop
}

function Write-PotatoMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Metric
    )

    try {
        $Metric | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath (Get-PotatoMetricsPath) -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        try { Write-PotatoLog -Level Warning -Message "Metric write failed: $($_.Exception.Message)" } catch {}
    }
}

function ConvertTo-PotatoArgumentMap {
    [CmdletBinding()]
    param(
        [string[]] $Arguments = @()
    )

    $map = [ordered]@{ _ = @() }
    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = $Arguments[$i]
        if ($arg -match '^-{1,2}([^=]+)=(.*)$') {
            $map[$Matches[1]] = $Matches[2]
            $i++
            continue
        }

        if ($arg -match '^-{1,2}(.+)$') {
            $name = $Matches[1]
            if (($i + 1) -lt $Arguments.Count -and ($Arguments[$i + 1] -notmatch '^-' -or $Arguments[$i + 1] -match '^-\d+(\.\d+)?$')) {
                $map[$name] = $Arguments[$i + 1]
                $i += 2
            }
            else {
                $map[$name] = $true
                $i++
            }
            continue
        }

        $map._ += $arg
        $i++
    }
    return $map
}

function Get-PotatoArg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap,

        [Parameter(Mandatory)]
        [string[]] $Names,

        [object] $Default = $null
    )

    foreach ($name in $Names) {
        if ($ArgsMap.Contains($name)) {
            return $ArgsMap[$name]
        }
    }
    return $Default
}

function ConvertTo-PotatoBool {
    [CmdletBinding()]
    param(
        [object] $Value,
        [bool] $Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $text = [string]$Value
    if ($text -match '^(1|true|yes|y|on)$') { return $true }
    if ($text -match '^(0|false|no|n|off)$') { return $false }
    return $Default
}

function ConvertTo-PotatoInt {
    [CmdletBinding()]
    param(
        [object] $Value,
        [int] $Default = 0
    )

    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function New-PotatoSelectorFromArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $selector = [ordered]@{}
    foreach ($pair in @(
        @{ key = 'Name'; names = @('Name', 'WindowName') },
        @{ key = 'AutomationId'; names = @('AutomationId', 'Id') },
        @{ key = 'ClassName'; names = @('ClassName', 'Class') },
        @{ key = 'ControlType'; names = @('ControlType') },
        @{ key = 'ProcessName'; names = @('ProcessName') },
        @{ key = 'ProcessId'; names = @('ProcessId') },
        @{ key = 'WindowTitle'; names = @('WindowTitle') }
    )) {
        $value = Get-PotatoArg -ArgsMap $ArgsMap -Names $pair.names
        if ($null -ne $value -and "$value" -ne '') {
            $selector[$pair.key] = $value
        }
    }

    $selector.ModalOnly = ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('ModalOnly')) $false
    $selector.InteractiveOnly = ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('InteractiveOnly')) $false
    $selector.Regex = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Regex')) $false
    $selector.Recurse = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Recurse')) $true
    $selector.FindFirst = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('FindFirst')) $false
    $selector.TimeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('TimeoutMs', 'MillisecondsToWait')) 1000
    return $selector
}

function ConvertFrom-PotatoJsonArgument {
    [CmdletBinding()]
    param(
        [object] $Value
    )

    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [string]) {
        return ($Value | ConvertFrom-Json)
    }
    return $Value
}

function Test-PotatoPattern {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Actual,

        [AllowNull()]
        [object] $Expected,

        [bool] $Regex = $false
    )

    if ($null -eq $Expected -or "$Expected" -eq '') { return $true }
    $actualText = [string]$Actual
    foreach ($item in @($Expected)) {
        $expectedText = [string]$item
        if ($Regex) {
            if ($actualText -match $expectedText) { return $true }
        }
        elseif ($expectedText -match '[\*\?\[]') {
            if ($actualText -like $expectedText) { return $true }
        }
        else {
            if ($actualText -ieq $expectedText) { return $true }
        }
    }
    return $false
}

function Get-PotatoControlTypeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element
    )

    try {
        return $Element.Current.ControlType.ProgrammaticName.Split('.')[-1]
    }
    catch {
        return ''
    }
}

function Test-PotatoElementMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element,

        [Parameter(Mandatory)]
        [object] $Selector
    )

    $regex = ConvertTo-PotatoBool $Selector.Regex $false
    $current = $Element.Current
    if ($Selector.InteractiveOnly -and ($current.IsOffscreen -or -not $current.IsEnabled)) { return $false }
    if ($Selector.ModalOnly -and -not (Test-PotatoModalAncestor $Element)) { return $false }
    if ($Selector.ProcessId -and $current.ProcessId -ne [int]$Selector.ProcessId) { return $false }
    $controlName = Get-PotatoControlTypeName -Element $Element

    if (-not (Test-PotatoPattern -Actual $current.Name -Expected $Selector.Name -Regex $regex)) { return $false }
    if (-not (Test-PotatoPattern -Actual $current.AutomationId -Expected $Selector.AutomationId -Regex $regex)) { return $false }
    if (-not (Test-PotatoPattern -Actual $current.ClassName -Expected $Selector.ClassName -Regex $regex)) { return $false }
    if ($Selector.ProcessName) {
        $processName = ''
        try { $processName = (Get-Process -Id $current.ProcessId -ErrorAction Stop).ProcessName } catch {}
        if (-not (Test-PotatoPattern -Actual $processName -Expected $Selector.ProcessName -Regex $regex)) { return $false }
    }
    if (-not (Test-PotatoPattern -Actual $current.Name -Expected $Selector.WindowTitle -Regex $regex)) { return $false }

    if ($Selector.ControlType -and "$($Selector.ControlType)" -ne '') {
        $localized = $current.LocalizedControlType
        if (-not (Test-PotatoPattern -Actual $controlName -Expected $Selector.ControlType -Regex $regex) -and
            -not (Test-PotatoPattern -Actual $localized -Expected $Selector.ControlType -Regex $regex)) {
            return $false
        }
    }
    return $true
}

function Get-PotatoRootElement {
    [CmdletBinding()]
    param()

    [System.Windows.Automation.AutomationElement]::RootElement
}

function Get-PotatoWorkingElement {
    [CmdletBinding()]
    param(
        [switch] $Required
    )

    $state = $script:CurrentState
    if (-not $state -or -not $state.working) {
        if ($Required) { throw 'No working window is set. Run start or focus first, or pass an explicit selector.' }
        return $null
    }

    $handle = [IntPtr]::Zero
    if ($state.working.nativeWindowHandle) {
        $handle = [IntPtr]([int64]$state.working.nativeWindowHandle)
        try {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if ($element -and $element.Current.ProcessId -eq $state.working.processId) { return $element }
        }
        catch {}
    }

    if ($state.working.windowScoped) {
        if ($Required) { throw 'The selected window closed. Use windows and focus explicitly; another window in the same host is not a replacement.' }
        return $null
    }
    $selector = [ordered]@{
        ProcessId = $state.working.processId
        ControlType = 'Window'
        Recurse = $false
        FindFirst = $true
        TimeoutMs = 100
    }
    if (-not $selector.ProcessId) { throw 'Working window has no process identity. Run focus with an explicit selector.' }
    $replacement = @(Find-PotatoElement -Selector $selector -Parent (Get-PotatoRootElement) -TimeoutMs 100 -FindFirst) | Select-Object -First 1
    if ($replacement) { [void](Set-PotatoWorkingWindow -Element $replacement); return $replacement }
    if ($Required) { throw 'Working window no longer exists. Observe windows and focus the owned application explicitly.' }
    return $null
}

function New-PotatoSearchCondition {
    param([Parameter(Mandatory)] [object] $Selector)

    $conditions = @()
    foreach ($field in @('Name', 'AutomationId', 'ClassName', 'WindowTitle', 'ControlType', 'ProcessName')) {
        foreach ($pattern in @($Selector.$field)) {
            if ($pattern -and (ConvertTo-PotatoBool $Selector.Regex $false)) {
                try { [void][regex]::new([string]$pattern) }
                catch { throw "Invalid regex for ${field}: '$pattern'. Use wildcard patterns without -Regex, or valid regular expressions." }
            }
        }
    }
    if (ConvertTo-PotatoBool $Selector.Regex $false) { return [System.Windows.Automation.Condition]::TrueCondition }

    if ($Selector.ProcessId) { $conditions += New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$Selector.ProcessId) }
    # Some custom providers report visibility/enabled correctly on Current but
    # omit the same controls when these properties are in a compound FindAll.
    # Test-PotatoElementMatch enforces both locally; never relax eligibility.
    # Push exact type predicates as well as strings. OR with the localized name
    # preserves the existing public matcher while avoiding marshaling every cell.
    if ($Selector.ControlType -and @($Selector.ControlType | Where-Object { "$_" -match '[\*\?\[]' }).Count -eq 0) {
        $types=@()
        foreach ($value in @($Selector.ControlType)) {
            $type=$null
            try { $type=[System.Windows.Automation.ControlType]::$value } catch {}
            if ($type) { $types += New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,$type) }
            $types += New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::LocalizedControlTypeProperty,[string]$value,[System.Windows.Automation.PropertyConditionFlags]::IgnoreCase)
        }
        if ($types.Count -eq 1) { $conditions += $types[0] }
        else { $conditions += New-Object System.Windows.Automation.OrCondition(,[System.Windows.Automation.Condition[]]$types) }
    }
    foreach ($field in @('Name', 'AutomationId', 'ClassName', 'WindowTitle')) {
        $values = @($Selector.$field)
        if (-not $Selector.$field -or @($values | Where-Object { "$_" -match '[\*\?\[]' }).Count) { continue }
        $propertyName = if ($field -eq 'WindowTitle') { 'NameProperty' } else { $field + 'Property' }
        $property = [System.Windows.Automation.AutomationElement]::$propertyName
        $alternatives = @($values | ForEach-Object {
            New-Object System.Windows.Automation.PropertyCondition($property, [string]$_, [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase)
        })
        if ($alternatives.Count -eq 1) { $conditions += $alternatives[0] }
        elseif ($alternatives.Count -gt 1) { $conditions += New-Object System.Windows.Automation.OrCondition(,[System.Windows.Automation.Condition[]]$alternatives) }
    }
    if ($conditions.Count -eq 0) { return [System.Windows.Automation.Condition]::TrueCondition }
    if ($conditions.Count -eq 1) { return $conditions[0] }
    return New-Object System.Windows.Automation.AndCondition(,[System.Windows.Automation.Condition[]]$conditions)
}

function Find-PotatoElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Selector,

        [object] $Parent = $null,

        [int] $TimeoutMs = -1,

        [switch] $FindFirst,
        [int] $MaxResults = 0,
        [switch] $RefreshWorkingParent,
        [switch] $RefreshFocusedParent,
        [string] $ForegroundSelectorJson,
        [switch] $IncludeRoot,
        [switch] $CheckBlockingDialog
    )

    if (-not $Parent) {
        $Parent = Get-PotatoWorkingElement
        if (-not $Parent) {
            $Parent = Get-PotatoRootElement
        }
    }

    $effectiveTimeout = $TimeoutMs
    if ($effectiveTimeout -lt 0) {
        $effectiveTimeout = ConvertTo-PotatoInt $Selector.TimeoutMs 1000
    }
    $recurse = ConvertTo-PotatoBool $Selector.Recurse $true
    $scope = [System.Windows.Automation.TreeScope]::Children
    if ($recurse) {
        $scope = [System.Windows.Automation.TreeScope]::Descendants
    }
    # Validate before the retry loop. An invalid regex must not become a silent miss.
    $condition = New-PotatoSearchCondition -Selector $Selector
    $firstOnly = $FindFirst -or (ConvertTo-PotatoBool $Selector.FindFirst $false)
    $exact = -not $Selector.Regex -and -not $Selector.ProcessName -and -not $Selector.ModalOnly
    foreach ($field in @('Name','AutomationId','ClassName','WindowTitle','ControlType')) {
        if (@($Selector.$field | Where-Object { "$_" -match '[\*\?\[]' }).Count) { $exact=$false }
    }
    $stopAt = (Get-Date).AddMilliseconds($effectiveTimeout)
    $attempt = 0

    do {
        $matches = @()
        $blockingDialog = $null
        $seen=New-Object 'Collections.Generic.HashSet[string]'
        try {
            if ($RefreshWorkingParent -and $attempt -gt 0) {
                $Parent = Get-PotatoWorkingElement
                if (-not $Parent) {
                    if ((Get-Date) -lt $stopAt) { Start-Sleep -Milliseconds 100 }
                    continue
                }
            }
            if ($RefreshFocusedParent -and $attempt -gt 0) { $Parent=Get-PotatoFocusedWindow }
            if ($ForegroundSelectorJson) { $Parent=Get-PotatoGuardedForegroundWindow $ForegroundSelectorJson }
            $attempt++
            if ($IncludeRoot -and (Test-PotatoElementMatch -Element $Parent -Selector $Selector)) {
                $matches=@($Parent)
                $identity=Get-PotatoElementIdentityKey $Parent
                if ($identity) { [void]$seen.Add($identity) }
                if ($firstOnly -or $MaxResults -eq 1) { return ,$Parent }
            }
            if ($firstOnly -and $exact) { $collection = @($Parent.FindFirst($scope, $condition)) | Where-Object { $null -ne $_ } }
            else { $collection = $Parent.FindAll($scope, $condition) }
            foreach ($element in $collection) {
                $identity=Get-PotatoElementIdentityKey $element
                if ($identity -and -not $seen.Add($identity)) { continue }
                try { $matched = Test-PotatoElementMatch -Element $element -Selector $Selector } catch { continue }
                if ($matched) {
                    $matches += $element
                    if ($firstOnly) {
                        return ,$matches[0]
                    }
                    if ($MaxResults -gt 0 -and $matches.Count -ge $MaxResults) { break }
                }
            }
            # A confirmed modal can make the disabled provider tree inaccessible.
            # Inspect it before spending the fallback traversal budget behind it.
            if (-not $matches.Count -and $CheckBlockingDialog) { $blockingDialog=Get-PotatoBlockingDialog $Parent }
            if (-not $matches.Count -and -not $blockingDialog -and $Parent.Current.ProcessId -gt 0) {
                $limit=if ($firstOnly) {1} else {$MaxResults}
                $fallback=Find-PotatoObservedTreeMatches $Parent $Selector $recurse $limit
                $matches=@($fallback.matches)
            }
        }
        catch {
            if ($_.Exception.Data['PotatoErrorType'] -in @('SearchIncomplete','ScopeNotReady')) { throw }
            Write-PotatoLog -Level Warning -Message "Element search failed: $($_.Exception.Message)"
        }

        if ($matches.Count -gt 0) { return $matches }
        if ($CheckBlockingDialog) {
            $dialog=if ($blockingDialog) {$blockingDialog} else {Get-PotatoBlockingDialog $Parent}
            if ($dialog) {
                $failure=New-Object InvalidOperationException('The requested control is absent and an owned modal dialog blocks the working window. Inspect error.blockingDialog and the actual GUI before recovery.')
                $failure.Data['PotatoErrorType']='WaitBlockedByDialog';$failure.Data['NoInputSent']=$true
                $failure.Data['blockingDialog']=$dialog
                throw $failure
            }
        }
        if ((Get-Date) -lt $stopAt) { Start-Sleep -Milliseconds 100 }
    } while ((Get-Date) -lt $stopAt)

    return @()
}

function Resolve-PotatoSelectorPath {
    [CmdletBinding()]
    param(
        [object] $Path,
        [object] $StartParent = $null,
        [int] $DefaultTimeoutMs = 1000,
        [switch] $RequireUnique
    )

    $parent = $StartParent
    if (-not $parent) {
        $parent = Get-PotatoWorkingElement
        if (-not $parent) { $parent = Get-PotatoRootElement }
    }

    if (-not $Path) {
        return [ordered]@{ ok = $true; element = $parent; failedIndex = $null; failedSelector = $null }
    }

    $selectors = @($Path)
    for ($i = 0; $i -lt $selectors.Count; $i++) {
        $selector = $selectors[$i]
        if ($null -eq $selector.Recurse) { $selector | Add-Member -NotePropertyName Recurse -NotePropertyValue $true -Force }
        if ($null -eq $selector.FindFirst) { $selector | Add-Member -NotePropertyName FindFirst -NotePropertyValue $true -Force }
        if ($null -eq $selector.TimeoutMs) { $selector | Add-Member -NotePropertyName TimeoutMs -NotePropertyValue $DefaultTimeoutMs -Force }

        if ($RequireUnique) {
            $selector=Get-PotatoUniqueSelector $selector
            $matches=@(Find-PotatoElement -Selector $selector -Parent $parent -MaxResults 8 -TimeoutMs (ConvertTo-PotatoInt $selector.TimeoutMs $DefaultTimeoutMs))
            Assert-PotatoUniqueMatches $matches
            $found=$matches | Select-Object -First 1
        } else {
            $found = @(Find-PotatoElement -Selector $selector -Parent $parent -FindFirst -TimeoutMs (ConvertTo-PotatoInt $selector.TimeoutMs $DefaultTimeoutMs)) | Select-Object -First 1
        }
        if (-not $found) {
            return [ordered]@{ ok = $false; element = $null; failedIndex = $i; failedSelector = $selector }
        }
        $parent = $found
    }

    return [ordered]@{ ok = $true; element = $parent; failedIndex = $null; failedSelector = $null }
}

function Get-PotatoSelectorInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $selectorJson = ConvertFrom-PotatoJsonArgument (Get-PotatoArg -ArgsMap $ArgsMap -Names @('SelectorJson'))
    $pathJson = ConvertFrom-PotatoJsonArgument (Get-PotatoArg -ArgsMap $ArgsMap -Names @('PathJson'))
    $selector = New-PotatoSelectorFromArguments -ArgsMap $ArgsMap

    if ($selectorJson) {
        if ($selectorJson -is [array]) {
            $pathJson = $selectorJson
        }
        elseif ($selectorJson.path -or $selectorJson.Path) {
            $pathJson = @($selectorJson.path)
            if ($selectorJson.target) {
                $selector = $selectorJson.target
            }
            elseif ($selectorJson.Target) {
                $selector = $selectorJson.Target
            }
        }
        else {
            $selector = $selectorJson
        }
    }

    [ordered]@{
        selector = $selector
        path = $pathJson
    }
}

function ConvertTo-PotatoRectangle {
    param([object] $Rectangle)
    if ($null -eq $Rectangle -or $Rectangle.IsEmpty) { return $null }
    $bounds = [ordered]@{}
    foreach ($part in @('X','Y','Width','Height')) {
        $value = [double]$Rectangle.$part
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or
            $value -lt [int]::MinValue -or $value -gt [int]::MaxValue) { return $null }
        $bounds[$part.ToLowerInvariant()] = [int][Math]::Round($value)
    }
    if ($bounds.width -le 0 -or $bounds.height -le 0) { return $null }
    return $bounds
}

function ConvertTo-PotatoElementInfo {
    param([Parameter(Mandatory)] [object] $Element, [switch]$Snapshot)
    $info = [ordered]@{}
    $errors = @()
    # Snapshot observation properties in one UIA request. Action checks continue
    # using live Current values; no element cache survives a desktop transition.
    $cached=if ($Snapshot) { Get-PotatoObservationSnapshot $Element }
    $properties=if ($cached) {$cached.Cached} else {$Element.Current}
    foreach ($property in @('Name','AutomationId','ClassName','LocalizedControlType','ProcessId','NativeWindowHandle','IsEnabled','IsOffscreen','HasKeyboardFocus','IsKeyboardFocusable')) {
        $key = $property.Substring(0,1).ToLowerInvariant() + $property.Substring(1)
        try { $info[$key] = $properties.$property; if ($null -eq $info[$key]) { $errors += "$property unavailable." } }
        catch { $info[$key] = $null; $errors += "$property`: $($_.Exception.Message)" }
    }
    $info.controlType = $null
    try { $info.controlType = $properties.ControlType.ProgrammaticName.Replace('ControlType.','') } catch { $errors += 'ControlType unavailable.' }
    $info.processName = ''
    try { $info.processName = (Get-Process -Id $info.processId -ErrorAction Stop).ProcessName } catch {}
    $info.boundingRectangle = $null
    try { $info.boundingRectangle = ConvertTo-PotatoRectangle $properties.BoundingRectangle } catch { $errors += 'BoundingRectangle unavailable.' }
    $info.boundsStatus = if ($info.boundingRectangle) { 'valid' } else { 'empty-invalid-or-unavailable' }
    $info.supportedPatterns = @()
    try {
        if ($cached) { $info.supportedPatterns=@($script:ObservationPatternProperties | Where-Object {$cached.GetCachedPropertyValue($_.property) -eq $true} | ForEach-Object {$_.name}) }
        else { $info.supportedPatterns = @($Element.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName.Replace('PatternIdentifiers.Pattern','') }) }
    }
    catch { $errors += 'Supported patterns unavailable.' }
    $info.isModal = $false
    try {
        $windowPattern = $null
        if ($cached) { $info.isModal=$cached.GetCachedPropertyValue([Windows.Automation.WindowPattern]::IsModalProperty) -eq $true }
        elseif ($Element.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$windowPattern)) {
            $info.isModal = [bool]$windowPattern.Current.IsModal
        }
    }
    catch { $errors += 'Modal state unavailable.' }
    $info.propertyErrors = $errors
    return $info
}

function Set-PotatoWorkingWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element,

        [object] $Process = $null
    )

    $info = ConvertTo-PotatoElementInfo -Element $Element
    # A splash/provider can disappear between discovery and property reads.
    # Never persist a partially read identity, even when other properties exist.
    if (-not $info.processId -or [int]$info.processId -le 0 -or -not $info.nativeWindowHandle) {
        throw 'Window identity became unavailable before activation. Rediscover the owned window.'
    }
    Initialize-PotatoWindowIdentity
    if ([PotatoWindowIdentity]::ProcessId([IntPtr][int64]$info.nativeWindowHandle) -ne [int]$info.processId) {
        throw 'Window handle and process identity changed before activation. Rediscover the owned window.'
    }
    if (-not $Process -and $info.processId) {
        try { $Process = Get-Process -Id $info.processId -ErrorAction Stop } catch {}
    }

    $working = [ordered]@{
        title = $info.name
        processName = $info.processName
        processId = $info.processId
        nativeWindowHandle = $info.nativeWindowHandle
        className = $info.className
        updatedAt = (Get-Date).ToString('o')
    }
    if ($Process -and $Process.Id -eq $info.processId) {
        # A launcher can exit or hand off to another process. UIA owns the
        # authoritative window identity, never the initial launcher PID.
        if ($Process.ProcessName) { $working.processName = $Process.ProcessName }
        if (-not $working.title) { $working.title = $Process.MainWindowTitle }
        if (-not $working.nativeWindowHandle) { $working.nativeWindowHandle = $Process.MainWindowHandle.ToInt64() }
    }

    $script:CurrentState.working = $working
    Save-PotatoState -State $script:CurrentState
    return $working
}

function Show-PotatoWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int64] $Handle,

        [switch] $Maximize
    )

    if ($Handle -eq 0) { return $false }
    try {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Handle)
        if (-not $element) { return $false }
        if ($Maximize) {
            try {
                $pattern = $element.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                $pattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized)
            }
            catch {}
        }
        try { $element.SetFocus() } catch {}
        return $true
    }
    catch {
        return $false
    }
}

function Get-PotatoTopLevelWindows {
    [CmdletBinding()]
    param(
        [object] $Selector = $null,
        [int] $TimeoutMs = 0,
        [switch] $RequireComplete
    )

    # Native handles are authoritative here; retrieving the unused desktop UIA
    # root adds a provider round trip to every window poll.
    $stopAt = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $windows = @()
        $enumerationError=$null
        $processWindows = @()
        try {
            # Native top-level handles include broker/owned dialogs that some
            # providers nest beneath their owner. Never search every desktop
            # descendant just to wait for a window title.
            Initialize-PotatoWindowIdentity
            $all=@(foreach ($handle in [PotatoWindowIdentity]::WindowHandles()) {
                if (-not [PotatoWindowIdentity]::IsWindowVisible([IntPtr]$handle)) { continue }
                if ($Selector -and $Selector.ProcessId -and [PotatoWindowIdentity]::ProcessId([IntPtr]$handle) -ne [int]$Selector.ProcessId) { continue }
                try { [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$handle) }
                catch { if ([PotatoWindowIdentity]::IsWindowVisible([IntPtr]$handle)) { $enumerationError=$_.Exception.Message } }
            })
            foreach ($window in $all) {
                if ($Selector -and $Selector.ProcessId -and $window.Current.ProcessId -eq [int]$Selector.ProcessId) { $processWindows += $window }
                try { $matchesSelector = -not $Selector -or (Test-PotatoElementMatch -Element $window -Selector $Selector) }
                catch {
                    if ([PotatoWindowIdentity]::IsWindowVisible([IntPtr]$window.Current.NativeWindowHandle)) { $enumerationError=$_.Exception.Message }
                    continue
                }
                if ($matchesSelector) {
                    $windows += $window
                }
            }
            # Some providers expose a modal Window beneath its owner in the UIA
            # tree, rather than as a desktop child. A PID-scoped query must see it.
            if ($Selector -and $Selector.ProcessId) {
                $windowCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Window)
                foreach ($owner in $processWindows) {
                    try {
                        $nested = $owner.FindAll([System.Windows.Automation.TreeScope]::Descendants, $windowCondition)
                        foreach ($candidate in $nested) {
                            if (-not (Test-PotatoModalAncestor $candidate)) { continue }
                            if (Test-PotatoElementMatch -Element $candidate -Selector $Selector) { $windows += $candidate }
                        }
                    }
                    catch { if ([PotatoWindowIdentity]::IsWindowVisible([IntPtr]$owner.Current.NativeWindowHandle)) { $enumerationError=$_.Exception.Message } }
                }
            }
        }
        catch { $enumerationError=$_.Exception.Message }
        if ($RequireComplete -and $enumerationError) {
            $failure=New-Object InvalidOperationException("Window enumeration was incomplete; absence is unproven. $enumerationError")
            $failure.Data['PotatoErrorType']='WindowEnumerationIncomplete'
            throw $failure
        }
        $seenWindows=New-Object 'Collections.Generic.HashSet[string]'
        $windows=@($windows | Where-Object {
            $key=Get-PotatoElementIdentityKey $_
            if (-not $key) {
                try {if ($_.Current.NativeWindowHandle) {$key="$($_.Current.ProcessId):$($_.Current.NativeWindowHandle)"}} catch { }
            }
            -not $key -or $seenWindows.Add($key)
        })
        if ($windows.Count -gt 0 -or $TimeoutMs -le 0) { return $windows }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $stopAt)

    return @()
}

function Wait-PotatoProcessWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process] $Process,

        [int] $TimeoutMs = 15000,
        [Parameter(Mandatory)] [string] $ExpectedProcessName,
        [int[]] $ExcludedProcessIds = @(),
        [datetime] $LaunchedAt = [datetime]::MinValue
    )

    $stopAt = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        try { $Process.Refresh() } catch {}
        if (-not $Process.HasExited -and $Process.MainWindowHandle -and $Process.MainWindowHandle.ToInt64() -ne 0) {
            try {
                $candidate = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
                if (Test-PotatoLaunchedWindow $candidate $ExpectedProcessName $ExcludedProcessIds $LaunchedAt) { return $candidate }
            }
            catch {}
        }
        $selector = [ordered]@{
            ProcessName = $ExpectedProcessName
            ControlType = 'Window'
            Recurse = $false
            FindFirst = $true
        }
        $window = @(Get-PotatoTopLevelWindows -Selector $selector -TimeoutMs 100) | Where-Object { Test-PotatoLaunchedWindow $_ $ExpectedProcessName $ExcludedProcessIds $LaunchedAt } | Select-Object -First 1
        if ($window) { return $window }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $stopAt)

    return $null
}

function Test-PotatoLaunchedWindow {
    param($Element, [string]$ExpectedProcessName, [int[]]$ExcludedProcessIds, [datetime]$LaunchedAt)
    if (-not $Element -or -not $ExpectedProcessName) { return $false }
    try {
        $windowPid = [int]$Element.Current.ProcessId
        if ($windowPid -le 0 -or $ExcludedProcessIds -contains $windowPid) { return $false }
        $candidateProcess = Get-Process -Id $windowPid -ErrorAction Stop
        return $candidateProcess.ProcessName -eq $ExpectedProcessName -and ($LaunchedAt -eq [datetime]::MinValue -or $candidateProcess.StartTime -ge $LaunchedAt.AddSeconds(-1))
    } catch { return $false }
}

function Invoke-PotatoStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $processName = Get-PotatoArg -ArgsMap $ArgsMap -Names @('ProcessName', 'FilePath', 'Path')
    if (-not $processName -and $ArgsMap._.Count -gt 0) { $processName = $ArgsMap._[0] }
    if (-not $processName) { throw 'start requires -ProcessName, -FilePath, or a positional process name.' }

    $arguments = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Arguments', 'ArgumentList') -Default ''
    if ($arguments -is [bool]) { throw 'Arguments requires a literal value. For a value beginning with a dash use -Arguments=<value> as one argument token.' }
    $killExisting = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('KillExisting')) $false
    $timeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('WaitForWindowMs', 'TimeoutMs')) 15000
    $maximize = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Maximize', 'MaximizeWindow')) $false

    $filePath = ''
    $targetProcessName = [System.IO.Path]::GetFileName([string]$processName) -replace '(?i)\.exe$', ''
    if (Test-Path -LiteralPath $processName) {
        $filePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($processName)
        $targetProcessName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    }

    $requireNew = ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('RequireNewProcess')) $false
    $requireWindow = ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('RequireNewWindow')) $false
    if ($requireWindow -and ($requireNew -or $killExisting)) { throw 'RequireNewWindow cannot be combined with RequireNewProcess or KillExisting.' }
    if ($requireWindow) {
        return Invoke-PotatoStartWindow $ArgsMap $(if ($filePath) {$filePath} else {$processName}) $arguments $targetProcessName $timeoutMs $maximize
    }
    $priorExitWaitMs = ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('WaitForPreviousExitMs')) 3000
    if ($priorExitWaitMs -lt 0 -or $priorExitWaitMs -gt 60000) { throw 'WaitForPreviousExitMs must be between 0 and 60000.' }
    $existingIds = @(Get-Process -Name $targetProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($requireNew -and $existingIds.Count) {
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while ($existingIds.Count -and $wait.ElapsedMilliseconds -lt $priorExitWaitMs) {
            Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Max(1, $priorExitWaitMs - $wait.ElapsedMilliseconds)))
            $existingIds = @(Get-Process -Name $targetProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        }
        if ($existingIds.Count) { throw 'Application is already running. Use a clean test session; do not reuse an unrelated document.' }
    }
    if ($killExisting) {
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -eq $targetProcessName -or ($filePath -and $_.Path -eq $filePath) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $startParams = @{ FilePath = $(if ($filePath) { $filePath } else { $processName }); PassThru = $true }
    if ($arguments) { $startParams.ArgumentList = $arguments }
    $launchedAt = Get-Date
    $started = Start-Process @startParams
    # A windowless/failed handoff must not leave an earlier application as the
    # text-input target of this successful launch command.
    $script:CurrentState.working = $null
    Save-PotatoState -State $script:CurrentState
    $launchWatch = [Diagnostics.Stopwatch]::StartNew()
    $window = $null
    $working = $null
    do {
        $remainingMs = [int][Math]::Max(0, $timeoutMs - $launchWatch.ElapsedMilliseconds)
        $candidate = Wait-PotatoProcessWindow -Process $started -TimeoutMs $remainingMs -ExpectedProcessName $targetProcessName -ExcludedProcessIds $existingIds -LaunchedAt $launchedAt
        if (-not $candidate) { break }
        try { $working = Set-PotatoWorkingWindow -Element $candidate; $window = $candidate }
        catch { Write-PotatoLog -Level Warning -Message $_.Exception.Message }
        if ($working) { break }
        if ($launchWatch.ElapsedMilliseconds -lt $timeoutMs) { Start-Sleep -Milliseconds 50 }
    } while ($launchWatch.ElapsedMilliseconds -lt $timeoutMs)
    if ($working) { [void](Show-PotatoWindow -Handle $working.nativeWindowHandle -Maximize:$maximize) }

    $ownedProcessId = $null
    $startedId = [int]$started.Id
    if ($startedId -gt 0 -and $existingIds -notcontains $startedId) { $ownedProcessId = $startedId }
    if ($window) {
        $windowProcessId = [int]$working.processId
        if ($windowProcessId -gt 0 -and $existingIds -notcontains $windowProcessId) { $ownedProcessId = $windowProcessId }
    }
    if ($requireNew -and -not $ownedProcessId -and $startedId -gt 0) { $ownedProcessId = $startedId }
    if ($requireNew -and -not $ownedProcessId) { throw 'New-process launch returned no process ID for scoped cleanup.' }

    [ordered]@{
        process = [ordered]@{
            id = $started.Id
            processName = $targetProcessName
            started = $true
        }
        working = $working
        windowFound = [bool]$window
        ownedProcessId = $ownedProcessId
    }
}

function Invoke-PotatoFocus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $selector = New-PotatoSelectorFromArguments -ArgsMap $ArgsMap
    $selector.Recurse = $false
    $selector.FindFirst = $false
    $timeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('TimeoutMs', 'MillisecondsToWait')) 5000
    $maximize = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Maximize', 'MaximizeWindow')) $false

    if ($selector.WindowTitle -and -not $selector.Name) { $selector.Name = $selector.WindowTitle }
    $processId = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('ProcessId')) 0
    $ticketJson=Get-PotatoArg $ArgsMap @('WindowIdentityJson')
    $checkpointId=Get-PotatoArg $ArgsMap @('SinceCheckpoint')
    if ($ticketJson -and $checkpointId) { throw 'Use WindowIdentityJson or SinceCheckpoint, not both.' }
    $checkpoint=if ($checkpointId) { Get-PotatoWindowCheckpoint $checkpointId }
    if ($checkpoint) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do {
            $windows=@(Get-PotatoTopLevelWindows -Selector $selector -TimeoutMs 0 | Where-Object {$checkpoint.handles -notcontains [long]$_.Current.NativeWindowHandle})
            if ($windows.Count -or $watch.ElapsedMilliseconds -ge $timeoutMs) {break}
            Start-Sleep -Milliseconds 100
        } while ($true)
    } else {
        $windows = if ($ticketJson) { @(Get-PotatoTicketWindow $ticketJson | Where-Object {$_}) } else { @(Get-PotatoTopLevelWindows -Selector $selector -TimeoutMs $timeoutMs) }
    }
    if ($processId -gt 0) { $windows = @($windows | Where-Object { $_.Current.ProcessId -eq $processId }) }
    $window = $windows | Select-Object -First 1
    if (-not $window) { throw 'No matching top-level window was found.' }
    if ($windows.Count -gt 1) { throw 'More than one top-level window matches. Narrow the observed selector or use WindowIdentityJson.' }

    $working = Set-PotatoWorkingWindow -Element $window
    $working['windowScoped']=$true
    Save-PotatoState $script:CurrentState
    [void](Show-PotatoWindow -Handle $working.nativeWindowHandle -Maximize:$maximize)
    [ordered]@{ working = $working; ownedWindow=$(if ($checkpoint) {New-PotatoOwnedWindow $working} else {$null}) }
}

function Invoke-PotatoWindows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $selector = New-PotatoSelectorFromArguments -ArgsMap $ArgsMap
    $selector.Recurse = $false
    $timeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('TimeoutMs')) 0
    $ticketJson=Get-PotatoArg $ArgsMap @('WindowIdentityJson')
    $foreground=ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('Foreground')) $false
    $checkpointRequested=ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('Checkpoint')) $false
    $waitForNotExists=ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('WaitForNotExists')) $false
    if ($timeoutMs -lt 0 -or $timeoutMs -gt 60000) { throw 'Windows TimeoutMs must be 0..60000.' }
    if ($waitForNotExists -and ($foreground -or $checkpointRequested -or -not ($ticketJson -or $selector.Name -or $selector.WindowTitle -or $selector.AutomationId -or $selector.ClassName -or $selector.ProcessName -or $selector.ProcessId))) {
        throw 'WaitForNotExists requires an explicit window selector or WindowIdentityJson; it cannot combine with Foreground or Checkpoint.'
    }
    if ($foreground -and ($ticketJson -or $checkpointRequested)) { throw 'Foreground cannot be combined with WindowIdentityJson or Checkpoint.' }
    $checkpoint=if ($checkpointRequested) {New-PotatoWindowCheckpoint}
    $windows = @()
    if ($waitForNotExists) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do {
            $windows=@(if ($ticketJson) {Get-PotatoTicketWindow $ticketJson | Where-Object {$_}}
                else {Get-PotatoTopLevelWindows -Selector $selector -TimeoutMs 0 -RequireComplete})
            if (-not $windows.Count -or $watch.ElapsedMilliseconds -ge $timeoutMs) {break}
            Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(50,$timeoutMs-$watch.ElapsedMilliseconds)))
        } while ($true)
    }
    elseif ($foreground) {
        Initialize-PotatoWindowIdentity
        if ($timeoutMs -lt 0 -or $timeoutMs -gt 60000) { throw 'Foreground TimeoutMs must be 0..60000.' }
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do {
            $handle=[PotatoWindowIdentity]::ForegroundRoot()
            $windows=@(if ($handle -ne [IntPtr]::Zero) {
                $candidate=[Windows.Automation.AutomationElement]::FromHandle($handle)
                if (Test-PotatoElementMatch $candidate $selector) { $candidate }
            })
            if ($windows.Count -or $watch.ElapsedMilliseconds -ge $timeoutMs) { break }
            Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(50,$timeoutMs-$watch.ElapsedMilliseconds)))
        } while ($true)
    }
    elseif ($ticketJson) { $windows=@(Get-PotatoTicketWindow $ticketJson | Where-Object {$_}) }
    else { $windows=@(Get-PotatoTopLevelWindows -Selector $selector -TimeoutMs $timeoutMs) }
    $result=[ordered]@{
        count = $windows.Count
        windows = @($windows | ForEach-Object { ConvertTo-PotatoElementInfo -Element $_ })
        checkpointId = $(if ($checkpoint) {$checkpoint.id} else {$null})
        foregroundSelector = $(if ($foreground -and $windows.Count -eq 1) {
            @{Name=$windows[0].Current.Name;ClassName=$windows[0].Current.ClassName;ProcessId=$windows[0].Current.ProcessId}
        })
    }
    if ($waitForNotExists) {
        $result.waitForNotExists=$true
        $result.conditionMet=$windows.Count -eq 0
        $result.timedOut=-not $result.conditionMet
    }
    $result
}

function Get-PotatoForegroundWindowInfo {
    [CmdletBinding()]
    param()

    try {
        $element = [System.Windows.Automation.AutomationElement]::FocusedElement
        if (-not $element) { return $null }
        return ConvertTo-PotatoElementInfo -Element $element
    }
    catch {
        return $null
    }
}

function ConvertTo-PotatoTreeNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element,

        [int] $Depth = 2,

        [ref] $Remaining,
        [ref] $DepthBoundaryReached,
        [Collections.Generic.HashSet[string]] $Seen
    )

    if ($null -eq $Seen) { $Seen=New-Object 'Collections.Generic.HashSet[string]' }
    $identity=Get-PotatoElementIdentityKey $Element
    if ($identity -and -not $Seen.Add($identity)) { return $null }
    if ($Remaining.Value -le 0) { return $null }
    $Remaining.Value--
    $info = ConvertTo-PotatoElementInfo -Element $Element -Snapshot
    $node = [ordered]@{
        element = $info
        children = @()
    }

    if ($Depth -le 0 -or $Remaining.Value -le 0) {
        if ($Depth -le 0 -and $DepthBoundaryReached) { $DepthBoundaryReached.Value=$true }
        return $node
    }

    try {
        $children = $Element.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($child in $children) {
            if ($Remaining.Value -le 0) { break }
            $childNode = ConvertTo-PotatoTreeNode -Element $child -Depth ($Depth - 1) -Remaining $Remaining -DepthBoundaryReached $DepthBoundaryReached -Seen $Seen
            if ($childNode) { $node.children += $childNode }
        }
    }
    catch {}
    return $node
}

function Invoke-PotatoObserve {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $depth = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Depth')) 2
    $maxElements = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('MaxElements')) 200
    if ($depth -lt 0 -or $depth -gt 20 -or $maxElements -lt 1 -or $maxElements -gt 2000) { throw 'Observe Depth must be 0..20 and MaxElements 1..2000.' }
    $format = [string](Get-PotatoArg $ArgsMap @('Format') 'Full')
    if ($format -notin @('Full','Compact')) { throw 'Observe Format must be Full or Compact.' }
    $working = Get-PotatoWorkingElement
    $root = Get-PotatoExplicitScope $ArgsMap
    if (-not $root) { $root=$working }
    $inputs=Get-PotatoSelectorInputs $ArgsMap
    $hasSelector=$inputs.path -or $inputs.selector.Name -or $inputs.selector.AutomationId -or $inputs.selector.ClassName -or $inputs.selector.ControlType -or $inputs.selector.ProcessName -or $inputs.selector.ProcessId -or $inputs.selector.WindowTitle
    if ($hasSelector -and -not (-not $inputs.path -and $root -and (Test-PotatoElementMatch $root $inputs.selector))) {
        $target=Resolve-PotatoCommandTarget -ArgsMap $ArgsMap -AllowPathAsTarget
        if (-not $target.ok) {
            $failure=New-Object InvalidOperationException("$($target.error) Observation selectors stay inside their scope; use guarded ForegroundWindow for an observed external dialog.")
            $failure.Data['PotatoErrorType']='TargetNotFound'; $failure.Data['NoInputSent']=$true
            throw $failure
        }
        $root=$target.element
    }
    if ($format -eq 'Compact') {
        $remaining=[ref]$maxElements
        $depthBoundary=[ref]$false
        $tree = if ($root) { ConvertTo-PotatoTreeNode $root -Depth $depth -Remaining $remaining -DepthBoundaryReached $depthBoundary }
        return [ordered]@{scope=(Get-PotatoArg $ArgsMap @('Scope') 'Working');
            root=$(if ($tree) { $tree.element });
            focusedElement=(ConvertTo-PotatoCompactElement (Get-PotatoForegroundWindowInfo));
            keyboardFocus=(Get-PotatoNativeInputState);
            elements=@(Get-PotatoCompactElements $tree); limitReached=($remaining.Value -le 0);
            depthBoundaryReached=$depthBoundary.Value;
            hint='Selectors are candidates; boundaries can hide descendants. Scope deeper discovery before coordinates. Opaque Pane roles may change. Use click Auto, selector type for Edit, observed focused typing for canvases; multiline needs Document. Inspect screenshots before coordinates.'}
    }
    $windows = @(Get-PotatoTopLevelWindows)
    $workingInfo = $null
    $tree = $null
    if ($working) {
        $workingInfo = ConvertTo-PotatoElementInfo -Element $working
        $remaining = [ref]$maxElements
        $tree = ConvertTo-PotatoTreeNode -Element $root -Depth $depth -Remaining $remaining
    }

    $blocking = @()
    foreach ($window in $windows) {
        $info = ConvertTo-PotatoElementInfo -Element $window
        $sameProcess = $workingInfo -and $info.processId -eq $workingInfo.processId
        $looksModal = $info.className -eq '#32770' -or $info.localizedControlType -match 'dialog' -or $info.controlType -eq 'Window'
        if ($sameProcess -and $looksModal -and $info.nativeWindowHandle -ne $workingInfo.nativeWindowHandle) {
            $blocking += $info
        }
    }

    [ordered]@{
        working = $workingInfo
        foreground = Get-PotatoForegroundWindowInfo
        keyboardFocus = Get-PotatoNativeInputState
        windows = @($windows | ForEach-Object { ConvertTo-PotatoElementInfo -Element $_ })
        likelyBlockingWindows = $blocking
        tree = $tree
    }
}

function Resolve-PotatoCommandTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap,

        [switch] $AllowPathAsTarget
    )

    $inputs = Get-PotatoSelectorInputs -ArgsMap $ArgsMap
    $path = $inputs.path
    $selector = $inputs.selector
    $parent = $null
    $scopeRoot = Get-PotatoExplicitScope $ArgsMap
    if (-not $scopeRoot -and $selector.ModalOnly) { $scopeRoot=Get-PotatoRootElement }
    $unique=ConvertTo-PotatoBool (Get-PotatoArg $ArgsMap @('RequireUnique')) $false
    $pathResult = Resolve-PotatoSelectorPath -Path $path -StartParent $scopeRoot -RequireUnique:$unique
    if (-not $pathResult.ok) {
        return [ordered]@{ ok = $false; error = "Selector path failed at index $($pathResult.failedIndex)."; element = $null; selector = $selector }
    }
    $parent = $pathResult.element

    $hasSimpleSelector = $selector.Name -or $selector.AutomationId -or $selector.ClassName -or $selector.ControlType -or $selector.ProcessName -or $selector.ProcessId -or $selector.WindowTitle
    if ($AllowPathAsTarget -and -not $hasSimpleSelector -and $path) {
        return [ordered]@{ ok = $true; element = $parent; selector = $selector }
    }

    $refresh = -not $path -and -not $scopeRoot -and [bool]$script:CurrentState.working
    if ($unique) {
        # FindFirst in a selector must not silently override an explicit
        # cardinality check. Two matches suffice to reject before any input.
        $selector=Get-PotatoUniqueSelector $selector
        $matches=@(Find-PotatoElement -Selector $selector -Parent $parent -MaxResults 8 -TimeoutMs (ConvertTo-PotatoInt $selector.TimeoutMs 1000) -RefreshWorkingParent:$refresh)
        Assert-PotatoUniqueMatches $matches
        if (-not $matches.Count) { return @{ok=$false;error='No visible enabled element matches the selector.';element=$null;selector=$selector} }
        return @{ok=$true;element=$matches[0];selector=$selector}
    }
    $found = @(Find-PotatoElement -Selector $selector -Parent $parent -FindFirst -TimeoutMs (ConvertTo-PotatoInt $selector.TimeoutMs 1000) -RefreshWorkingParent:$refresh) | Select-Object -First 1
    if (-not $found) {
        return [ordered]@{ ok = $false; error = 'No matching element was found.'; element = $null; selector = $selector }
    }
    return [ordered]@{ ok = $true; element = $found; selector = $selector }
}

function Invoke-PotatoSelect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap,
        [switch] $PresenceOnly
    )

    $inputs = Get-PotatoSelectorInputs -ArgsMap $ArgsMap
    # A working window cannot be found by searching only its descendants.
    # Window queries also need to see sibling and owned dialog windows.
    $windowQuery = (-not $inputs.path) -and (([string]$inputs.selector.ControlType -eq 'Window') -or [bool]$inputs.selector.WindowTitle)
    $scopeRoot = Get-PotatoExplicitScope $ArgsMap
    if ($windowQuery -and -not $scopeRoot) {
        $maxResults=ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('MaxResults')) 20
        if ($maxResults -lt 1 -or $maxResults -gt 1000) { throw 'MaxResults must be 1..1000.' }
        if ($PresenceOnly) { $maxResults=1 }
        $windows=@(Get-PotatoTopLevelWindows $inputs.selector (ConvertTo-PotatoInt $inputs.selector.TimeoutMs 1000) | Select-Object -First $maxResults)
        return [ordered]@{count=$windows.Count;elements=@($windows | ForEach-Object {ConvertTo-PotatoElementInfo $_ -Snapshot})}
    }
    if (-not $scopeRoot -and ($inputs.selector.ModalOnly -or $windowQuery)) { $scopeRoot=Get-PotatoRootElement }
    $pathResult = Resolve-PotatoSelectorPath -Path $inputs.path -StartParent $scopeRoot
    if (-not $pathResult.ok) { throw "Selector path failed at index $($pathResult.failedIndex)." }

    $maxResults = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('MaxResults')) 20
    $selector = $inputs.selector
    $timeoutMs = ConvertTo-PotatoInt $selector.TimeoutMs 1000
    $findFirst = $PresenceOnly -or (ConvertTo-PotatoBool $selector.FindFirst $false)
    if ($maxResults -lt 1 -or $maxResults -gt 1000) { throw 'MaxResults must be 1..1000.' }
    $refresh = -not $inputs.path -and -not $scopeRoot -and [bool]$script:CurrentState.working
    $refreshFocus = -not $inputs.path -and (Get-PotatoArg $ArgsMap @('Scope') 'Working') -eq 'FocusedWindow'
    $foregroundSelector=if (-not $inputs.path -and (Get-PotatoArg $ArgsMap @('Scope')) -eq 'ForegroundWindow') {Get-PotatoArg $ArgsMap @('WindowSelectorJson')} else {$null}
    $includeRoot=(($refreshFocus -or $foregroundSelector) -and $windowQuery) -or
        ($PresenceOnly -and -not $inputs.path -and ($refresh -or $refreshFocus -or $foregroundSelector))
    $checkDialog=$PresenceOnly -and (Get-PotatoArg $ArgsMap @('Scope') 'Working') -eq 'Working'
    $elements = @(@(Find-PotatoElement -Selector $selector -Parent $pathResult.element -TimeoutMs $timeoutMs -FindFirst:$findFirst -MaxResults $maxResults -RefreshWorkingParent:$refresh -RefreshFocusedParent:$refreshFocus -ForegroundSelectorJson $foregroundSelector -IncludeRoot:$includeRoot -CheckBlockingDialog:$checkDialog) |
        Select-Object -First $maxResults)

    [ordered]@{
        count = $elements.Count
        elements = @($elements | ForEach-Object { ConvertTo-PotatoElementInfo -Element $_ })
    }
}

function Move-PotatoMouse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $X,

        [Parameter(Mandatory)]
        [int] $Y
    )

    if (-not (Initialize-PotatoNativeMouse)) { throw 'Native mouse input is not available in this PowerShell session.' }
    [PotatoMouseNative]::MoveTo($X,$Y)
}

function Invoke-PotatoMouseClick {
    [CmdletBinding()]
    param(
        [ValidateSet('Left', 'Right')]
        [string] $Button = 'Left'
    )

    if (-not (Initialize-PotatoNativeMouse)) {
        throw 'Native mouse input is not available in this PowerShell session.'
    }

    if ($Button -eq 'Right') {
        [PotatoMouseNative]::MouseEvent(0x0008, 0, 0, 0, 0)
        [PotatoMouseNative]::MouseEvent(0x0010, 0, 0, 0, 0)
    }
    else {
        [PotatoMouseNative]::MouseEvent(0x0002, 0, 0, 0, 0)
        [PotatoMouseNative]::MouseEvent(0x0004, 0, 0, 0, 0)
    }
}

function Invoke-PotatoElementDefaultAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element
    )

    # Fall back only when a pattern is absent. If an action throws after the
    # provider received it, another pattern or mouse click could double-act.
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return 'InvokePattern'
    }

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
        $pattern.Toggle()
        return 'TogglePattern'
    }

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        $pattern.Select()
        return 'SelectionItemPattern'
    }

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        if ($pattern.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
            $pattern.Expand()
        }
        else {
            $pattern.Collapse()
        }
        return 'ExpandCollapsePattern'
    }

    return $null
}

function Get-PotatoClickPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element,

        [bool] $Center = $false,

        [int] $OffsetX = 0,

        [int] $OffsetY = 0,

        [bool] $OffsetClickablePoint = $true,
        [Nullable[double]] $RelativeX = $null,
        [Nullable[double]] $RelativeY = $null
    )

    $clickable = $null
    try { $clickable = $Element.GetClickablePoint() } catch {}
    $rect = ConvertTo-PotatoRectangle $Element.Current.BoundingRectangle
    if (-not $rect) { throw 'Physical input requires finite, nonempty bounds.' }
    if ($null -ne $RelativeX -or $null -ne $RelativeY) {
        if ($null -eq $RelativeX -or $null -eq $RelativeY -or [double]::IsNaN($RelativeX) -or [double]::IsNaN($RelativeY) -or
            $RelativeX -lt 0 -or $RelativeX -gt 1 -or $RelativeY -lt 0 -or $RelativeY -gt 1) { throw 'RelativeX and RelativeY must both be finite fractions in 0..1.' }
        return [ordered]@{x=[int]($rect.x + [Math]::Round(($rect.width-1)*$RelativeX)); y=[int]($rect.y + [Math]::Round(($rect.height-1)*$RelativeY))}
    }
    if ($clickable -and ([double]::IsNaN($clickable.X) -or [double]::IsInfinity($clickable.X) -or [double]::IsNaN($clickable.Y) -or [double]::IsInfinity($clickable.Y))) { $clickable = $null }
    if ($Center -or -not $clickable) {
        $x = $rect.X + ($rect.Width / 2)
        $y = $rect.Y + ($rect.Height / 2)
    }
    else {
        $x = $clickable.X
        $y = $clickable.Y
    }

    if ($OffsetX -ne 0 -or $OffsetY -ne 0) {
        if ($OffsetClickablePoint -or -not $clickable) {
            $x += $OffsetX
            $y += $OffsetY
        }
        else {
            $x = $rect.X + $OffsetX
            $y = $rect.Y + $OffsetY
        }
    }

    if ($x -lt [int]::MinValue -or $x -gt [int]::MaxValue -or $y -lt [int]::MinValue -or $y -gt [int]::MaxValue) { throw 'Physical input point is out of range.' }
    [ordered]@{ x = [int][Math]::Round($x); y = [int][Math]::Round($y) }
}

function Invoke-PotatoClick {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    if (-not $ArgsMap.ContainsKey('RequireUnique')) { $ArgsMap.RequireUnique=$true }
    $target = Resolve-PotatoCommandTarget -ArgsMap $ArgsMap -AllowPathAsTarget
    if (-not $target.ok) {
        $failure=New-Object InvalidOperationException($target.error)
        $failure.Data['PotatoErrorType']='TargetNotFound'; $failure.Data['NoInputSent']=$true
        throw $failure
    }

    $method = [string](Get-PotatoArg -ArgsMap $ArgsMap -Names @('Method') -Default 'Auto')
    if ($method -notin @('Auto', 'Mouse', 'Invoke')) { throw 'click -Method must be Auto, Mouse, or Invoke.' }
    # Read evidence before acting: invoking a dialog button may destroy it.
    $elementInfo = ConvertTo-PotatoElementInfo -Element $target.element
    if (-not $elementInfo.isEnabled) { throw 'The target element is disabled.' }
    # Win32 button proxies invoke via synchronous BM_CLICK. A handler that calls
    # COM (for example a common file dialog) can then fail with 0x8001010D.
    # Choose physical input BEFORE dispatch, by control semantics, never caption.
    $nativeButton = $elementInfo.controlType -eq 'Button' -and $elementInfo.nativeWindowHandle -and
        $elementInfo.supportedPatterns -contains 'Invoke'
    # Validate explicit Invoke BEFORE SetFocus: focusing a list item can select
    # it, so a rejected method must not silently change the application state.
    $invokePattern = $null
    if ($method -eq 'Invoke' -and -not $target.element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        throw ('InvokePattern is unavailable on this control. Use -Method Auto to choose a supported UIA action or visible mouse click. Supported patterns: ' + ($elementInfo.supportedPatterns -join ', '))
    }
    # Invoke/select/toggle do not require refocusing. Focusing the parent or a
    # popup item first can dismiss menus or change the selection before clicking.
    $focus = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Focus')) $false
    $elementFocus = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('ElementFocus')) $false
    $center = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Center')) $false
    $button = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Button') -Default 'Left'
    $offsetX = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('OffsetX')) 0
    $offsetY = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('OffsetY')) 0
    $offsetClickablePoint = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('OffsetClickablePoint')) $true
    $relative = $ArgsMap.ContainsKey('RelativeX') -or $ArgsMap.ContainsKey('RelativeY')
    if ($relative) {
        if (-not $ArgsMap.ContainsKey('RelativeX') -or -not $ArgsMap.ContainsKey('RelativeY') -or $offsetX -ne 0 -or $offsetY -ne 0 -or $center -or $method -eq 'Invoke') { throw 'Relative clicks need RelativeX and RelativeY without offsets, Center, or Invoke.' }
        # Validate geometry and fractions before moving focus or dispatching input.
        [void](Get-PotatoClickPoint -Element $target.element -RelativeX ([double]$ArgsMap.RelativeX) -RelativeY ([double]$ArgsMap.RelativeY))
    }

    if ($focus) {
        $working = Get-PotatoWorkingElement
        if ($working) { [void](Show-PotatoWindow -Handle $working.Current.NativeWindowHandle) }
    }
    if ($elementFocus) {
        try { $target.element.SetFocus() } catch {}
    }

    $action = $null
    if ((Get-PotatoArg $ArgsMap @('Scope')) -eq 'ForegroundWindow') { Assert-PotatoGuardedTarget $target.element $ArgsMap }
    if ($method -eq 'Invoke') {
        $invokePattern.Invoke()
        $action = 'InvokePattern'
    }
    elseif ($method -eq 'Auto' -and -not $nativeButton -and $button -eq 'Left' -and $offsetX -eq 0 -and $offsetY -eq 0 -and -not $center -and -not $relative) {
        $action = Invoke-PotatoElementDefaultAction -Element $target.element
    }
    $point = $null
    if (-not $action) {
        if ($elementInfo.isOffscreen -or $elementInfo.boundingRectangle.width -le 0 -or $elementInfo.boundingRectangle.height -le 0) {
            throw 'Mouse click requires a visible, nonempty target rectangle.'
        }
        if (-not $ArgsMap.ContainsKey('Focus') -and (Get-PotatoArg $ArgsMap @('Scope')) -ne 'ForegroundWindow') {
            $node=$target.element
            for ($i=0;$i -lt 32 -and $node;$i++) {
                if ($node.Current.NativeWindowHandle) {
                    Initialize-PotatoWindowIdentity
                    $targetRoot=[PotatoWindowIdentity]::Root([IntPtr]$node.Current.NativeWindowHandle)
                    $foreground=[PotatoWindowIdentity]::ForegroundRoot()
                    if ($targetRoot -ne $foreground -and -not [PotatoWindowIdentity]::IsOwnedBy($targetRoot,$foreground) -and -not [PotatoWindowIdentity]::IsOwnedBy($foreground,$targetRoot)) {
                        [void](Show-PotatoWindow -Handle $targetRoot.ToInt64())
                    }
                    break
                }
                $node=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($node)
            }
        }
        if ($relative) { $point = Get-PotatoClickPoint -Element $target.element -RelativeX ([double]$ArgsMap.RelativeX) -RelativeY ([double]$ArgsMap.RelativeY) }
        else { $point = Get-PotatoClickPoint -Element $target.element -Center $center -OffsetX $offsetX -OffsetY $offsetY -OffsetClickablePoint $offsetClickablePoint }
        if ((Get-PotatoArg $ArgsMap @('Scope')) -eq 'ForegroundWindow') { Assert-PotatoGuardedTarget $target.element $ArgsMap }
        Move-PotatoMouse -X $point.x -Y $point.y
        Invoke-PotatoMouseClick -Button $button
        $action = 'Mouse'
    }

    $verifyDisappeared = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('VerifyDisappeared')) $false
    $verified = $null
    if ($verifyDisappeared) {
        Start-Sleep -Milliseconds 500
        $matches = @(Find-PotatoElement -Selector $target.selector -TimeoutMs 1000 -FindFirst)
        $verified = ($matches.Count -eq 0)
    }

    $script:CurrentState.lastAction = [ordered]@{ command = 'click'; ok = ($verified -ne $false); timestamp = (Get-Date).ToString('o') }
    Save-PotatoState -State $script:CurrentState

    [ordered]@{
        clicked = $true
        verified = $verified
        verificationPerformed = $verifyDisappeared
        action = $action
        point = $point
        element = $elementInfo
    }
}

function Invoke-PotatoClickCoordinate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $x = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('X', 'x')) ([int]::MinValue)
    $y = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Y', 'y')) ([int]::MinValue)
    if ($x -eq [int]::MinValue -or $y -eq [int]::MinValue) { throw 'click-coordinate requires -X and -Y.' }
    $button = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Button') -Default 'Left'
    Move-PotatoMouse -X $x -Y $y
    $action = 'Mouse'
    try {
        Invoke-PotatoMouseClick -Button $button
    }
    catch {
        if ($button -ne 'Left') { throw }
        $point = New-Object System.Windows.Point($x, $y)
        $element = [System.Windows.Automation.AutomationElement]::FromPoint($point)
        $action = Invoke-PotatoElementDefaultAction -Element $element
        if (-not $action) { throw }
    }
    [ordered]@{ clicked = $true; point = [ordered]@{ x = $x; y = $y }; button = $button; action = $action }
}

function ConvertTo-PotatoLiteralKeys {
    param([AllowEmptyString()] [string] $Text)
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Text.Replace("`r`n", "`n").Replace("`r", "`n").ToCharArray()) {
        $token = [string]$character
        if ($token -eq "`n") { $token = '{ENTER}' }
        elseif ($token -eq "`t") { $token = '{TAB}' }
        elseif ('+^%~(){}[]'.Contains($token)) { $token = '{' + $token + '}' }
        [void]$builder.Append($token)
    }
    return $builder.ToString()
}

function Get-PotatoEditableText {
    param([Parameter(Mandatory)] [object] $Element)
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        return [string]$pattern.Current.Value
    }
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
        return [string]$pattern.DocumentRange.GetText(-1)
    }
    Initialize-PotatoWindowIdentity
    if ([PotatoWindowIdentity]::IsStandardEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId,$false)) {
        return [PotatoWindowIdentity]::ReadEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId)
    }
    throw 'Text verification requires ValuePattern, TextPattern or a standard Windows Edit control; its name is not text evidence.'
}

function Test-PotatoTypedTextMatch {
    param([string] $Actual, [string] $Expected,
          [ValidateSet('Exact','Contains','NormalizedExact','NormalizedContains')] [string] $Mode = 'Exact')
    if ($Mode -like 'Normalized*') {
        $Actual = $Actual.Replace("`r`n", "`n").Replace("`r", "`n").Replace([char]0x2028, "`n").Replace([char]0x2029, "`n")
        $Expected = $Expected.Replace("`r`n", "`n").Replace("`r", "`n").Replace([char]0x2028, "`n").Replace([char]0x2029, "`n")
    }
    if ($Mode -like '*Contains') { return $Actual.IndexOf($Expected, [StringComparison]::Ordinal) -ge 0 }
    return $Actual -ceq $Expected
}

function Wait-PotatoTypedText {
    param([object] $Element, [string] $Expected, [string] $Mode,
          [ValidateRange(0,60000)] [int] $TimeoutMs,
          [ValidateRange(0,1000)] [int] $MaxAttempts = 0)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    $lastLength = $null
    $lastReadError = $null
    do {
        $attempts++
        try {
            $actual = Get-PotatoEditableText -Element $Element
            $lastLength = $actual.Length
            $lastReadError = $null
            if (Test-PotatoTypedTextMatch -Actual $actual -Expected $Expected -Mode $Mode) {
                return [ordered]@{ verified=$true; attempts=$attempts; elapsedMs=$watch.ElapsedMilliseconds
                    mode=$Mode; observedLength=$lastLength; readError=$null }
            }
        }
        catch { $lastReadError = $_.Exception.Message }
        if (($MaxAttempts -gt 0 -and $attempts -ge $MaxAttempts) -or $watch.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Max(1, $TimeoutMs - $watch.ElapsedMilliseconds)))
    } while ($true)
    return [ordered]@{ verified=$false; attempts=$attempts; elapsedMs=$watch.ElapsedMilliseconds
        mode=$Mode; observedLength=$lastLength; readError=$lastReadError }
}

function Invoke-PotatoType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $text = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Text')
    if ($null -eq $text -and $ArgsMap._.Count -gt 0) { $text = $ArgsMap._[0] }
    if ($null -eq $text) { throw 'type requires -Text or a positional text value.' }

    $focus = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Focus')) $false
    $preDelete = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('PreDelete')) $false
    $verify = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Verify')) ([bool](Get-PotatoArg $ArgsMap @('PathKind')))
    $typeByCharacter = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('TypeByCharacter')) $false
    $inputDelayMs=ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('InputDelayMs')) $(if ($typeByCharacter) {50} else {5})
    if ($inputDelayMs -lt 0 -or $inputDelayMs -gt 100 -or ($typeByCharacter -and $ArgsMap.ContainsKey('InputDelayMs'))) { throw 'InputDelayMs must be 0..100; do not combine it with the legacy TypeByCharacter flag.' }
    $useWildcard = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('UseWildcardForVerify')) $false
    $verifyMode = [string](Get-PotatoArg -ArgsMap $ArgsMap -Names @('VerifyMode') -Default $(if ($useWildcard) { 'Contains' } else { 'Exact' }))
    if ($verifyMode -notin @('Exact','Contains','NormalizedExact','NormalizedContains')) { throw 'VerifyMode must be Exact, Contains, NormalizedExact, or NormalizedContains.' }
    $verifyTimeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('VerifyTimeoutMs')) 3000
    if ($verifyTimeoutMs -lt 0 -or $verifyTimeoutMs -gt 60000) { throw 'VerifyTimeoutMs must be between 0 and 60000.' }
    $maxAttempts = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('MaxAttempts')) 0
    if ($maxAttempts -lt 0 -or $maxAttempts -gt 1000) { throw 'MaxAttempts must be between 0 and 1000; 0 uses the verification deadline.' }
    $requestedFocusMethod = [string](Get-PotatoArg -ArgsMap $ArgsMap -Names @('FocusMethod') -Default 'Auto')
    if ($requestedFocusMethod -notin @('Auto','UIA','Mouse')) { throw 'FocusMethod must be Auto, UIA, or Mouse.' }
    $targetMode = [string](Get-PotatoArg $ArgsMap @('TargetMode') 'Writable')
    if ($targetMode -notin @('Writable','Focused')) { throw 'TargetMode must be Writable or Focused.' }
    $opaque = $targetMode -eq 'Focused'
    $expectedFocus=Get-PotatoArg $ArgsMap @('ExpectedFocusJson')
    if ($expectedFocus -and -not $opaque) { throw 'ExpectedFocusJson is for TargetMode Focused. Writable typing already resolves and focuses its selector.' }
    $hasTargetSelector = @('SelectorJson','PathJson','AutomationId','Name','ControlType','ClassName','Class','WindowTitle') | Where-Object { $ArgsMap.ContainsKey($_) }
    if ($opaque -and ($hasTargetSelector -or $focus -or $requestedFocusMethod -ne 'Auto')) { throw 'TargetMode Focused preserves existing focus: no selector, Focus, or FocusMethod override. PreDelete requires supported text selection.' }
    try { if (-not $script:InputScope) { [void](Get-PotatoWorkingElement -Required) } }
    catch {
        if ($opaque) { throw (New-PotatoFocusFailure $_.Exception.Message (Get-PotatoNativeInputState)) }
        throw
    }

    if ($focus) {
        $working = Get-PotatoWorkingElement
        if ($working) { [void](Show-PotatoWindow -Handle $working.Current.NativeWindowHandle) }
    }

    $inputFocus=$null
    if ($opaque) {
        $inputFocus=Wait-PotatoInputFocus $expectedFocus (ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('FocusTimeoutMs')) 2000)
        $element=$inputFocus.element
    } else { $element = [System.Windows.Automation.AutomationElement]::FocusedElement }
    $usedFocusMethod = 'ExistingFocus'
    if ($hasTargetSelector) {
        $target = Resolve-PotatoCommandTarget -ArgsMap $ArgsMap -AllowPathAsTarget
        if (-not $target.ok) {
            $failure=New-Object InvalidOperationException($target.error)
            $failure.Data['PotatoErrorType']='TargetNotFound'; $failure.Data['NoInputSent']=$true
            throw $failure
        }
        $element = $target.element
        Assert-PotatoTextTarget -Element $element -Text ([string]$text) -RequireFocus:$false
        if ($requestedFocusMethod -ne 'Mouse') {
            try { $element.SetFocus() } catch { if ($requestedFocusMethod -eq 'UIA') { throw } }
            $usedFocusMethod = 'UIA'
        }
        if ($requestedFocusMethod -eq 'Mouse' -or ($requestedFocusMethod -eq 'Auto' -and -not $element.Current.HasKeyboardFocus)) {
            if ($element.Current.IsOffscreen) { throw 'Mouse focus requires a visible text control.' }
            $working = if (-not $script:InputScope) {Get-PotatoWorkingElement}
            if ($working) { [void](Show-PotatoWindow -Handle $working.Current.NativeWindowHandle) }
            $point = Get-PotatoClickPoint -Element $element
            Move-PotatoMouse -X $point.x -Y $point.y
            Invoke-PotatoMouseClick -Button 'Left'
            $usedFocusMethod = 'Mouse'
        }
    }
    elseif ($requestedFocusMethod -ne 'Auto') { throw 'FocusMethod UIA or Mouse requires an explicit text target selector.' }
    $expectedProcessId = ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('ProcessId')) 0
    if ($expectedProcessId -and $element.Current.ProcessId -ne $expectedProcessId) { throw 'Focused element does not match the requested ProcessId.' }
    Assert-PotatoTextTarget -Element $element -Text ([string]$text) -AllowOpaque:$opaque -RequireFocus:$false
    if ($opaque) { Assert-PotatoInputFocusUnchanged $inputFocus } else { Assert-PotatoForegroundInput $element }
    $targetInfo = ConvertTo-PotatoElementInfo $element
    $clearMethod = [string](Get-PotatoArg -ArgsMap $ArgsMap -Names @('ClearMethod') -Default 'Selection')
    if ($clearMethod -notin @('Selection', 'Shortcut')) { throw 'ClearMethod must be Selection or Shortcut.' }
    if ($verify) { [void](Get-PotatoEditableText -Element $element) }
    $clearInputSent=$false
    if ($preDelete) {
        $cleared=Clear-PotatoEditableText -Element $element -Method $clearMethod
        $clearMethod=$cleared.method
        $clearInputSent=$cleared.inputSent
    }

    if (-not ('PotatoLiteralInput' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'LiteralInput.cs') }
    try {
        if ($opaque) { Assert-PotatoInputFocusUnchanged $inputFocus }
        else { Assert-PotatoForegroundInput $element -NoInputSent:(-not $clearInputSent) }
    } catch {
        if ($clearInputSent) { $_.Exception.Data['NoInputSent']=$false }
        throw
    }
    $native=Get-PotatoNativeInputState
    if (-not $native.ready) {
        $failure=New-PotatoFocusFailure 'Native keyboard target is not ready. No text was sent; inspect error.focus before retrying.' $native
        $failure.Data['NoInputSent']=-not $clearInputSent
        throw $failure
    }
    [PotatoLiteralInput]::SendText([string]$text,$inputDelayMs,[long]$native.foregroundHandle,[long]$native.focusHandle)
    $typedOk = $null
    $verification = $null
    if ($verify) {
        $verification = Wait-PotatoTypedText -Element $element -Expected ([string]$text) -Mode $verifyMode -TimeoutMs $verifyTimeoutMs -MaxAttempts $maxAttempts
        $typedOk = [bool]$verification.verified
    }

    $script:CurrentState.lastAction = [ordered]@{ command = 'type'; ok = ($typedOk -ne $false); timestamp = (Get-Date).ToString('o') }
    Save-PotatoState -State $script:CurrentState

    [ordered]@{ typed = $true; textLength = ([string]$text).Length; verified = $typedOk; verificationPerformed = $verify; verification = $verification; inputMethod = 'UnicodeKeyboard'; inputDelayMs=$inputDelayMs; focusMethod = $usedFocusMethod; targetMode=$targetMode; target=$targetInfo;
        inputFocus=$(if ($inputFocus) {@{source=$inputFocus.source;native=$inputFocus.native;waitMs=$inputFocus.waitMs}}); clearMethod = $(if ($preDelete) { $clearMethod } else { $null }) }
}

function Invoke-PotatoHotkey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $keys = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Keys', 'Text')
    if ($null -eq $keys -and $ArgsMap._.Count -gt 0) { $keys = $ArgsMap._[0] }
    if ($null -eq $keys) { throw 'hotkey requires -Keys or a positional SendKeys expression.' }
    $focus = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Focus')) $false
    if ($focus) {
        $working = Get-PotatoWorkingElement
        if ($working) { [void](Show-PotatoWindow -Handle $working.Current.NativeWindowHandle) }
    }
    [System.Windows.Forms.SendKeys]::SendWait([string]$keys)
    [ordered]@{ sent = $true; keys = [string]$keys }
}

function Move-PotatoMouseSmooth {
    [CmdletBinding()]
    param(
        [int] $StartX,
        [int] $StartY,
        [int] $EndX,
        [int] $EndY,
        [int] $DurationMs = 300
    )

    [PotatoMouseNative]::MoveSmooth($StartX,$StartY,$EndX,$EndY,$DurationMs)
}

function Resolve-PotatoDragEndpoint {
    param([hashtable]$ArgsMap, [ValidateSet('Source','Target')][string]$Endpoint)
    $selectorKey=$Endpoint+'SelectorJson'
    $xKey=if ($Endpoint -eq 'Source') {'StartX'} else {'EndX'}
    $yKey=if ($Endpoint -eq 'Source') {'StartY'} else {'EndY'}
    if ($ArgsMap.ContainsKey($selectorKey)) {
        if ($ArgsMap.ContainsKey($xKey) -or $ArgsMap.ContainsKey($yKey)) { throw "Use either $selectorKey or $xKey/$yKey, not both." }
        $target=Resolve-PotatoCommandTarget -ArgsMap @{SelectorJson=$ArgsMap[$selectorKey]} -AllowPathAsTarget
        if (-not $target.ok) {
            $failure=New-Object InvalidOperationException("$Endpoint drag selector failed: $($target.error)")
            $failure.Data['PotatoErrorType']='TargetNotFound';$failure.Data['NoInputSent']=$true
            throw $failure
        }
        $info=ConvertTo-PotatoElementInfo $target.element
        if (-not $info.isEnabled -or $info.isOffscreen) { throw "$Endpoint drag element must be enabled and visible." }
        $rx=Get-PotatoArg $ArgsMap @($Endpoint+'RelativeX') 0.5
        $ry=Get-PotatoArg $ArgsMap @($Endpoint+'RelativeY') 0.5
        $point=Get-PotatoClickPoint $target.element -RelativeX ([double]$rx) -RelativeY ([double]$ry)
        return @{point=$point;element=$info}
    }
    if ($ArgsMap.ContainsKey($Endpoint+'RelativeX') -or $ArgsMap.ContainsKey($Endpoint+'RelativeY')) { throw "$Endpoint relative coordinates require $selectorKey." }
    $x=ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @($xKey)) ([int]::MinValue)
    $y=ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @($yKey)) ([int]::MinValue)
    if ($x -eq [int]::MinValue -or $y -eq [int]::MinValue) { throw "drag requires $selectorKey or both $xKey and $yKey." }
    return @{point=@{x=$x;y=$y};element=$null}
}

function Invoke-PotatoDrag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    # Resolve and validate BOTH endpoints before pressing any mouse button.
    $source=Resolve-PotatoDragEndpoint $ArgsMap Source
    $destination=Resolve-PotatoDragEndpoint $ArgsMap Target
    $startX=$source.point.x; $startY=$source.point.y
    $endX=$destination.point.x; $endY=$destination.point.y
    $smooth = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Smooth')) $true
    $durationMs=ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('DurationMs')) 300
    if ($durationMs -lt 50 -or $durationMs -gt 10000) { throw 'DurationMs must be 50..10000.' }
    if (-not (Initialize-PotatoNativeMouse)) {
        throw 'drag requires native mouse input, which is not available in this PowerShell session.'
    }
    Move-PotatoMouse -X $startX -Y $startY
    Start-Sleep -Milliseconds 50
    $pressed=$false
    try {
        [PotatoMouseNative]::MouseEvent(0x0002, 0, 0, 0, 0)
        $pressed=$true
        Start-Sleep -Milliseconds 50
        if ($smooth) { Move-PotatoMouseSmooth -StartX $startX -StartY $startY -EndX $endX -EndY $endY -DurationMs $durationMs } else { Move-PotatoMouse -X $endX -Y $endY }
    } catch {
        if ($pressed) {
            $diagnostic=$_.Exception
            while (-not $diagnostic.Data['PotatoErrorType'] -and $diagnostic.InnerException) { $diagnostic=$diagnostic.InnerException }
            $diagnostic.Data['NoInputSent']=$false
        }
        throw
    } finally {
        # A provider/motion error must never leave the desktop mouse held down.
        if ($pressed) { [PotatoMouseNative]::MouseEvent(0x0004, 0, 0, 0, 0) }
    }
    [ordered]@{ dragged = $true; released=$true; verified=$null; verificationPerformed=$false;
        start=$source.point; end=$destination.point; source=$source.element; target=$destination.element; durationMs=$durationMs; smooth=$smooth }
}

function Invoke-PotatoHover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $xValue = Get-PotatoArg -ArgsMap $ArgsMap -Names @('X', 'x')
    $yValue = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Y', 'y')
    if ($null -ne $xValue -and $null -ne $yValue) {
        $point = [ordered]@{ x = (ConvertTo-PotatoInt $xValue 0); y = (ConvertTo-PotatoInt $yValue 0) }
    }
    else {
        $target = Resolve-PotatoCommandTarget -ArgsMap $ArgsMap -AllowPathAsTarget
        if (-not $target.ok) { throw $target.error }
        $point = Get-PotatoClickPoint -Element $target.element -Center $true
    }
    Move-PotatoMouse -X $point.x -Y $point.y
    [ordered]@{ hovered = $true; point = $point }
}

function Invoke-PotatoWaitElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    if ((Get-PotatoArg $ArgsMap @('Scope')) -in @('FocusedWindow','ForegroundWindow')) {
        $timeout=ConvertTo-PotatoInt (Get-PotatoArg $ArgsMap @('TimeoutMs','MillisecondsToWait')) 1000
        if ($timeout -lt 0 -or $timeout -gt 60000) {throw 'Scoped wait TimeoutMs must be 0..60000.'}
        $watch=[Diagnostics.Stopwatch]::StartNew(); $probe=$ArgsMap.Clone(); $probe.TimeoutMs=0
        $lastScopeError=$null
        do {
            try { $result=Invoke-PotatoSelect $probe -PresenceOnly; $lastScopeError=$null }
            catch {
                if ($_.Exception.Data['PotatoErrorType'] -ne 'ScopeNotReady') {throw}
                $lastScopeError=$_.Exception.Message; $result=@{count=0;elements=@()}
            }
            if ($result.count -gt 0 -or $watch.ElapsedMilliseconds -ge $timeout) {break}
            Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(100,$timeout-$watch.ElapsedMilliseconds)))
        } while ($true)
    } else { $result = Invoke-PotatoSelect -ArgsMap $ArgsMap -PresenceOnly }
    [ordered]@{
        exists = ($result.count -gt 0)
        count = $result.count
        elements = $result.elements
        lastScopeError = $lastScopeError
    }
}

function Invoke-PotatoWaitFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $path = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Path', 'FilePath')
    if ($null -eq $path -and $ArgsMap._.Count -gt 0) { $path = $ArgsMap._[0] }
    if (-not $path) { throw 'wait-file requires -Path or a positional path.' }
    $timeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('TimeoutMs', 'MillisecondsToWait')) 1000
    $waitForNotExists = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('WaitForNotExists')) $false
    $minBytes = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('MinBytes')) 0
    $stableMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('StableMs')) 0
    if ($timeoutMs -lt 0 -or $minBytes -lt 0 -or $stableMs -lt 0) { throw 'TimeoutMs, MinBytes and StableMs must be nonnegative.' }
    if ($waitForNotExists -and ($minBytes -gt 0 -or $stableMs -gt 0)) { throw 'WaitForNotExists cannot be combined with MinBytes or StableMs.' }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastSignature = $null
    $stableSince = 0L
    $conditionMet = $false
    $length = $null
    do {
        $exists = Test-Path -LiteralPath $path
        $length = $null
        if ($waitForNotExists) { $conditionMet = -not $exists }
        elseif ($exists) {
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                if (-not $item.PSIsContainer) {
                    $length = $item.Length
                    $signature = '{0}:{1}' -f $length, $item.LastWriteTimeUtc.Ticks
                    if ($signature -ne $lastSignature) { $lastSignature = $signature; $stableSince = $watch.ElapsedMilliseconds }
                    $conditionMet = ($length -ge $minBytes -and ($watch.ElapsedMilliseconds - $stableSince) -ge $stableMs)
                }
            }
            catch { $lastSignature = $null }
        }
        else { $lastSignature = $null }
        if ($conditionMet -or $watch.ElapsedMilliseconds -ge $timeoutMs) { break }
        Start-Sleep -Milliseconds ([Math]::Min(100, [Math]::Max(1, $timeoutMs - $watch.ElapsedMilliseconds)))
    } while ($true)

    [ordered]@{ path = [string]$path; exists = $exists; conditionMet = $conditionMet; length = $length; minBytes = $minBytes; stableMs = $stableMs; timedOut = (-not $conditionMet) }
}

function Get-PotatoElementText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Element,
        [switch] $WithSource
    )

    try {
        $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($valuePattern) {
            $value=$valuePattern.Current.Value
            if ($WithSource) { return @{text=$value;source='ValuePattern'} }; return $value
        }
    }
    catch {}
    try {
        $textPattern = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($textPattern) {
            $value=$textPattern.DocumentRange.GetText(-1)
            if ($WithSource) { return @{text=$value;source='TextPattern'} }; return $value
        }
    }
    catch {}
    Initialize-PotatoWindowIdentity
    if ([PotatoWindowIdentity]::IsStandardEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId,$false)) {
        $value=[PotatoWindowIdentity]::ReadEdit([IntPtr]$Element.Current.NativeWindowHandle,$Element.Current.ProcessId)
        if ($WithSource) {return @{text=$value;source='Win32Edit'}}; return $value
    }
    if ($WithSource) { return @{text=$Element.Current.Name;source='Name'} }; return $Element.Current.Name
}

function Invoke-PotatoRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $target = Resolve-PotatoCommandTarget -ArgsMap $ArgsMap -AllowPathAsTarget
    if (-not $target.ok) { throw $target.error }
    $readback = Get-PotatoElementText -Element $target.element -WithSource
    [ordered]@{
        text = $readback.text
        textSource = $readback.source
        element = ConvertTo-PotatoElementInfo -Element $target.element
    }
}

function New-PotatoScreenshot {
    [CmdletBinding()]
    param(
        [int] $X = 0,
        [int] $Y = 0,
        [int] $Width = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width,
        [int] $Height = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height,
        [string] $OutFile,
        [ValidateSet('PNG', 'JPEG', 'BMP', 'GIF', 'TIFF')]
        [string] $EncoderType = 'PNG',
        [int] $Quality = 80
    )

    $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $parent = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    $graphics = $null
    $encoderParams = $null
    try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $methodName = 'Copy' + 'FromScreen'
    $copyMethod = $graphics.GetType().GetMethod($methodName, [type[]]@([int], [int], [int], [int], [System.Drawing.Size]))
    [void]$copyMethod.Invoke($graphics, @($X, $Y, 0, 0, $bitmap.Size))
    $encoderTypeLower = $EncoderType.ToLower()
    $mime = "image/$encoderTypeLower"
    if ($encoderType -eq 'JPEG') { $mime = 'image/jpeg' }
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq $mime } | Select-Object -First 1
    if (-not $codec) { $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.FormatDescription -eq $EncoderType } | Select-Object -First 1 }
    $encoder = [System.Drawing.Imaging.Encoder]::Quality
    $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter($encoder, [int64]$Quality)
    $bitmap.Save($OutFile, $codec, $encoderParams)
    } finally {
        if ($encoderParams) { $encoderParams.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        $bitmap.Dispose()
    }
}

function Invoke-PotatoScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $encoder = Get-PotatoArg -ArgsMap $ArgsMap -Names @('EncoderType', 'Format') -Default 'PNG'
    $quality = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Quality')) 80
    $outFile = Get-PotatoArg -ArgsMap $ArgsMap -Names @('OutFile', 'Path')
    if (-not $outFile) {
        $name = 'screenshot_{0}.{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([string]$encoder).ToLower()
        $outFile = Join-Path -Path (Join-Path (Get-PotatoRunPath) 'screenshots') -ChildPath $name
    }

    $region = $null
    $hasExplicitRegion = $ArgsMap.Contains('X') -or $ArgsMap.Contains('Y') -or $ArgsMap.Contains('Width') -or $ArgsMap.Contains('Height')
    if ($hasExplicitRegion) {
        $region = [ordered]@{
            x = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('X')) 0
            y = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Y')) 0
            width = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Width')) ([PotatoWindowIdentity]::PrimaryWidth())
            height = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Height')) ([PotatoWindowIdentity]::PrimaryHeight())
        }
    }
    else {
        $inputs = Get-PotatoSelectorInputs -ArgsMap $ArgsMap
        $hasSelector = $inputs.path -or $inputs.selector.Name -or $inputs.selector.AutomationId -or $inputs.selector.ClassName -or $inputs.selector.ControlType
        if ($hasSelector) {
            $target = Resolve-PotatoCommandTarget -ArgsMap $ArgsMap -AllowPathAsTarget
            if (-not $target.ok) { throw $target.error }
            $region = ConvertTo-PotatoRectangle -Rectangle $target.element.Current.BoundingRectangle
        }
        else {
            $region = [ordered]@{ x = 0; y = 0; width = [PotatoWindowIdentity]::PrimaryWidth(); height = [PotatoWindowIdentity]::PrimaryHeight() }
        }
    }

    if (-not $region -or $region.width -le 0 -or $region.height -le 0) { throw 'Screenshot target has no usable bounds.' }
    New-PotatoScreenshot -X $region.x -Y $region.y -Width $region.width -Height $region.height -OutFile $outFile -EncoderType $encoder -Quality $quality
    [ordered]@{ path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outFile); region = $region; format = $encoder;
        coordinateSpace='PhysicalScreenPixels'; imageWidth=$region.width; imageHeight=$region.height;
        hint='Image pixels map to physical screen pixels plus region.x/y. Inspect the image before choosing a fallback point; do not use coordinates from a scaled preview.' }
}

function Invoke-PotatoCloseWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $selector = New-PotatoSelectorFromArguments -ArgsMap $ArgsMap
    $selector.Recurse = $false
    $timeoutMs = ConvertTo-PotatoInt (Get-PotatoArg -ArgsMap $ArgsMap -Names @('TimeoutMs')) 0
    $hasSelector = $selector.Name -or $selector.AutomationId -or $selector.ClassName -or $selector.ControlType -or $selector.ProcessName -or $selector.ProcessId -or $selector.WindowTitle
    $windows = @()
    $ticketJson=Get-PotatoArg $ArgsMap @('WindowIdentityJson')
    if ($ticketJson) { $windows=@(Get-PotatoTicketWindow $ticketJson | Where-Object {$_}) }
    elseif ($hasSelector) { $windows = @(Get-PotatoTopLevelWindows -Selector $selector -TimeoutMs $timeoutMs) }
    else {
        $working = Get-PotatoWorkingElement
        if ($working) { $windows = @($working) }
    }

    $closed = 0
    $requests=@()
    # Close dialogs before their parent; closing the parent first can raise a
    # second warning and strand both windows.
    $windows = @($windows | Sort-Object -Property @{ Expression = {
        try { if (Test-PotatoModalAncestor $_) { 0 } else { 1 } } catch { 1 }
    } })
    foreach ($window in $windows) {
        $handle=[int64]$window.Current.NativeWindowHandle
        $processId=[int]$window.Current.ProcessId
        if ($handle) {
            Initialize-PotatoWindowIdentity
            [PotatoWindowIdentity]::RequestClose([IntPtr]$handle,$processId)
            $closed++
            $requests+=@{nativeWindowHandle=$handle;processId=$processId;method='WM_CLOSE'}
        } else {
            $pattern = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
            $pattern.Close()
            $closed++
            $requests+=@{nativeWindowHandle=0;processId=$processId;method='WindowPattern'}
        }
    }
    # Keep identity for asynchronous exit/prompt recovery. The runtime verifies
    # closure separately; do not block in the provider while the window closes.
    [ordered]@{ closed = $closed; closeRequested=$closed; matched = $windows.Count; requests=$requests;
        hint='Close requests were queued. Verify owned windows/process exit and handle any GUI save prompt; closed is the legacy request count, not proof of exit.' }
}

function Invoke-PotatoReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    $step = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Step', 'StepNr')
    $status = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Status')
    $description = Get-PotatoArg -ArgsMap $ArgsMap -Names @('Description', 'Message') -Default ''
    if (-not $step) { throw 'report requires -Step.' }
    if (-not $status) { throw 'report requires -Status.' }

    $takeScreenshot = ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Screenshot', 'TakeScreenshot')) $false
    $screenshot = $null
    if ($takeScreenshot) {
        $screenshot = Invoke-PotatoScreenshot -ArgsMap ([ordered]@{})
    }

    $event = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        step = [string]$step
        status = ([string]$status).ToUpperInvariant()
        description = [string]$description
        screenshot = $screenshot
    }
    $reportPath = Join-Path -Path (Get-PotatoRunPath) -ChildPath 'reports.jsonl'
    $event | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $reportPath -Encoding UTF8
    $script:CurrentState.lastReport = $event
    Save-PotatoState -State $script:CurrentState

    [ordered]@{ event = $event; reportPath = $reportPath }
}

function Invoke-PotatoStateCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ArgsMap
    )

    if (ConvertTo-PotatoBool (Get-PotatoArg -ArgsMap $ArgsMap -Names @('Clear')) $false) {
        if (Test-Path -LiteralPath $script:StatePath) {
            Remove-Item -LiteralPath $script:StatePath -Force
        }
        $script:CurrentState = New-PotatoStateObject
        Save-PotatoState -State $script:CurrentState
        Initialize-PotatoRun -State $script:CurrentState | Out-Null
    }
    [ordered]@{
        statePath = $script:StatePath
        runsRoot = $script:RunsRoot
        state = $script:CurrentState
    }
}

function New-PotatoResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [bool] $Ok,

        [object] $Data = $null,

        [object] $ErrorObject = $null,

        [int] $DurationMs = 0
    )

    $session = [ordered]@{
        statePath = $script:StatePath
        runId = $script:CurrentState.runId
        working = $script:CurrentState.working
    }

    [ordered]@{
        ok = $Ok
        command = $Command
        session = $session
        data = $Data
        error = $ErrorObject
        durationMs = $DurationMs
        logPath = $(if ($script:CurrentState -and $script:RunsRoot) { Get-PotatoLogPath } else { $null })
    }
}

function Invoke-PotatoCliCommandCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [string] $CliRoot = (Split-Path -Parent $PSScriptRoot)
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $normalized = $Command.ToLowerInvariant()
    $argsMap = ConvertTo-PotatoArgumentMap -Arguments $Arguments
    $result = $null
    $ok = $true
    $errorObject = $null

    if ($normalized -eq 'help') {
        try {
            $help = Get-Content -LiteralPath (Join-Path $CliRoot 'commands.json') -Raw | ConvertFrom-Json
            $topic = Get-PotatoArg -ArgsMap $argsMap -Names @('Topic')
            $topics = Get-PotatoArg -ArgsMap $argsMap -Names @('Topics')
            if (-not $topic -and $argsMap._.Count) { $topic = $argsMap._[0] }
            if ($topics) {
                if ($topic) { throw 'Use Topic or Topics, not both.' }
                $selected=[ordered]@{}
                $unknown=@()
                foreach ($item in ([string]$topics -split ',')) {
                    $item=$item.Trim()
                    if ($help.commands.PSObject.Properties.Name -notcontains $item) { $unknown+=$item; continue }
                    $selected[$item]=$help.commands.$item
                }
                $result=@{commands=$selected;unknownTopics=$unknown;availableTopics=@($help.commands.PSObject.Properties.Name);rules=$help.rules;globalOptions=$help.globalOptions;selectorOptions=$help.selectorOptions}
                if ($unknown.Count) { $ok=$false; $errorObject=@{message=('Unknown help topics: '+($unknown -join ', ')+'. Valid requested topics are in data.commands; choose from data.availableTopics.');type='HelpError'} }
            }
            elseif ($topic) {
                if ($help.commands.PSObject.Properties.Name -notcontains $topic) { $result=@{availableTopics=@($help.commands.PSObject.Properties.Name)}; throw "Unknown help topic '$topic'. See data.availableTopics." }
                $result = @{ topic = $topic; help = $help.commands.$topic; rules = $help.rules; globalOptions = $help.globalOptions; selectorOptions = $help.selectorOptions }
            }
            else { $result = $help }
        }
        catch { $ok = $false; $errorObject = @{ message = $_.Exception.Message; type = 'HelpError' } }
        return @{ ok = $ok; command = 'help'; data = $result; error = $errorObject; session = $null; logPath = $null; durationMs = $watch.ElapsedMilliseconds }
        return
    }

    if ($normalized -eq 'read-pdf') {
        try {
            $path = Get-PotatoArg -ArgsMap $argsMap -Names @('Path')
            if (-not $path) { throw 'read-pdf requires -Path.' }
            $reader = [string](Get-PotatoArg $argsMap @('Reader') 'Auto')
            $readTimeout=ConvertTo-PotatoInt (Get-PotatoArg $argsMap @('TimeoutMs')) 5000
            if ($readTimeout -lt 0 -or $readTimeout -gt 60000) { throw 'PDF TimeoutMs must be 0..60000.' }
            if ($reader -notin @('Auto','Builtin','Python')) { throw 'Reader must be Auto, Builtin, or Python.' }
            $pythonPath = [string](Get-PotatoArg $argsMap @('PythonPath') $env:POTATO_PDF_PYTHON)
            $readerUsed='Builtin'; $builtinError=$null
            if ($reader -ne 'Python') {
                try { $text = Read-PotatoPdfText -Path $path -TimeoutMs $readTimeout }
                catch { $builtinError=$_.Exception.Message; if ($reader -eq 'Builtin' -or -not $pythonPath) { throw } }
            }
            if ($reader -eq 'Python' -or $builtinError) {
                if (-not $pythonPath -or -not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { throw 'Python reader needs -PythonPath pointing to an installed Python with pypdf.' }
                $resolvedPdf=(Get-Item -LiteralPath $path -ErrorAction Stop).FullName
                $raw = & $pythonPath (Join-Path $PSScriptRoot 'ReadPdf.py') $resolvedPdf $readTimeout 2>&1
                $pythonExit=$LASTEXITCODE
                $external=($raw -join "`n") | ConvertFrom-Json
                if ($pythonExit -ne 0 -or -not $external.ok) { throw "PDF Python reader failed: $($external.error)" }
                $text=[string]$external.text; $readerUsed='Python/pypdf'
            }
            $result = @{ path = (Get-Item -LiteralPath $path).FullName; text = $text; reader=$readerUsed; builtinError=$builtinError }
        }
        catch { $ok = $false; $errorObject = @{ message = $_.Exception.Message; type = 'PdfReadError' } }
        return @{ ok = $ok; command = $normalized; data = $result; error = $errorObject; session = $null; logPath = $null; durationMs = $watch.ElapsedMilliseconds }
    }

    $script:CurrentState = $null
    $script:StatePath = $null
    $script:RunsRoot = $null
    $policy = $null
    $script:InputScope=$null
    $dispatched = $false
    $previousDpi=[IntPtr]::Zero
    try {
        $policy = Get-PotatoInteractionPolicy -ArgsMap $argsMap -Command $normalized
        $pathValidation=$null
        if ($normalized -eq 'type' -and $argsMap.Contains('PathKind')) {
            $pathText=Get-PotatoArg $argsMap @('Text')
            if ($null -eq $pathText -and $argsMap._.Count) { $pathText=$argsMap._[0] }
            $pathValidation=Test-PotatoTypedPath -Text ([string]$pathText) -Kind ([string]$argsMap.PathKind)
        }
        if ($normalized -notin @('state','wait-file')) {
            Initialize-PotatoWindowIdentity
            $previousDpi=[PotatoWindowIdentity]::EnterPhysicalCoordinates()
        }
        Initialize-PotatoEnvironment -CliRoot $CliRoot
        if ($normalized -in @('type','press-key','observe') -and (Get-PotatoArg $argsMap @('Scope')) -eq 'ForegroundWindow') {
            $scopeRoot=Wait-PotatoGuardedForegroundWindow $argsMap
            $script:InputScope=@{processId=$scopeRoot.Current.ProcessId;nativeWindowHandle=$scopeRoot.Current.NativeWindowHandle;windowScoped=$true}
        }
        Write-PotatoLog -Command $normalized -Message "Command started."
        $dispatched = $true
        switch ($normalized) {
            'start' { $result = Invoke-PotatoStart -ArgsMap $argsMap }
            'focus' { $result = Invoke-PotatoFocus -ArgsMap $argsMap }
            'windows' { $result = Invoke-PotatoWindows -ArgsMap $argsMap }
            'observe' { $result = Invoke-PotatoObserve -ArgsMap $argsMap }
            'select' { $result = Invoke-PotatoSelect -ArgsMap $argsMap }
            'click' { $result = Invoke-PotatoClick -ArgsMap $argsMap }
            'click-coordinate' { $result = Invoke-PotatoClickCoordinate -ArgsMap $argsMap }
            'type' { $result = Invoke-PotatoType -ArgsMap $argsMap; if ($pathValidation) { $result.pathValidation=$pathValidation } }
            'hotkey' { $result = Invoke-PotatoHotkey -ArgsMap $argsMap }
            'press-key' { $result = Invoke-PotatoPressKey -ArgsMap $argsMap }
            'drag' { $result = Invoke-PotatoDrag -ArgsMap $argsMap }
            'hover' { $result = Invoke-PotatoHover -ArgsMap $argsMap }
            'wait-element' { $result = Invoke-PotatoWaitElement -ArgsMap $argsMap }
            'wait-file' { $result = Invoke-PotatoWaitFile -ArgsMap $argsMap }
            'read' { $result = Invoke-PotatoRead -ArgsMap $argsMap }
            'screenshot' { $result = Invoke-PotatoScreenshot -ArgsMap $argsMap }
            'close-window' { $result = Invoke-PotatoCloseWindow -ArgsMap $argsMap }
            'report' { $result = Invoke-PotatoReport -ArgsMap $argsMap }
            'state' { $result = Invoke-PotatoStateCommand -ArgsMap $argsMap }
            default { throw "Unknown command '$Command'." }
        }
        if ($result.verificationPerformed -and $result.verified -eq $false) {
            $ok = $false
            $detail = if ($result.verification) {
                'Mode {0}; {1} read(s) over {2} ms; observed length {3}.' -f
                    $result.verification.mode, $result.verification.attempts,
                    $result.verification.elapsedMs, $result.verification.observedLength
            } else { 'No readback details were available.' }
            $errorObject = [ordered]@{ message = "The requested verification failed. $detail Input was not repeated."; type = 'VerificationFailed'; category = 'InvalidResult' }
        }
        Write-PotatoLog -Command $normalized -Level Success -Message "Command completed."
    }
    catch {
        $ok = $false
        $errorObject = [ordered]@{
            message = $_.Exception.Message
            type = $(if (-not $policy) { 'InteractionPolicyViolation' } else { $_.Exception.GetType().FullName })
            category = [string]$_.CategoryInfo.Category
        }
        $diagnostic=$_.Exception
        while (-not $diagnostic.Data['PotatoErrorType'] -and $diagnostic.InnerException) { $diagnostic=$diagnostic.InnerException }
        if ($diagnostic.Data['PotatoErrorType']) {
            $errorObject.type=$diagnostic.Data['PotatoErrorType']
            $errorObject.candidates=$diagnostic.Data['candidates']
            if ($diagnostic.Data['focus']) { $errorObject.focus=$diagnostic.Data['focus'] }
            if ($diagnostic.Data['blockingDialog']) { $errorObject.blockingDialog=$diagnostic.Data['blockingDialog'] }
            if ($diagnostic.Data['NoInputSent']) { $dispatched=$false }
        }
        if ($script:CurrentState) { try { Write-PotatoLog -Command $normalized -Level Error -Message $errorObject.message } catch {} }
    }
    finally {
        $script:InputScope=$null
        if ($previousDpi -ne [IntPtr]::Zero) { [void][PotatoWindowIdentity]::SetThreadDpiAwarenessContext($previousDpi) }
        $watch.Stop()
    }

    $durationMs = [int]$watch.ElapsedMilliseconds
    try {
        $argumentNames = @($argsMap.Keys | Where-Object { $_ -ne '_' } | ForEach-Object { [string]$_ })
        $positionalCount = 0
        if ($argsMap.Contains('_') -and $argsMap._) { $positionalCount = @($argsMap._).Count }
        Write-PotatoMetric -Metric ([ordered]@{
            timestamp = (Get-Date).ToString('o')
            event = 'potato_command'
            runId = $script:CurrentState.runId
            command = $normalized
            ok = $ok
            durationMs = $durationMs
            argumentNames = $argumentNames
            positionalArgumentCount = $positionalCount
            errorType = $(if ($errorObject) { $errorObject.type } else { $null })
            errorCategory = $(if ($errorObject) { $errorObject.category } else { $null })
        })
    }
    catch {}

    $response = New-PotatoResult -Command $normalized -Ok $ok -Data $result -ErrorObject $errorObject -DurationMs $durationMs
    $response.interactionPolicy = $policy
    $response.outcome = if (-not $dispatched) { 'not-dispatched' } elseif (-not $ok -and $normalized -in @('click','click-coordinate','type','hotkey','press-key','start','close-window','drag','focus')) { 'unknown' } else { 'completed' }
    return $response
}

function Invoke-PotatoCliCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Command, [string[]] $Arguments = @(),
          [string] $CliRoot = (Split-Path -Parent $PSScriptRoot), [switch] $AsObject)
    $lease = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Command -notin @('help', 'read-pdf')) {
            $map = ConvertTo-PotatoArgumentMap $Arguments
            $lease = Enter-PotatoDesktopLease -TimeoutMs (ConvertTo-PotatoInt (Get-PotatoArg $map @('LeaseTimeoutMs')) 15000)
        }
        $leaseMs = $watch.ElapsedMilliseconds
        $response = Invoke-PotatoCliCommandCore -Command $Command -Arguments $Arguments -CliRoot $CliRoot
        $response.leaseWaitMs = $leaseMs
    }
    catch {
        $response = @{ok=$false;command=$Command;data=$null;session=$null;logPath=$null;outcome='not-dispatched';
            error=@{type='DesktopLeaseError';message=$_.Exception.Message};durationMs=$watch.ElapsedMilliseconds}
    }
    finally { if ($lease) { $lease.ReleaseMutex(); $lease.Dispose() } }
    $response.totalDurationMs = $watch.ElapsedMilliseconds
    if ($AsObject) { return $response }
    $response | ConvertTo-Json -Depth 60 -Compress
}

Export-ModuleMember -Function Invoke-PotatoCliCommand, Read-PotatoPdfText
