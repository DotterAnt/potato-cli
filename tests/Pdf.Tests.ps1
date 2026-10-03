param([string] $SampleDirectory)
$ErrorActionPreference = 'Stop'
$cliRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $cliRoot 'PoTAToCli\PoTAToCli.psm1') -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('potato-pdf-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:checks = 0
function Check($condition, $message) { if (-not $condition) { throw $message }; $script:checks++ }
$latin1 = [Text.Encoding]::GetEncoding(28591)

function New-TestStream([string] $Text, [switch] $Compressed) {
    $filter = ''
    if ($Compressed) {
        $bytes = $latin1.GetBytes($Text)
        $buffer = [IO.MemoryStream]::new()
        $deflate = [IO.Compression.DeflateStream]::new($buffer, [IO.Compression.CompressionMode]::Compress, $true)
        try { $deflate.Write($bytes, 0, $bytes.Length) } finally { $deflate.Dispose() }
        # Wrap the raw deflate data in zlib with an Adler-32 checksum.
        [long]$a = 1; [long]$b = 0
        foreach ($byte in $bytes) { $a = ($a + $byte) % 65521; $b = ($b + $a) % 65521 }
        $checksum = [byte[]]@(($b -shr 8), ($b -band 255), ($a -shr 8), ($a -band 255))
        $Text = $latin1.GetString([byte[]](@(0x78, 0x9c) + $buffer.ToArray() + $checksum))
        $buffer.Dispose()
        $filter = '/Filter /FlateDecode '
    }
    return "<< $filter/Length $($Text.Length) >>`nstream`n$Text`nendstream"
}

function Write-TestPdf([string] $Path, [System.Collections.IDictionary] $Objects, [string] $Trailer = '') {
    $pdf = [Text.StringBuilder]::new("%PDF-1.4`n")
    $offsets = @{}
    foreach ($id in $Objects.Keys) {
        $offsets[[int]$id] = $pdf.Length
        [void]$pdf.Append("$id 0 obj`n$($Objects[$id])`nendobj`n")
    }
    $xref = $pdf.Length
    $size = 1 + ($offsets.Keys | Measure-Object -Maximum).Maximum
    [void]$pdf.Append("xref`n0 $size`n0000000000 65535 f `n")
    for ($id = 1; $id -lt $size; $id++) {
        $line = if ($offsets.ContainsKey($id)) { '{0:0000000000} 00000 n ' -f $offsets[$id] } else { '0000000000 00000 f ' }
        [void]$pdf.AppendLine($line)
    }
    [void]$pdf.Append("trailer`n<< /Size $size /Root 1 0 R $Trailer >>`nstartxref`n$xref`n%%EOF`n")
    [IO.File]::WriteAllBytes($Path, $latin1.GetBytes($pdf.ToString()))
}

try {
    $path = Join-Path $testRoot 'text [sample].pdf'
    $cmap = @'
begincmap
1 begincodespacerange <0000> <FFFF> endcodespacerange
3 beginbfchar <0001> <0054> <0002> <00E9> <0003> <00730074> endbfchar
2 beginbfrange
<0010> <0012> <0041>
<0020> <0021> [<0151> <D83DDE00>]
endbfrange
endcmap
'@
    $objects = @{
        1 = '<< /Type /Catalog /Pages 2 0 R >>'
        2 = '<< /Type /Pages /Kids [7 0 R 3 0 R] /Count 2 /Resources << /Font << /F1 4 0 R >> >> >>'
        3 = '<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>'
        4 = '<< /Type /Font /Subtype /Type0 /Encoding /Identity-H /ToUnicode 6 0 R >>'
        5 = New-TestStream 'BT /F1 12 Tf [<0010> 10 <0011> -200 <0012>] TJ ET'
        6 = New-TestStream $cmap -Compressed
        7 = '<< /Type /Page /Parent 2 0 R /Resources 9 0 R /Contents [8 0 R 10 0 R] >>'
        8 = New-TestStream 'BT /F1 12 Tf <000100020003> Tj' -Compressed
        9 = '<< /Font << /F1 4 0 R >> >>'
        10 = New-TestStream '0 -20 Td <00200021> Tj ET' -Compressed
        # Deliberately contains apparent object delimiters. It must never be scanned as objects.
        11 = New-TestStream 'endobj 12 0 obj << /Type /Catalog >> endobj'
    }
    Write-TestPdf $path $objects
    $expected = 'T' + [char]0xE9 + "st`n" + [char]0x151 + [char]::ConvertFromUtf32(0x1F600) + "`n`nAB C"
    $text = Read-PotatoPdfText -Path $path
    Check (($text -replace "`r`n", "`n") -ceq $expected) 'Page order, stream joining, Unicode maps, or TJ spacing failed.'
    $incomplete=Join-Path $testRoot 'incomplete.pdf'
    [IO.File]::WriteAllText($incomplete,([IO.File]::ReadAllText($path,$latin1) -replace '%%EOF\s*$', ''),$latin1)
    $unfinished=Invoke-PotatoCliCommand read-pdf @('-Path',$incomplete) -AsObject
    Check (-not $unfinished.ok -and $unfinished.error.message -match 'missing final EOF') 'Shared snapshot accepted an unfinished PDF export.'
    $response = Invoke-PotatoCliCommand read-pdf @('-Path', $path) -CliRoot (Join-Path $testRoot 'unused') -AsObject
    Check ($response.ok -and $response.data.text -ceq $text -and $response.data.path -eq $path) 'JSON/object command differs from the exported reader.'
    Check ($null -eq $response.session -and $null -eq $response.logPath -and -not (Test-Path (Join-Path $testRoot 'unused'))) 'PDF command touched session state.'
    $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    try { Check ((Read-PotatoPdfText $path) -ceq $text) 'PDF read conflicted with a cooperating producer retaining its write handle.' }
    finally { $writer.Dispose() }
    $ready=New-Object Threading.ManualResetEvent($false)
    $worker=[powershell]::Create()
    [void]$worker.AddScript({param($path,$ready)
        $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { [void]$ready.Set(); Start-Sleep -Milliseconds 400 } finally {$lock.Dispose()}
    }).AddArgument($path).AddArgument($ready)
    $pending=$worker.BeginInvoke()
    try {
        Check ($ready.WaitOne(5000)) 'PDF lock fixture did not become ready.'
        Check ((Read-PotatoPdfText $path -TimeoutMs 2000) -ceq $text) 'Transient exclusive PDF lock was not retried.'
    } finally { $worker.EndInvoke($pending) | Out-Null; $worker.Dispose(); $ready.Dispose() }
    $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $locked=Invoke-PotatoCliCommand read-pdf @('-Path',$path,'-TimeoutMs','150') -AsObject
        Check (-not $locked.ok -and $locked.error.message -match 'locked or changing' -and $watch.ElapsedMilliseconds -lt 2500) 'Persistent PDF lock did not fail within the configured read deadline.'
    } finally { $lock.Dispose() }
    $json = @(& (Join-Path $cliRoot 'potato.ps1') read-pdf -Path $path)
    Check ($json.Count -eq 1 -and ($json[0] | ConvertFrom-Json).data.text -ceq $text) 'Entry point must write exactly one JSON response.'
    $help = & (Join-Path $cliRoot 'potato.ps1') help -Topic read-pdf | ConvertFrom-Json
    Check ($help.ok -and $help.data.topic -eq 'read-pdf') 'PDF command help is missing.'

    # Reused font names on different pages must not share the wrong Unicode map.
    $objects[4] = '<< /Type /Font /Subtype /TrueType /ToUnicode 6 0 R >>'
    $objects[6] = New-TestStream '1 beginbfrange <00> <7F> <0000> endbfrange'
    $objects[9] = '<< /Font << /F1 12 0 R >> >>'
    $objects[12] = '<< /Type /Font /Subtype /Type0 /ToUnicode 13 0 R >>'
    $objects[13] = New-TestStream '1 beginbfchar <41> <03A9> endbfchar'
    $objects[8] = New-TestStream 'BT /F1 12 Tf (A) Tj ET'
    $objects[10] = New-TestStream ''
    $objects[5] = New-TestStream 'BT /F1 12 Tf (a(b)c \\ \(x\) \101) Tj T* (next) Tj ET'
    Write-TestPdf $path $objects
    $expected = [string][char]0x3A9 + "`n`na(b)c \ (x) A`nnext"
    Check (((Read-PotatoPdfText $path) -replace "`r`n", "`n") -ceq $expected) 'Page font scoping or literal string escapes failed.'

    $objects[2] = '<< /Type /Pages /Kids [3 0 R] /Count 1 /Resources << /Font << /F1 4 0 R /F2 12 0 R >> /XObject 14 0 R >> >>'
    $objects[14] = '<< >>'
    $objects[5] = New-TestStream '/F1 12 Tf BT (A) Tj ET q BT /F2 12 Tf (A) Tj ET Q BT (A) Tj ET'
    Write-TestPdf $path $objects
    $expected = "A`n" + [char]0x3A9 + "`nA"
    Check (((Read-PotatoPdfText $path) -replace "`r`n", "`n") -ceq $expected) 'Graphics state did not restore the selected font.'
    $objects[14] = '<< /Form1 15 0 R >>'
    $objects[15] = (New-TestStream 'BT /F1 12 Tf (hidden form text) Tj ET') -replace '^<<', '<< /Subtype /Form'
    $objects[5] = New-TestStream 'BT /F1 12 Tf (A) Tj ET /Form1 Do'
    Write-TestPdf $path $objects
    $response = Invoke-PotatoCliCommand read-pdf @('-Path', $path) -AsObject
    Check (-not $response.ok -and $response.error.message -like '*Form XObjects*') 'Form text was silently omitted.'

    $objects[5] = New-TestStream 'BT /F1 12 Tf <FF> Tj ET'
    Write-TestPdf $path $objects
    $response = Invoke-PotatoCliCommand read-pdf @('-Path', $path) -AsObject
    Check (-not $response.ok -and $response.error.message -like '*no entry*') 'Unmapped glyphs must fail instead of returning gibberish.'
    Write-TestPdf $path $objects '/Encrypt 14 0 R'
    $response = Invoke-PotatoCliCommand read-pdf @('-Path', $path) -AsObject
    Check (-not $response.ok -and $response.error.message -like '*Encrypted*') 'Encrypted PDF did not fail clearly.'

    $objects[5] = New-TestStream 'q Q'
    $objects[8] = New-TestStream 'q Q'
    Write-TestPdf $path $objects
    $response = Invoke-PotatoCliCommand read-pdf @('-Path', $path) -AsObject
    Check (-not $response.ok -and $response.error.message -like '*No extractable*') 'Empty/image-only PDF reported success.'
    $existence=Invoke-PotatoCliCommand wait-file @('-Path',$path,'-TimeoutMs','1000') -AsObject
    Check ($existence.ok -and $existence.data.conditionMet -and $existence.data.exists) 'Existence-only PDF check required extractable content.'
    $help=Invoke-PotatoCliCommand help @('-Topic','read-pdf','-Format','Full') -AsObject
    Check ($help.ok -and $help.data.help.imageContent -match 'existence-only' -and $help.data.help.imageContent -match 'use wait-file') 'CLI help required extra inspection for an existence-only PDF expectation.'
    $objects[5] = '<< /Length 1 /Filter /LZWDecode >>' + "`nstream`nx`nendstream"
    Write-TestPdf $path $objects
    Check (-not (Invoke-PotatoCliCommand read-pdf @('-Path', $path) -AsObject).ok) 'Unsupported stream filter reported success.'
    $objects[5] = "<< /Length 999999 >>`nstream`nx`nendstream"
    Write-TestPdf $path $objects
    Check (-not (Invoke-PotatoCliCommand read-pdf @('-Path', $path) -AsObject).ok) 'Truncated stream reported success.'

    [IO.File]::WriteAllText($path, 'not a PDF')
    foreach ($arguments in @(@('-Path', $path), @('-Path', (Join-Path $testRoot 'missing.pdf')), @('-Path', $testRoot), @())) {
        $response = Invoke-PotatoCliCommand read-pdf $arguments -AsObject
        Check (-not $response.ok -and $response.error.type -eq 'PdfReadError') 'Invalid input did not return a structured PDF error.'
    }

    if ($SampleDirectory) {
        $expectedSamples = @{
            'ExcelTest.pdf' = 'Test'; 'powerpoint.pdf' = 'testsetse'; 'notepad.pdf' = 'test'
            'access.pdf' = 'Table1'; 'onenote.pdf' = 'Quick Notes Page 1'; 'edge.pdf' = 'Microsoft Corporation'
        }
        foreach ($name in $expectedSamples.Keys) {
            $text = Read-PotatoPdfText (Join-Path $SampleDirectory $name)
            Check ($text.Contains($expectedSamples[$name])) "Sample $name did not contain its expected text."
            "Sample ${name}: $($text.Length) characters extracted"
        }
    }
    "PDF checks: $script:checks passed (PowerShell $($PSVersionTable.PSVersion))"
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'potato-pdf-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
