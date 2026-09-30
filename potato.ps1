# Keep this a simple script: advanced binding consumes command flags such as
# -Arguments before they reach the CLI parser. All tokens after Command are raw.
param(
    [string] $Command = 'state'
)

$commandArguments = @($args)
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'PoTAToCli\PoTAToCli.psm1'
Import-Module $modulePath -Force

$result=Invoke-PotatoCliCommand -Command $Command -Arguments $commandArguments -CliRoot $PSScriptRoot -AsObject
$result | ConvertTo-Json -Depth 60 -Compress
if ($result.ok -eq $false) { exit 1 }
