param()
$ErrorActionPreference='Stop'
$cliRoot=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-path-fixture-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root)
        $script:checks=0
        function Check($value,$message) { if (-not $value) {throw $message}; $script:checks++ }
        function RejectPath($text,$kind) {
            $result=Invoke-PotatoCliCommand type @('-Text',$text,'-PathKind',$kind) -CliRoot $root -AsObject
            Check (-not $result.ok -and $result.error.type -eq 'PathValidationFailed' -and $result.outcome -eq 'not-dispatched') ('Invalid path reached desktop dispatch: '+$text)
        }
        $missing=Join-Path $root 'uncreated\output.ext'
        RejectPath $missing SaveFile
        Check (-not [IO.Directory]::Exists((Join-Path $root 'uncreated'))) 'Validation created the missing folder.'
        Check (-not [IO.Directory]::Exists((Join-Path $root '.state'))) 'Invalid path initialized a desktop session.'
        foreach ($path in @('relative\output.ext','C:output.ext','\output.ext','"C:\output.ext"','%TEMP%\output.ext',('C:\bad'+[char]10+'name.ext'))) {
            RejectPath $path SaveFile
        }
        RejectPath $root SaveFile
        RejectPath (Join-Path $root 'absent.ext') OpenFile
        RejectPath (Join-Path $root 'absent') Directory
        RejectPath (Join-Path $root 'output.ext') WrongKind
        $folder=Join-Path $root ('literal [brackets] +^%{} '+[char]0x151+[char]0x4e2d)
        [void][IO.Directory]::CreateDirectory($folder)
        $path=Join-Path $folder 'output.ext'
        $validated=Test-PotatoTypedPath $path SaveFile
        Check ($validated.validated -and $validated.path -ceq $path -and $validated.parentPath -ceq $folder) 'Literal path was expanded, truncated, or changed.'
        Check (-not [IO.File]::Exists($path)) 'Save validation fabricated output.'
        [IO.File]::WriteAllText($path,'Synthetic existing-file fixture')
        Check (Test-PotatoTypedPath $path OpenFile).validated 'Existing literal file was rejected.'
        Check (Test-PotatoTypedPath $folder Directory).validated 'Existing literal directory was rejected.'
        Check (Test-PotatoTypedPath $path SaveFile).validated 'Existing save target was rejected; overwrite decisions belong to the GUI.'
        "Path input checks: $script:checks passed"
    } $root
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-path-fixture-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
