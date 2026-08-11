#!/usr/bin/env python3
"""Container health probe for vLLM's OpenAI server."""

from urllib.error import URLError
from urllib.request import urlopen

try:
    with urlopen("http://127.0.0.1:8000/health", timeout=5) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except (OSError, URLError):
    raise SystemExit(1)
