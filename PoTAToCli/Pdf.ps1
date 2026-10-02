function Read-PotatoPdfSnapshot {
    param([string]$Path,[int]$TimeoutMs=5000)
    if ($TimeoutMs -lt 0 -or $TimeoutMs -gt 60000) { throw 'PDF TimeoutMs must be 0..60000.' }
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.PSProvider.Name -ne 'FileSystem') { throw 'PDF path must be a file.' }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $stream=$null; $buffer=$null
        try {
            $file.Refresh()
            $length=$file.Length; $modified=$file.LastWriteTimeUtc.Ticks
            # Print/export producers can retain a write handle after flushing.
            # Shared read observes bytes only; the file must not change during it.
            $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $buffer=New-Object IO.MemoryStream
            $stream.CopyTo($buffer)
            $file.Refresh()
            if ($length -eq $file.Length -and $modified -eq $file.LastWriteTimeUtc.Ticks -and $buffer.Length -eq $length) { return ,$buffer.ToArray() }
            $lastError='The file changed during the read.'
        } catch {
            $exception=$_.Exception
            while ($exception.InnerException) { $exception=$exception.InnerException }
            if (($exception.HResult -band 0xffff) -notin @(32,33)) { throw }
            $lastError=$exception.Message
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($buffer) { $buffer.Dispose() }
        }
        if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { throw "PDF remained locked or changing for $TimeoutMs ms. $lastError" }
        Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(100,$TimeoutMs-$watch.ElapsedMilliseconds)))
    } while ($true)
}

function Read-PotatoPdfText {
    <#
    .SYNOPSIS
    Reads text from simple PDFs, including Microsoft Print to PDF and Edge output.
    .DESCRIPTION
    Uses only built-in .NET types. Supports ordinary PDF objects, direct stream
    lengths, uncompressed/FlateDecode streams, and fonts with ToUnicode maps.
    Returns text in drawing order with approximate whitespace, not page layout.
    Does not perform OCR or support encryption, object streams, or Form XObjects.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path,[int]$TimeoutMs=5000)

    $ErrorActionPreference = 'Stop'
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.PSProvider.Name -ne 'FileSystem') { throw 'PDF path must be a file.' }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $raw = $latin1.GetString((Read-PotatoPdfSnapshot $file.FullName $TimeoutMs))
    if (-not $raw.StartsWith('%PDF-')) { throw 'Not a PDF file.' }
    if ($raw -notmatch '%%EOF[\x00\x09\x0A\x0C\x0D\x20]*\z') { throw 'Incomplete PDF: missing final EOF marker. Wait for export completion before reading.' }

    # Latin-1 preserves byte offsets. Skip streams by /Length so embedded font or
    # image bytes containing PDF-looking tokens cannot become document objects.
    $objects = @{}
    $objectPattern = [regex]'(?s)(\d+)\s+(\d+)\s+obj\b(.*?)(\bstream(?:\r\n|\n|\r)|\bendobj\b)'
    $offset = 0
    while (($match = $objectPattern.Match($raw, $offset)).Success) {
        $key = $match.Groups[1].Value + ' ' + $match.Groups[2].Value
        $body = $match.Groups[3].Value
        if ($objects.ContainsKey($key)) { throw 'Incrementally updated PDFs are not supported.' }
        if ($body -match '/Type\s*/(?:ObjStm|XRef)\b') { throw 'PDF object/xref streams are not supported.' }
        $offset = $match.Index + $match.Length
        $stream = $null
        if ($match.Groups[4].Value.StartsWith('stream')) {
            $lengthMatch = [regex]::Match($body, '/Length\s+(\d+)(\s+\d+\s+R)?\b')
            if (-not $lengthMatch.Success -or $lengthMatch.Groups[2].Success) { throw 'PDF streams must have direct lengths.' }
            $length = [int]$lengthMatch.Groups[1].Value
            if ($length -gt $raw.Length - $offset) { throw 'Truncated PDF stream.' }
            $stream = $raw.Substring($offset, $length)
            $offset += $length
            $ending = [regex]::Match($raw.Substring($offset), '^\s*endstream\s*endobj\b')
            if (-not $ending.Success) { throw 'Invalid PDF stream length or terminator.' }
            $offset += $ending.Length
        }
        $objects[$key] = @{ body = $body; stream = $stream }
    }
    if ($raw.Substring($offset) -match '/Encrypt\b') { throw 'Encrypted PDFs are not supported.' }

    function Get-PdfObject([string] $Reference) {
        $key = ($Reference -replace '\s+R\s*$', '').Trim() -replace '\s+', ' '
        if (-not $objects.ContainsKey($key)) { throw "Missing PDF object $key." }
        return $objects[$key]
    }

    function Get-PdfStream([string] $Reference) {
        $obj = Get-PdfObject $Reference
        if ($null -eq $obj.stream) { throw "PDF object $Reference is not a stream." }
        if ($obj.body -notmatch '/Filter\b') { return $obj.stream }
        if ($obj.body -notmatch '/Filter\s*(?:/FlateDecode\b|\[\s*/FlateDecode\s*\])' -or $obj.body -match '/DecodeParms\b') {
            throw 'Only plain FlateDecode PDF streams without DecodeParms are supported.'
        }
        $bytes = $latin1.GetBytes($obj.stream)
        if ($bytes.Length -lt 6 -or ($bytes[0] -band 15) -ne 8 -or
            (($bytes[0] * 256 + $bytes[1]) % 31) -ne 0 -or ($bytes[1] -band 32)) { throw 'Invalid PDF zlib stream.' }
        # PDF FlateDecode uses zlib; DeflateStream on PowerShell 5.1 needs the
        # payload without the two-byte header/four-byte checksum.
        $inputStream = [IO.MemoryStream]::new($bytes, 2, $bytes.Length - 6)
        $outputStream = [IO.MemoryStream]::new()
        $deflate = [IO.Compression.DeflateStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
        try {
            $deflate.CopyTo($outputStream)
            return $latin1.GetString($outputStream.ToArray())
        }
        finally { $deflate.Dispose(); $inputStream.Dispose(); $outputStream.Dispose() }
    }

    function ConvertFrom-PdfHex([string] $Hex) {
        $hex = $Hex -replace '\s', ''
        if ($hex.Length % 2) { $hex += '0' }
        $bytes = [byte[]]::new($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        return ,$bytes
    }

    $fontCache = @{}
    function Get-PdfFontMap([string] $Reference) {
        if ($fontCache.ContainsKey($Reference)) { return $fontCache[$Reference] }
        $font = Get-PdfObject $Reference
        if ($font.body -notmatch '/ToUnicode\s+(\d+\s+\d+\s+R)') { throw 'PDF text fonts must have a ToUnicode map.' }
        $cmap = Get-PdfStream $Matches[1]
        if ($cmap -match '\busecmap\b') { throw 'Inherited PDF Unicode maps are not supported.' }
        $map = @{}
        foreach ($block in [regex]::Matches($cmap, '(?s)beginbfchar\b(.*?)endbfchar')) {
            foreach ($entry in [regex]::Matches($block.Groups[1].Value, '<([\da-fA-F]+)>\s*<([\da-fA-F]+)>')) {
                $map[$entry.Groups[1].Value] = [Text.Encoding]::BigEndianUnicode.GetString((ConvertFrom-PdfHex $entry.Groups[2].Value))
            }
        }
        foreach ($block in [regex]::Matches($cmap, '(?s)beginbfrange\b(.*?)endbfrange')) {
            foreach ($entry in [regex]::Matches($block.Groups[1].Value, '(?s)<([\da-fA-F]+)>\s*<([\da-fA-F]+)>\s*(<([\da-fA-F]{4})>|\[(.*?)\])')) {
                $first = [Convert]::ToInt32($entry.Groups[1].Value, 16)
                $last = [Convert]::ToInt32($entry.Groups[2].Value, 16)
                if ($last -lt $first -or $last -gt 65535) { throw 'Unsupported PDF Unicode range.' }
                $values = @([regex]::Matches($entry.Groups[5].Value, '<([\da-fA-F]+)>'))
                for ($code = $first; $code -le $last; $code++) {
                    $key = $code.ToString('X' + $entry.Groups[1].Value.Length)
                    if ($entry.Groups[4].Success) {
                        $unicode = [Convert]::ToInt32($entry.Groups[4].Value, 16) + $code - $first
                        $map[$key] = [string][char]$unicode
                    }
                    else {
                        if ($values.Count -ne $last - $first + 1) { throw 'Invalid PDF Unicode range array.' }
                        $map[$key] = [Text.Encoding]::BigEndianUnicode.GetString((ConvertFrom-PdfHex $values[$code - $first].Groups[1].Value))
                    }
                }
            }
        }
        $widths = @($map.Keys | ForEach-Object { $_.Length } | Sort-Object -Unique)
        if ($widths.Count -ne 1 -or $widths[0] -notin @(2, 4)) { throw 'Only fixed one/two-byte PDF Unicode maps are supported.' }
        $result = @{ map = $map; width = $widths[0] }
        $fontCache[$Reference] = $result
        return $result
    }

    function ConvertFrom-PdfText([string] $Token, $Font) {
        if (-not $Font) { throw 'PDF text has no selected font.' }
        if ($Token.StartsWith('<')) { $hex = $Token.Trim('<', '>') -replace '\s', '' }
        else {
            # Literal strings allow escaped parentheses, octal bytes and line continuations.
            $literal = $Token.Substring(1, $Token.Length - 2) -replace "`r`n?", "`n"
            $literal = [regex]::Replace($literal, '\\([0-7]{1,3}|\n|.)', {
                param($escape)
                $value = $escape.Groups[1].Value
                if ($value -match '^[0-7]{1,3}$') { return [string][char]([Convert]::ToInt32($value, 8) -band 255) }
                switch -CaseSensitive ($value) {
                    'n' { return "`n" }; 'r' { return "`r" }; 't' { return "`t" }
                    'b' { return "`b" }; 'f' { return "`f" }; "`n" { return '' }
                    default { return $value }
                }
            })
            $hex = [BitConverter]::ToString($latin1.GetBytes($literal)).Replace('-', '')
        }
        if ($hex.Length % 2) { $hex += '0' }
        if ($hex.Length % $Font.width) { throw 'Incomplete PDF character code.' }
        $decoded = [Text.StringBuilder]::new()
        for ($i = 0; $i -lt $hex.Length; $i += $Font.width) {
            $code = $hex.Substring($i, $Font.width)
            if (-not $Font.map.ContainsKey($code)) { throw "PDF Unicode map has no entry for character $code." }
            [void]$decoded.Append($Font.map[$code])
        }
        return $decoded.ToString()
    }

    # Follow /Kids rather than file/object-number order, including inherited resources.
    $visited = @{}
    function Get-PdfPages([string] $Reference, [string] $Resources = '') {
        if ($visited.ContainsKey($Reference)) { throw 'Repeated or cyclic PDF page reference.' }
        $visited[$Reference] = $true
        $body = (Get-PdfObject $Reference).body
        if ($body -match '/Resources\s+(\d+\s+\d+\s+R)') { $Resources = (Get-PdfObject $Matches[1]).body }
        elseif ($body -match '/Resources\s*<<') { $Resources = $body }
        if ($body -match '/Type\s*/Page\b') { return @{ body = $body; resources = $Resources } }
        if ($body -notmatch '(?s)/Kids\s*\[(.*?)\]') { throw 'Unsupported PDF page tree.' }
        foreach ($child in [regex]::Matches($Matches[1], '\d+\s+\d+\s+R')) { Get-PdfPages $child.Value $Resources }
    }

    $catalogs = @($objects.Values | Where-Object { $_.body -match '/Type\s*/Catalog\b' })
    if ($catalogs.Count -ne 1 -or $catalogs[0].body -notmatch '/Pages\s+(\d+\s+\d+\s+R)') { throw 'Unsupported or invalid PDF catalog.' }
    $pages = @(Get-PdfPages $Matches[1])
    $pageTexts = [Collections.Generic.List[string]]::new()
    # Balanced groups keep parentheses inside literal strings together. Tokens
    # are data, never PowerShell expressions to execute.
    $tokenPattern = [regex]'(?s)%[^\r\n]*|\((?:\\(?:\r\n|.)|[^\\()]|\((?<nest>)|\)(?<-nest>))*(?(nest)(?!))\)|<[\da-fA-F\s]*>|/[^\s<>\[\]()/{}%]+|[^\s<>\[\]()/{}%]+|[^\s]'
    foreach ($page in $pages) {
        $fonts = @{}
        $resources = $page.resources
        if ($resources -match '/Font\s+(\d+\s+\d+\s+R)') { $fontBody = (Get-PdfObject $Matches[1]).body }
        elseif ($resources -match '(?s)/Font\s*<<(.*?)>>') { $fontBody = $Matches[1] }
        else { $fontBody = '' }
        foreach ($entry in [regex]::Matches($fontBody, '/([^\s/<>]+)\s+(\d+\s+\d+\s+R)')) { $fonts[$entry.Groups[1].Value] = $entry.Groups[2].Value }
        $xObjects = $resources
        if ($resources -match '/XObject\s+(\d+\s+\d+\s+R)') { $xObjects = (Get-PdfObject $Matches[1]).body }
        $contents = ''
        if ($page.body -match '(?s)/Contents\s*(\[.*?\]|\d+\s+\d+\s+R)') {
            $parts = foreach ($reference in [regex]::Matches($Matches[1], '\d+\s+\d+\s+R')) { Get-PdfStream $reference.Value }
            $contents = $parts -join "`n"
        }
        $text = [Text.StringBuilder]::new()
        $operands = [Collections.Generic.List[string]]::new()
        $inText = $false
        $font = $null
        $fontStack = [Collections.Generic.Stack[object]]::new()
        foreach ($tokenMatch in $tokenPattern.Matches($contents)) {
            $token = $tokenMatch.Value
            if ($token.StartsWith('%')) { continue }
            if ($token -match '^(?:/|\(|<[\da-fA-F\s]*>$|[\[\]]$|[-+\d.])') { $operands.Add($token); continue }
            $newline = $false
            switch -CaseSensitive ($token) {
                'BT' { $inText = $true }
                'ET' { $inText = $false; $newline = $true }
                'q' { $fontStack.Push($font) }
                'Q' { if ($fontStack.Count) { $font = $fontStack.Pop() } }
                'Tf' {
                    if ($operands.Count -ne 2 -or -not $fonts.ContainsKey($operands[0].TrimStart('/'))) { throw 'Unknown PDF text font.' }
                    $font = Get-PdfFontMap $fonts[$operands[0].TrimStart('/')]
                }
                { $_ -cin @('Tj', 'TJ', "'", '"') } {
                    if ($inText) {
                        if ($token -in @("'", '"') -and $text.Length) { [void]$text.AppendLine() }
                        foreach ($operand in $operands) {
                            if ($operand.StartsWith('<') -or $operand.StartsWith('(')) { [void]$text.Append((ConvertFrom-PdfText $operand $font)) }
                            elseif ($token -ceq 'TJ' -and $operand -match '^-\d' -and
                                [double]::Parse($operand, [Globalization.CultureInfo]::InvariantCulture) -le -100) { [void]$text.Append(' ') }
                        }
                    }
                }
                { $_ -cin @('Tm', 'T*', 'Td', 'TD') } {
                    $newline = $inText -and ($token -cin @('Tm', 'T*') -or ($operands.Count -eq 2 -and
                        [double]::Parse($operands[1], [Globalization.CultureInfo]::InvariantCulture) -ne 0))
                }
                'Do' {
                    # Images may be skipped, but silently skipping a Form could lose text.
                    if ($operands.Count -and $xObjects -match ('/' + [regex]::Escape($operands[0].TrimStart('/')) + '\s+(\d+\s+\d+\s+R)')) {
                        if ((Get-PdfObject $Matches[1]).body -match '/Subtype\s*/Form\b') { throw 'PDF Form XObjects are not supported.' }
                    }
                }
                'BI' { throw 'PDF inline images are not supported.' }
            }
            if ($newline -and $text.Length -and $text[$text.Length - 1] -ne "`n") { [void]$text.AppendLine() }
            $operands.Clear()
        }
        $pageTexts.Add($text.ToString().Trim())
    }
    $result = ($pageTexts -join ([Environment]::NewLine + [Environment]::NewLine)).Trim()
    if (-not $result) { throw 'No extractable PDF text found. For image/layout expectations, render this existing PDF and inspect/assert its pixels; OCR is needed only for text extraction and is not supported here. A PDF header is not content verification.' }
    return $result
}
