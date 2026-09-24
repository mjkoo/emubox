#!/usr/bin/env python3
"""Check the library integration against the pinned upstream source trees."""

import argparse
import json
import re
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def source(root: Path, relative: str) -> str:
    return (root / relative).read_text()


def declared_cli(cli: str) -> tuple[set[str], set[str]]:
    options = set(re.findall(r'QCommandLineOption\s+\w+\s*\(\s*"([\w-]+)"', cli))
    # Help and version are registered by Qt, not used by the library.
    flags_section = cli.split('if (subCmd == "flags") {', 2)[-1]
    flags_section = flags_section.split("return m;", 1)[0]
    flags = set(re.findall(r'\{"([a-z][a-z0-9]*)",', flags_section))
    return options, flags


def check_platform_map(platforms: set[str], mapping: dict[str, str]) -> None:
    require(bool(mapping), "platform map is empty")
    for folder, platform in mapping.items():
        require(
            isinstance(folder, str) and isinstance(platform, str),
            "platform map must contain strings",
        )
        require(
            platform in platforms, f"{folder}: unknown Skyscraper platform {platform!r}"
        )


def check_vector(options: set[str], flags: set[str], argv: list[str]) -> None:
    require(
        isinstance(argv, list) and all(isinstance(arg, str) for arg in argv),
        "vector must be strings",
    )
    idx = 0
    while idx < len(argv):
        option = argv[idx]
        require(option.startswith("-"), f"unexpected positional argument {option!r}")
        name = option.lstrip("-")
        require(name in options, f"undeclared Skyscraper option {option!r}")
        require(idx + 1 < len(argv), f"missing value for {option}")
        value = argv[idx + 1]
        if name == "flags":
            for flag in value.split(","):
                require(flag in flags, f"undeclared Skyscraper flag {flag!r}")
        idx += 2


def contains_all(content: str, relative: str, *needles: str) -> None:
    for needle in needles:
        require(needle in content, f"{relative}: missing source contract {needle!r}")


def check_sources(
    sky: Path, esde: Path, nixpkgs: Path
) -> tuple[set[str], set[str], set[str]]:
    recipe = source(nixpkgs, "pkgs/by-name/sk/skyscraper/package.nix")
    contains_all(
        recipe,
        "pkgs/by-name/sk/skyscraper/package.nix",
        'version = "3.18.5"',
        "enableXdg ? false",
        "postPatch = lib.optionalString enableXdg",
    )
    peas = json.loads(source(sky, "peas.json"))
    require(
        isinstance(peas, dict) and len(peas) >= 100, "Skyscraper platform table changed"
    )
    platforms = set(peas)
    require(
        {"3ds", "megadrive", "pcengine", "pcenginecd"} <= platforms,
        "expected platform names changed",
    )
    require(
        not {"n3ds", "genesis", "tg16", "tg-cd"} & platforms,
        "ES-DE aliases became platforms",
    )

    cli = source(sky, "src/cli.cpp")
    options, flags = declared_cli(cli)
    require(
        {"p", "s", "f", "c", "i", "d", "g", "o", "flags"} <= options,
        "required CLI option missing",
    )
    require(
        "stderr" not in options, "--stderr was added; review wrapper output handling"
    )
    require(
        {
            "unattend",
            "onlymissing",
            "skipped",
            "videos",
            "manuals",
            "skipexistingcovers",
            "skipexistingmanuals",
            "skipexistingbackcovers",
            "skipexistingfanarts",
            "skipexistingmarquees",
            "skipexistingscreenshots",
            "skipexistingtextures",
            "skipexistingvideos",
            "skipexistingwheels",
        }
        <= flags,
        "required CLI flag missing",
    )
    contains_all(
        cli,
        "src/cli.cpp",
        "parser->addOption(pOption)",
        "parser->addOption(flagsOption)",
        "'import'",
        "'screenscraper'",
    )

    config = source(sky, "src/config.cpp")
    contains_all(
        config,
        "src/config.cpp",
        "#ifndef XDG",
        'QDir::homePath() % "/." % appFolder',
        "void Config::setupUserConfig()",
        "QDir::setCurrent(skyDir.absolutePath())",
        'QString localEtcPath = QString(SYSCONFDIR "/skyscraper/")',
        "copyFile(localEtcPath % src, tgt, isPristine,",
    )
    sky_build = source(sky, "skyscraper.pro")
    contains_all(sky_build, "skyscraper.pro", "#DEFINES+=XDG")
    require(
        "\nDEFINES+=XDG" not in sky_build, "upstream source now enables XDG by default"
    )

    main = source(sky, "src/main.cpp")
    contains_all(
        main,
        "src/main.cpp",
        "sigaction(SIGINT, &sigIntHandler, NULL)",
        "if (signal == SIGINT)",
    )
    require(
        "sigaction(SIGTERM" not in main,
        "Skyscraper now handles SIGTERM; review process cleanup",
    )
    sky_sources = "\n".join(path.read_text() for path in (sky / "src").glob("*.cpp"))
    require(
        not re.search(r"\b(flock|lockf|QLockFile)\s*\(", sky_sources),
        "Skyscraper gained an inter-process lock; review wrapper locking",
    )

    scraper = source(sky, "src/skyscraper.cpp")
    contains_all(
        scraper,
        "src/skyscraper.cpp",
        "frontend->loadOldGameList(gameListFileString)",
        "if (config.skipped)",
        "gameEntries.append(entry)",
        "gameListFile.open(QIODevice::WriteOnly)",
        "gameListFile.write(finalOutput.toUtf8())",
    )
    entry = source(sky, "src/gameentry.cpp")
    for tag in (
        "favorite",
        "hidden",
        "kidgame",
        "lastplayed",
        "playcount",
        "sortname",
        "altemulator",
        "completed",
        "broken",
        "controller",
        "collectionsortname",
        "hidemetadata",
        "nogamecount",
        "nomultiscrape",
    ):
        require(f'"{tag}"' in entry, f"src/gameentry.cpp: missing preserved tag {tag}")
    esde_output = source(sky, "src/esde.cpp")
    contains_all(
        esde_output,
        "src/esde.cpp",
        "GameEntry::Format::ESDE",
        "return QStringList()",
        "GameEntry::COVER",
        "GameEntry::MANUAL",
        "GameEntry::MARQUEE",
        "GameEntry::SCREENSHOT",
        "GameEntry::VIDEO",
        "GameEntry::WHEEL",
    )
    require(
        "GameEntry::TEXTURE" not in esde_output, "ES-DE output now includes textures"
    )
    media = source(sky, "src/abstractfrontend.cpp")
    contains_all(
        media,
        "src/abstractfrontend.cpp",
        "supportedMedia() & (savedMedia ^ GameEntry::MEDIA)",
        "if (!config->manuals)",
        "if (!config->videos)",
        "game.wheelFile",
        "getTargetFilePath(GameEntry::MARQUEE",
        "QFile::copy(cacheFn, tgt)",
    )

    systems = source(esde, "es-app/src/SystemData.cpp")
    contains_all(
        systems,
        "es-app/src/SystemData.cpp",
        'system.child("command")',
        'system.child("extension")',
        "sSystemVector.emplace_back(newSys)",
        '"Parsed configuration for "',
        '"Total game count: "',
        '"Parsing systems configuration file \\""',
    )
    launch = source(esde, "es-app/src/FileData.cpp")
    contains_all(
        launch,
        "es-app/src/FileData.cpp",
        '"Launching game \\""',
        "emulator = findEmulator(command, false)",
        'Utils::String::replace(command, "%ROM%", romPath)',
        "Utils::Platform::launchGameUnix(command, startDirectory",
    )
    require(
        launch.index("emulator = findEmulator(command, false)")
        < launch.index('Utils::String::replace(command, "%ROM%", romPath)'),
        "ES-DE launch resolution order changed",
    )
    frontend_main = source(esde, "es-app/src/main.cpp")
    contains_all(
        frontend_main,
        "es-app/src/main.cpp",
        "SystemData::loadConfig()",
        "InputManager::getInstance().parseEvent(event)",
        "if (event.type == SDL_QUIT)",
    )
    return platforms, options, flags


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skyscraper-source", required=True, type=Path)
    parser.add_argument("--esde-source", required=True, type=Path)
    parser.add_argument("--nixpkgs-source", required=True, type=Path)
    parser.add_argument("--platform-map", type=Path)
    parser.add_argument("--vectors", type=Path)
    args = parser.parse_args()

    platforms, options, flags = check_sources(
        args.skyscraper_source, args.esde_source, args.nixpkgs_source
    )
    check_platform_map(
        platforms,
        {
            "n3ds": "3ds",
            "genesis": "megadrive",
            "tg16": "pcengine",
            "tg-cd": "pcenginecd",
        },
    )
    try:
        check_platform_map(platforms, {"negative-control": "not-a-platform"})
    except AssertionError:
        pass
    else:
        raise AssertionError("invalid platform negative control passed")

    check_vector(
        options,
        flags,
        [
            "-p",
            "3ds",
            "-s",
            "screenscraper",
            "-c",
            "/config",
            "-i",
            "/roms",
            "-d",
            "/cache",
            "--flags",
            "unattend,onlymissing,videos,manuals",
        ],
    )
    check_vector(
        options,
        flags,
        [
            "-p",
            "3ds",
            "-f",
            "esde",
            "-c",
            "/config",
            "-i",
            "/roms",
            "-d",
            "/cache",
            "-g",
            "/work",
            "-o",
            "/media",
            "--flags",
            "unattend,skipped,videos,manuals,skipexistingcovers,skipexistingmanuals,skipexistingbackcovers,skipexistingfanarts,skipexistingmarquees,skipexistingscreenshots,skipexistingtextures,skipexistingvideos,skipexistingwheels",
        ],
    )
    for invalid in (["--stderr", "yes"], ["--flags", "unattend,not-a-flag"]):
        try:
            check_vector(options, flags, invalid)
        except AssertionError:
            pass
        else:
            raise AssertionError(
                f"invalid option/flag negative control passed: {invalid}"
            )

    if args.platform_map:
        mapping = json.loads(args.platform_map.read_text())
        check_platform_map(platforms, mapping)
        try:
            check_platform_map(
                platforms, {**mapping, "negative-control": "not-a-platform"}
            )
        except AssertionError:
            pass
        else:
            raise AssertionError("invalid platform added to exported map was accepted")
    if args.vectors:
        vectors = json.loads(args.vectors.read_text())
        require(
            isinstance(vectors, dict) and bool(vectors),
            "vectors export must be a nonempty object",
        )
        for label, vector in vectors.items():
            try:
                check_vector(options, flags, vector)
            except AssertionError as error:
                raise AssertionError(f"{label}: {error}") from error
            try:
                check_vector(options, flags, [*vector, "--stderr", "yes"])
            except AssertionError:
                pass
            else:
                raise AssertionError(
                    f"{label}: --stderr added to exported vector was accepted"
                )
    print(
        f"Pinned source contracts passed: {len(platforms)} platforms, {len(options)} options, {len(flags)} flags"
    )


if __name__ == "__main__":
    main()
