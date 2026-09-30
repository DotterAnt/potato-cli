# Read-only desktop capture in an isolated state directory; no app is launched.
param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-dpi-fixture-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$checks=0
try {
    $probe=Join-Path $root 'probe.ps1'
    @'
param($ModulePath,$Root,[int]$Awareness)
$ErrorActionPreference='Stop'
$module=Import-Module $ModulePath -PassThru
& $module { Initialize-PotatoWindowIdentity }
$original=[PotatoWindowIdentity]::SetThreadDpiAwarenessContext([IntPtr]$Awareness)
if ($original -eq [IntPtr]::Zero) { throw 'Could not set test caller DPI context.' }
try {
    # Cache WinForms Screen under the caller's context before the CLI loads it.
    Add-Type -AssemblyName System.Windows.Forms
    $callerWidth=[Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
    $callerContext=[PotatoWindowIdentity]::GetThreadDpiAwarenessContext()
    $physical=[PotatoWindowIdentity]::EnterPhysicalCoordinates()
    try { $width=[PotatoWindowIdentity]::PrimaryWidth(); $height=[PotatoWindowIdentity]::PrimaryHeight() }
    finally { [void][PotatoWindowIdentity]::SetThreadDpiAwarenessContext($physical) }
    $shot=Invoke-PotatoCliCommand screenshot @('-OutFile',(Join-Path $Root 'capture.png')) -CliRoot $Root -AsObject
    if (-not $shot.ok) { throw ($shot | ConvertTo-Json -Depth 6 -Compress) }
    $restored=[PotatoWindowIdentity]::AreDpiAwarenessContextsEqual($callerContext,[PotatoWindowIdentity]::GetThreadDpiAwarenessContext())
    $bitmap=[Drawing.Image]::FromFile($shot.data.path)
    try { $imageWidth=$bitmap.Width; $imageHeight=$bitmap.Height } finally { $bitmap.Dispose() }
    $failure=Invoke-PotatoCliCommand unsupported-dpi-fixture @() -CliRoot $Root -AsObject
    $restoredOnError=[PotatoWindowIdentity]::AreDpiAwarenessContextsEqual($callerContext,[PotatoWindowIdentity]::GetThreadDpiAwarenessContext())
    @{ok=$shot.ok;callerWidth=$callerWidth;width=$width;height=$height;region=$shot.data.region;imageWidth=$imageWidth;imageHeight=$imageHeight;
        coordinateSpace=$shot.data.coordinateSpace;restored=$restored;restoredOnError=$restoredOnError;failureOk=$failure.ok} | ConvertTo-Json -Depth 5 -Compress
} finally { [void][PotatoWindowIdentity]::SetThreadDpiAwarenessContext($original) }
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
    $values=@()
    foreach ($awareness in @(-1,-2)) {
        $value=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -ModulePath (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Root $root -Awareness $awareness | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $value.ok) { throw 'DPI fixture process failed.' }; $checks++
        if ($value.region.width -ne $value.width -or $value.region.height -ne $value.height -or $value.imageWidth -ne $value.width -or $value.imageHeight -ne $value.height -or $value.coordinateSpace -ne 'PhysicalScreenPixels') { throw 'Capture dimensions were virtualized or inconsistent with physical pixels.' }; $checks++
        if (-not $value.restored -or -not $value.restoredOnError -or $value.failureOk) { throw 'CLI changed the embedding caller DPI context after success/failure.' }; $checks++
        $values+=$value
    }
    if ($values[0].width -ne $values[1].width -or $values[0].height -ne $values[1].height) { throw 'Physical capture dimensions depend on caller awareness.' }; $checks++
    "DPI checks: $checks passed (unaware/system-aware callers, cached screen bounds, capture dimensions, context restoration). Physical=$($values[0].width)x$($values[0].height); unaware cached width=$($values[0].callerWidth)."
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-dpi-fixture-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
