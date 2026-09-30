"""Optional, read-only PDF text extraction. Invoked as a file, never inline code."""
import json
import sys
import io
import time

try:
    from pypdf import PdfReader
    timeout_ms = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    if not 0 <= timeout_ms <= 60000:
        raise ValueError('PDF TimeoutMs must be 0..60000')
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        try:
            with open(sys.argv[1], 'rb') as source:
                payload = source.read()
            if not payload.rstrip(b'\x00\t\n\f\r ').endswith(b'%%EOF'):
                raise ValueError('Incomplete PDF: missing final EOF marker. Wait for export completion before reading.')
            reader = PdfReader(io.BytesIO(payload))
            break
        except OSError as exc:
            if getattr(exc, 'winerror', None) not in (32, 33) or time.monotonic() >= deadline:
                raise
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
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
