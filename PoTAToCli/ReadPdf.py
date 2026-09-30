"""Optional, read-only PDF text extraction. Invoked as a file, never inline code."""
import json
import sys

try:
    from pypdf import PdfReader
    reader = PdfReader(sys.argv[1])
    if reader.is_encrypted:
        raise ValueError('Encrypted PDF is unsupported')
    if len(reader.pages) > 500:
        raise ValueError('PDF exceeds the 500-page extraction bound')
    text = '\n'.join(page.extract_text() or '' for page in reader.pages)
    if not text.strip():
        raise ValueError('PDF contains no extractable text')
    print(json.dumps({'ok': True, 'text': text}, ensure_ascii=True))
except Exception as exc:
    print(json.dumps({'ok': False, 'error': str(exc)}, ensure_ascii=True))
    sys.exit(1)
