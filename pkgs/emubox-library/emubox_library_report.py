#!/usr/bin/env python3
"""Report game library state to the operator status command."""

import sys

sys.path.insert(0, "@LIBDIR@")

from library import report_main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(report_main())
