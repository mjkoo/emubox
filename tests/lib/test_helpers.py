# Pure helpers the VM test scripts share, spliced into each script as text.
# Every function here takes and returns plain strings and containers, never
# the test driver's `machine`, so each script keeps its own machine-bound
# wrappers and this file needs nothing from them.


def _is_header(stripped):
    return stripped.startswith("[") and stripped.endswith("]")


def ini_value(text, section, key):
    """The value of the first `key = value` line under `[section]`, or None
    if it is absent.

    `section=None` reads a sectionless file (RetroArch's flat config) by
    never leaving the "in section" state. A plain reader, mirroring
    emubox-prepare's own section matching without importing it.
    """
    in_section = section is None
    for line in text.splitlines():
        stripped = line.strip()
        if _is_header(stripped):
            in_section = stripped[1:-1] == section
            continue
        if not in_section or "=" not in stripped:
            continue
        k, _, v = stripped.partition("=")
        if k.strip() == key:
            return v.strip()
    return None


def ini_sections(text):
    """Every `[section]` header's name, in file order."""
    return [
        line.strip()[1:-1] for line in text.splitlines() if _is_header(line.strip())
    ]


def ini_section_keys(text, section):
    """Every key name present under `[section]`, in the order it appears -
    used to assert a recreated file's key set exactly, rather than merely a
    subset of it."""
    keys = []
    in_section = False
    for line in text.splitlines():
        stripped = line.strip()
        if _is_header(stripped):
            in_section = stripped[1:-1] == section
            continue
        if not in_section or "=" not in stripped:
            continue
        keys.append(stripped.partition("=")[0].strip())
    return keys


def _locate(lines, section, key):
    """The index of the first `key` line under `[section]`, or None; and
    the index just past the end of the first `[section]` body, or None if
    there is no such section."""
    in_section = False
    found = None
    end = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if _is_header(stripped):
            if in_section and end is None:
                end = i
            in_section = stripped[1:-1] == section
            continue
        if (
            in_section
            and found is None
            and "=" in stripped
            and stripped.partition("=")[0].strip() == key
        ):
            found = i
    if in_section and end is None:
        end = len(lines)
    return found, end


def ini_edited(text, section, key, value=None):
    """`text` with the first `key` line under `[section]` rewritten to
    `value`, or removed when `value` is None.

    The key must already be assigned there: a test that alters or removes a
    key that was never written would otherwise pass without testing
    anything.
    """
    lines = text.splitlines(keepends=True)
    found, _ = _locate(lines, section, key)
    action = "remove" if value is None else "alter"
    assert found is not None, f"no [{section}] {key} line to {action}"
    lines[found : found + 1] = [] if value is None else [f"{key} = {value}\n"]
    return "".join(lines)


def ini_inserted(text, section, key, value):
    """`text` with a new `key = value` line at the end of an existing
    `[section]`'s body."""
    lines = text.splitlines(keepends=True)
    _, end = _locate(lines, section, key)
    assert end is not None, f"no [{section}] section to insert into"
    if end == len(lines) and lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines[end:end] = [f"{key} = {value}\n"]
    return "".join(lines)


def status_sections(output):
    """Split emubox-status's output into one block per section, keyed by
    name.

    Each section opens with a "name: status" header at the left margin and
    indents everything the reporter said beneath it, so a header is any
    non-blank line that does not start with whitespace, and a reporter's
    own blank lines stay in its block.
    """
    sections = {}
    current = None
    for line in output.splitlines():
        if line and not line[0].isspace():
            current = line.split(":", 1)[0]
            sections[current] = [line]
        elif current is not None:
            sections[current].append(line)
    return {name: "\n".join(lines) for name, lines in sections.items()}
