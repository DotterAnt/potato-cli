[CmdletBinding()]
param([string] $CliRoot, [switch] $ContinueOnError)

$ErrorActionPreference = 'Stop'
if (-not $CliRoot) { $CliRoot = $PSScriptRoot }
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Import-Module (Join-Path $PSScriptRoot 'PoTAToCli\PoTAToCli.psm1') -Force

while ($null -ne ($line = [Console]::ReadLine())) {
    $line = $line.TrimStart([char]0xFEFF)
    $requestId = $null
    $command = ''
    try {
        $request = $line | ConvertFrom-Json
        if ($null -eq $request -or $request -isnot [psobject] -or -not $request.command) {
            throw 'Each input line must be a JSON object with a command.'
        }
        $command = [string]$request.command
        $requestId = $request.requestId
        if ($command -eq 'quit') {
            $response = [ordered]@{ok=$true;command='quit';outcome='completed';data=$null;error=$null}
        }
        else {
            $arguments = @()
            if ($null -ne $request.arguments) { $arguments = @($request.arguments | ForEach-Object { [string]$_ }) }
            $response = Invoke-PotatoCliCommand -Command $command -Arguments $arguments -CliRoot $CliRoot -AsObject
        }
    }
    catch {
        $response = [ordered]@{ok=$false;command=$command;outcome='not-dispatched';data=$null;
            error=[ordered]@{type='StreamRequestError';message=$_.Exception.Message}}
    }
    if ($null -ne $requestId) { $response['requestId'] = $requestId }
    [Console]::WriteLine(($response | ConvertTo-Json -Depth 80 -Compress))
    $conditionFailed=($command -eq 'wait-element' -and -not $response.data.exists) -or ($command -eq 'wait-file' -and -not $response.data.conditionMet)
    if ((-not $response.ok -or $conditionFailed) -and -not $ContinueOnError) { exit 1 }
    if ($command -eq 'quit' -and $response.ok) { break }
}
