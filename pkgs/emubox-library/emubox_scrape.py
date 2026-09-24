#!/usr/bin/env python3
"""Fetch artwork for ROM folders as the frontend account."""

import sys

sys.path.insert(0, "@LIBDIR@")

from library import scrape_main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(scrape_main())
