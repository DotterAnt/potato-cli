param([Parameter(Mandatory)][string]$PythonPath)
$ErrorActionPreference='Stop'
$cliRoot=Split-Path $PSScriptRoot
Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('potato-pdf-external-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
try {
    $fixture=Join-Path $root 'make_fixture.py'
    @'
from pypdf import PdfWriter
from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
import sys
w=PdfWriter()
p=w.add_blank_page(width=300,height=300)
font=DictionaryObject({NameObject('/Type'):NameObject('/Font'),NameObject('/Subtype'):NameObject('/Type1'),NameObject('/BaseFont'):NameObject('/Helvetica')})
p[NameObject('/Resources')]=DictionaryObject({NameObject('/Font'):DictionaryObject({NameObject('/F1'):w._add_object(font)})})
s=DecodedStreamObject(); s.set_data(b'BT /F1 12 Tf 20 220 Td (External reader fixture) Tj ET')
p[NameObject('/Contents')]=w._add_object(s)
# An unused object rejected by the deliberately limited built-in reader.
# pypdf follows the cross-reference table and reads the supported page normally.
w._add_object(DictionaryObject({NameObject('/Type'):NameObject('/ObjStm')}))
w.write(sys.argv[1])
'@ | Set-Content $fixture -Encoding UTF8
    $path=Join-Path $root "sample with space and apostrophe's.pdf"
    & $PythonPath $fixture $path
    if ($LASTEXITCODE -ne 0) { throw 'PDF fixture generator failed.' }
    $r=Invoke-PotatoCliCommand read-pdf @('-Path',$path,'-Reader','Python','-PythonPath',$PythonPath) -CliRoot $root -AsObject
    if (-not $r.ok -or $r.data.reader -ne 'Python/pypdf' -or $r.data.text -notmatch 'External reader fixture') { throw ($r | ConvertTo-Json -Depth 6) }
    $r=Invoke-PotatoCliCommand read-pdf @('-Path',$path,'-Reader','Auto','-PythonPath',$PythonPath) -CliRoot $root -AsObject
    if (-not $r.ok -or $r.data.reader -ne 'Python/pypdf' -or -not $r.data.builtinError -or $r.data.text -notmatch 'External reader fixture') { throw ($r | ConvertTo-Json -Depth 6) }
    $r=Invoke-PotatoCliCommand read-pdf @('-Path',$path,'-Reader','Builtin') -CliRoot $root -AsObject
    if ($r.ok) { throw 'Builtin silently ignored an unsupported PDF.' }
    $incomplete=Join-Path $root 'incomplete.pdf'
    $latin1=[Text.Encoding]::GetEncoding(28591)
    [IO.File]::WriteAllText($incomplete,([IO.File]::ReadAllText($path,$latin1) -replace '%%EOF\s*$', ''),$latin1)
    foreach ($reader in @('Python','Auto')) {
        $r=Invoke-PotatoCliCommand read-pdf @('-Path',$incomplete,'-Reader',$reader,'-PythonPath',$PythonPath) -CliRoot $root -AsObject
        if ($r.ok -or $r.error.message -notmatch 'missing final EOF') { throw 'External reader accepted an unfinished PDF export.' }
    }
    $bad=Join-Path $root 'bad.pdf'; 'not a PDF' | Set-Content $bad
    $r=Invoke-PotatoCliCommand read-pdf @('-Path',$bad,'-Reader','Python','-PythonPath',$PythonPath) -CliRoot $root -AsObject
    if ($r.ok) { throw 'Invalid PDF passed external verification.' }
    'External PDF checks: 6 passed (quoted path, fallback with provenance, strict builtin, incomplete export in Python/Auto, invalid PDF)'
} finally {
    $resolved=[IO.Path]::GetFullPath($root); $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-pdf-external-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
