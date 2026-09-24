#!/usr/bin/env python3
"""Generate pending gamelists before the frontend starts."""

import sys

sys.path.insert(0, "@LIBDIR@")

from library import generate_main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(generate_main())
