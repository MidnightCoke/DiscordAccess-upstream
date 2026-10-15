#!/usr/bin/env python3
"""The four assets of a DiscordAccess macOS GitHub Release (`macos-v<version>`, stage 3).

    notices  Derives macos/licenses/engine-source-manifest.json and ENGINE-THIRD-PARTY-NOTICES.txt from the verified
             Windows collection in licenses/, keeping exactly the components the macOS engine records in its build
             evidence (go-version-m.txt). The macOS engine is built from the same main source, Go, locks and overlay.
    fetch    Downloads the source archives those components name into a cache, each checked by SHA-256, size and, for
             a Go module, its h1 content hash.
    package  Builds the release assets into a new folder from a clean HEAD, the app build-app.sh made from it, the
             current engine build evidence and the cache: the runtime ZIP, the corresponding engine source ZIP, the
             source manifest and SHA256SUMS.txt.

The shared validation is scripts/ReleaseChecks.py, used read-only. Nothing it packages is run, nothing is published
and no credential is read; only `fetch` uses the network. Python 3.11 or newer.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import plistlib
import re
import ssl
import stat
import subprocess
import sys
import urllib.request
import zipfile

sys.dont_write_bytecode = True
MACOS = Path(os.path.realpath(__file__)).parent.parent
REPO = MACOS.parent
sys.path.insert(0, str(REPO / "scripts"))
import ReleaseChecks as checks  # noqa: E402

WINDOWS_MANIFEST = "licenses/engine-source-manifest.json"
WINDOWS_AGGREGATE = "licenses/ENGINE-THIRD-PARTY-NOTICES.txt"
MANIFEST = "macos/licenses/engine-source-manifest.json"
AGGREGATE = "macos/licenses/ENGINE-THIRD-PARTY-NOTICES.txt"
NOTICES = "macos/licenses/THIRD_PARTY_NOTICES.txt"
RECIPE = "macos/scripts/build-engine.py"
USAGE = "macos/docs/OKU-BENI.md"
DEFAULT_CACHE = MACOS / "work" / "license-source-cache"
SEPARATOR = "=" * 78
EVIDENCE_FILES = ("build-metadata.json", "compiled-packages.txt", "go-version-m.txt", "selected-modules.txt",
                  "source-unit-tests.txt", "upstream-go.mod", "upstream-go.sum")
CA_FILE = "/etc/ssl/cert.pem"
AGGREGATE_HEADER = """sing-box 1.14.3-discordaccess.2 — dependency notices for the DiscordAccess macOS build (darwin/arm64)

Collected from pinned source archives matching the distributed engine build information.
Original notice contents are reproduced below; archive paths identify their scope.
Including source/test/platform notices is conservative and does not imply that every file is linked or used.
The JSON manifest records source URLs, versions, SHA256, and verified Go h1 content hashes.
The macOS engine links no native component: the Windows-only Wintun DLLs and WireGuard loader are absent.
Hash-pinned main-source HTTP limits, dependency locks and build instructions accompany this build.
These blocks were selected, unchanged, from the verified Windows collection for exactly the modules the macOS
engine records; no source, dependency, build script or program was executed to select them.
"""


def recipe_pins() -> dict:
    """The recipe's reviewed literal pins, read as text and never executed."""
    text = checks.read(REPO / RECIPE, REPO).decode("utf-8")
    pins = {}
    for key in ("SOURCE_COMMIT", "SOURCE_SHA256", "GO_VERSION", "ENGINE_VERSION", "PATCH_MANIFEST_SHA256", "LOCK_MOD_SHA256",
                "LOCK_SUM_SHA256", "BUILD_TAGS", "ENGINE_SHA256", "ENGINE_CDHASH"):
        found = re.findall(r'^' + key + r' = "([^"\n]+)"$', text, re.M)
        if len(found) != 1:
            raise ValueError("Recipe pin is missing or ambiguous: " + key)
        pins[key] = found[0]
    size = re.findall(r"^ENGINE_BYTES = ([0-9]+)$", text, re.M)
    if len(size) != 1:
        raise ValueError("Recipe engine size pin is missing or ambiguous")
    pins["ENGINE_BYTES"] = checks.byte_count(int(size[0]))
    return pins


def verify_evidence(evidence: Path, pins: dict) -> tuple[dict[str, bytes], bytes]:
    """The current build's checksum-bound evidence: the exact current recipe, the pinned engine and passing source tests."""
    evidence = checks.bounded_path(evidence)
    checksum_bytes = checks.read(evidence / "SHA256SUMS.txt", evidence)
    sums = checks.checksums(checksum_bytes, flat=True)
    if set(sums) != set(EVIDENCE_FILES) | {"sing-box"}:
        raise ValueError("Build evidence checksum inventory differs")
    files = {name: checks.read(evidence / name, evidence, sums[name]) for name in sums}
    engine = files.pop("sing-box")
    if checks.sha(engine) != pins["ENGINE_SHA256"] or len(engine) != pins["ENGINE_BYTES"]:
        raise ValueError("Build evidence engine differs from the pinned engine")
    metadata = checks.parse_json(files["build-metadata.json"])
    expected = {"schema": 1, "target": "darwin/arm64", "engine_version": pins["ENGINE_VERSION"], "engine_sha256": pins["ENGINE_SHA256"],
                "engine_bytes": pins["ENGINE_BYTES"], "engine_cdhash": pins["ENGINE_CDHASH"], "go_version": pins["GO_VERSION"],
                "main_source_commit": pins["SOURCE_COMMIT"], "source_archive_sha256": pins["SOURCE_SHA256"],
                "main_source_patch_sha256": pins["PATCH_MANIFEST_SHA256"], "lock_go_mod_sha256": pins["LOCK_MOD_SHA256"],
                "lock_go_sum_sha256": pins["LOCK_SUM_SHA256"], "build_tags": pins["BUILD_TAGS"],
                "build_script_sha256": checks.sha(checks.read(REPO / RECIPE, REPO)), "engine_pin_enforced": True,
                "source_unit_tests_ran": True, "engine_executed": False}
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError("Build evidence differs from the current recipe: " + key)
    for name, data in files.items():
        checks.public_report(data)
    if "ok" not in files["source-unit-tests.txt"].decode("utf-8") or "FAIL" in files["source-unit-tests.txt"].decode("utf-8"):
        raise ValueError("Build evidence does not show passing source tests")
    return files, checksum_bytes


def recorded_modules(go_version_m: bytes) -> tuple[str, dict[str, tuple[str, str]], dict[str, str]]:
    """The Go version, linked modules (version, h1) and build settings the engine records."""
    lines = go_version_m.decode("utf-8").splitlines()
    head = re.fullmatch(r"sing-box: (go[0-9]+\.[0-9]+(?:\.[0-9]+)?)", lines[0]) if lines else None
    if head is None:
        raise ValueError("Engine build information is malformed")
    modules, build = {}, {}
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) == 5 and fields[:2] == ["", "dep"] and fields[2] not in modules and fields[4].startswith("h1:"):
            modules[fields[2]] = (fields[3], fields[4])
        elif len(fields) == 3 and fields[:2] == ["", "build"] and "=" in fields[2]:
            key, _, value = fields[2].partition("=")
            build[key] = value
        elif not (fields[:2] in (["", "path"], ["", "mod"])):
            raise ValueError("Engine build information has an unexpected line (a replaced module?)")
    return head[1], modules, build


def derive(evidence_files: dict[str, bytes], pins: dict) -> tuple[bytes, bytes]:
    """The macOS source manifest and aggregate notices, from the verified Windows collection."""
    windows_bytes = checks.read(REPO / WINDOWS_MANIFEST, REPO)
    aggregate_bytes = checks.read(REPO / WINDOWS_AGGREGATE, REPO)
    windows = checks.parse_json(windows_bytes)
    checks.manifest_identity(windows)
    checks.validate_aggregate(aggregate_bytes, windows["components"])
    go_version, modules, build = recorded_modules(evidence_files["go-version-m.txt"])
    if go_version != windows["go_version"] or go_version != pins["GO_VERSION"] or windows["main_source_commit"] != pins["SOURCE_COMMIT"]:
        raise ValueError("The macOS engine's Go or main source differs from the verified collection")
    if (build.get("GOOS"), build.get("GOARCH"), build.get("CGO_ENABLED"), build.get("-tags"), build.get("-trimpath")) != \
            ("darwin", "arm64", "0", pins["BUILD_TAGS"], "true"):
        raise ValueError("The macOS engine's build settings differ from the recipe")
    recipe = windows["build_recipe"]
    if (recipe["go_mod_sha256"], recipe["go_sum_sha256"], recipe["patch_manifest"]["sha256"]) != \
            (pins["LOCK_MOD_SHA256"], pins["LOCK_SUM_SHA256"], pins["PATCH_MANIFEST_SHA256"]):
        raise ValueError("The macOS recipe's locks or overlay differ from the verified collection")
    components, matched = [], set()
    for component in windows["components"]:
        module = component["module"]
        if module == "Go standard library/runtime" or (module == "github.com/sagernet/sing-box" and "expected_go_h1" not in component):
            components.append(component)
        elif module in modules:
            version, h1 = modules[module]
            if component["version"] != version or component["expected_go_h1"] != h1 or component["verified_go_h1"] != h1:
                raise ValueError("Module identity differs from the verified collection: " + module)
            components.append(component)
            matched.add(module)
    if matched != set(modules):
        raise ValueError("The verified collection lacks modules the macOS engine records: " + ", ".join(sorted(set(modules) - matched)))
    notices = sum(len(component["notices"]) for component in components)
    manifest = {
        "schema": 1, "platform": "darwin/arm64", "engine_version": windows["engine_version"],
        "engine_sha256": pins["ENGINE_SHA256"], "engine_bytes": pins["ENGINE_BYTES"], "engine_cdhash": pins["ENGINE_CDHASH"],
        "go_version": go_version, "build_settings": dict(sorted(build.items())), "main_source_commit": windows["main_source_commit"],
        "build_recipe": {"script": RECIPE, "script_sha256": checks.sha(checks.read(REPO / RECIPE, REPO)),
                         "go_mod": recipe["go_mod"], "go_mod_sha256": recipe["go_mod_sha256"],
                         "go_sum": recipe["go_sum"], "go_sum_sha256": recipe["go_sum_sha256"],
                         "patch_manifest": recipe["patch_manifest"], "patch_files": recipe["patch_files"],
                         "note": "These exact main-source HTTP limits, dependency locks and build options produce the macOS engine. "
                                 "Corresponding modified sources, tests and upstream notices must accompany binary distribution."},
        "module_count": len(matched), "notice_count": notices, "native_notice_count": 0, "total_notice_count": notices,
        "notice_format": "Each aggregate_marker identifies its BEGIN/END block in macos/licenses/ENGINE-THIRD-PARTY-NOTICES.txt. "
                         "Notice text is UTF-8, omitting a leading UTF-8 BOM if present. Original archive-file SHA256 and "
                         "aggregate-text SHA256 are both retained. No separate notice text files are required.",
        "hash_algorithm_reference": windows["hash_algorithm_reference"],
        "scope": "All legal notice filenames found in exact source archives of the components the macOS engine records, conservatively "
                 "including source/tests/platform files. The macOS engine links no native component. No claim of legal opinion or "
                 "complete package-level attribution.",
        "derived_from": {"manifest": WINDOWS_MANIFEST, "manifest_sha256": checks.sha(windows_bytes),
                         "aggregate": WINDOWS_AGGREGATE, "aggregate_sha256": checks.sha(aggregate_bytes)},
        "components": components, "native_components": [],
    }
    checks.manifest_identity(manifest)
    text = aggregate_bytes.decode("utf-8")
    preamble = text[:text.index("\n" + SEPARATOR + "\n")]
    overlay = preamble[preamble.index("Reviewed main-source modifications notice"):].rstrip("\n")
    sections = [AGGREGATE_HEADER + "\n" + overlay + "\n"]
    for component in components:
        blocks = []
        for notice in component["notices"]:
            marker = re.escape(notice["aggregate_marker"])
            found = re.findall(r"^--- BEGIN NOTICE " + marker + r" ---\nArchive path: " + re.escape(notice["archive_path"]) +
                               r"\nOriginal file SHA256: " + re.escape(notice["sha256"]) + r"\n\n(.*?)\n--- END NOTICE " + marker + r" ---$",
                               text, re.M | re.S)
            if len(found) != 1:
                raise ValueError("Notice block is missing from the verified collection: " + notice["aggregate_marker"])
            blocks.append("--- BEGIN NOTICE " + notice["aggregate_marker"] + " ---\nArchive path: " + notice["archive_path"] +
                          "\nOriginal file SHA256: " + notice["sha256"] + "\n\n" + found[0] + "\n--- END NOTICE " + notice["aggregate_marker"] + " ---")
        sections.append(SEPARATOR + "\n" + component["module"] + " " + component["version"] + "\nSource: " + component["source_url"] +
                        "\n\n" + "\n\n".join(blocks) + "\n")
    aggregate = "\n".join(sections).encode("utf-8")
    checks.validate_aggregate(aggregate, components)
    return checks.json_bytes(manifest), aggregate


def archive_name(component: dict) -> tuple[str, str]:
    """The cache file name and source package path of a component (as Windows `source_payloads` names them)."""
    identifier = component["component_id"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", identifier):
        raise ValueError("Unsafe source component ID")
    if "expected_go_h1" in component:
        return identifier + ".zip", "sources/modules/" + identifier + ".zip"
    if component["module"] == "github.com/sagernet/sing-box":
        return identifier + ".zip", "sources/main/sing-box-upstream-" + component["commit"] + ".zip"
    if component["module"] == "Go standard library/runtime":
        return identifier + ".src.tar.gz", "sources/go/" + identifier + ".src.tar.gz"
    raise ValueError("Unexpected source component")


def verify_archive(data: bytes, component: dict) -> dict[str, bytes] | None:
    """Checks an archive's content against its component; returns the upstream main source's files."""
    if checks.sha(data) != checks.digest(component["source_archive_sha256"]) or len(data) != component["source_archive_bytes"]:
        raise ValueError("Source archive differs from its manifest record: " + component["component_id"])
    if "expected_go_h1" in component:
        checks.verify_module(data, component)
        return None
    if component["module"] == "Go standard library/runtime":
        checks.verify_go(data, component)
        return None
    upstream = checks.zip_inventory(data, "sing-box-" + component["commit"] + "/")
    checks.verify_notices(upstream, component)
    return upstream


def fetch(cache: Path) -> dict:
    manifest = checks.parse_json(checks.read(REPO / MANIFEST, REPO))
    cache.mkdir(parents=True, exist_ok=True)
    context = ssl.create_default_context(cafile=CA_FILE)
    fetched, present = 0, 0
    for component in manifest["components"]:
        filename, _ = archive_name(component)
        target = cache / filename
        if target.exists():
            verify_archive(checks.read(target, cache), component)
            present += 1
            continue
        url = component["source_url"]
        checks.source_url(url)
        request = urllib.request.Request(url, headers={"User-Agent": "DiscordAccess release source fetch"})
        with urllib.request.urlopen(request, context=context, timeout=120) as response:
            data = response.read(component["source_archive_bytes"] + 1)
        verify_archive(data, component)
        partial = cache / (filename + ".partial")
        with partial.open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(partial, target)
        fetched += 1
    return {"cache": str(cache), "components": len(manifest["components"]), "fetched": fetched, "already_present": present}


def deterministic_zip(entries: dict[str, tuple[bytes, int]], stored: tuple[str, ...] = ()) -> bytes:
    """A ZIP with fixed times, sorted entries, Unix modes and the bytes checked back."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, (data, mode) in sorted(entries.items()):
            info = zipfile.ZipInfo(checks.clean_name(name.rstrip("/")) + ("/" if name.endswith("/") else ""), checks.FIXED_TIME)
            info.create_system = 3
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_STORED if name.endswith(stored) or name.endswith("/") else zipfile.ZIP_DEFLATED
            archive.writestr(info, data, compresslevel=9)
    result = buffer.getvalue()
    with zipfile.ZipFile(io.BytesIO(result)) as archive:
        if archive.testzip() is not None or sorted(archive.namelist()) != sorted(entries):
            raise ValueError("ZIP inventory or CRC differs")
        for name, (data, _) in entries.items():
            if not name.endswith("/") and archive.read(name) != data:
                raise ValueError("ZIP changed payload bytes: " + name)
    return result


def app_entries(app: Path, prefix: str, version: str, pins: dict) -> dict[str, tuple[bytes, int]]:
    """Every file of the app bundle with its mode; the bundle must carry the pinned engine and this version."""
    app = checks.bounded_path(app)
    info = plistlib.loads(checks.read(app / "Contents/Info.plist", app))
    if info.get("CFBundleIdentifier") != "io.github.alpertknn.DiscordAccess" or info.get("CFBundleShortVersionString") != version:
        raise ValueError("App bundle identifier or version differs from the release")
    checks.read(app / "Contents/Helpers/sing-box", app, pins["ENGINE_SHA256"], pins["ENGINE_BYTES"])
    if subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)], capture_output=True).returncode != 0:
        raise ValueError("App bundle signature does not verify")
    entries = {}
    for path in sorted(app.rglob("*")):
        status = path.lstat()
        name = prefix + "DiscordAccess.app/" + path.relative_to(app).as_posix()
        if stat.S_ISDIR(status.st_mode):
            entries[name + "/"] = (b"", stat.S_IFDIR | 0o755)
        elif stat.S_ISREG(status.st_mode):
            entries[name] = (checks.read(path, app), stat.S_IFREG | (0o755 if status.st_mode & 0o111 else 0o644))
        else:
            raise ValueError("App bundle holds a link or special file: " + name)
    entries[prefix + "DiscordAccess.app/"] = (b"", stat.S_IFDIR | 0o755)
    return entries


def package(version: str, commit: str, app: Path, evidence: Path, cache: Path, output: Path) -> dict:
    checks.release_version(version)
    tag = "macos-v" + version
    prefix = "DiscordAccess-" + tag
    output = checks.bounded_path(output)
    if output.exists():
        raise ValueError("Release output already exists; nothing was replaced")
    repository = checks.exact_head(REPO, commit)
    pins = recipe_pins()
    evidence_files, checksum_bytes = verify_evidence(evidence, pins)
    manifest_bytes, aggregate_bytes = derive(evidence_files, pins)
    if checks.read(REPO / MANIFEST, REPO) != manifest_bytes or checks.read(REPO / AGGREGATE, REPO) != aggregate_bytes:
        raise ValueError("Committed macOS notices are not current; run `release.py notices` and commit")
    manifest = checks.parse_json(manifest_bytes)
    notices = checks.read(REPO / NOTICES, REPO)
    checks.validate_full_gpl(notices)
    if pins["ENGINE_SHA256"].encode() not in notices or pins["ENGINE_CDHASH"].encode() not in notices:
        raise ValueError("Third-party notices do not identify the pinned engine")

    # The corresponding engine source.
    source = {}
    upstream = None
    for component in manifest["components"]:
        filename, name = archive_name(component)
        data = checks.read(cache / filename, cache)
        files = verify_archive(data, component)
        upstream = files if files is not None else upstream
        source[name] = data
    if upstream is None:
        raise ValueError("Main source archive is missing")
    recipe = manifest["build_recipe"]
    for path_key, hash_key in (("script", "script_sha256"), ("go_mod", "go_mod_sha256"), ("go_sum", "go_sum_sha256")):
        source[recipe[path_key]] = checks.read(REPO / recipe[path_key], REPO, recipe[hash_key])
    patch, patch_bytes, overlay = checks.validate_overlay(REPO, recipe, manifest, upstream, source)
    modified = dict(upstream)
    modified["go.mod"], modified["go.sum"] = source[recipe["go_mod"]], source[recipe["go_sum"]]
    for item in overlay:
        modified[item["source_relative"]] = source[item["payload_relative"]]
    changed = sorted(name for name in modified if upstream.get(name) != modified[name])
    modified_zip = deterministic_zip({"source/" + name: (data, stat.S_IFREG | 0o644) for name, data in modified.items()})
    source["sources/main/sing-box-modified-source.zip"] = modified_zip
    for name, data in evidence_files.items():
        source["evidence/current-build/" + name] = data
    source["evidence/current-build/SHA256SUMS.txt"] = checksum_bytes
    for name in ("LICENSE", NOTICES, AGGREGATE, MANIFEST):
        source[name] = checks.read(REPO / name, REPO)
    overlay_notice = next(source[item["payload_relative"]] for item in overlay if item["source_relative"].endswith("DISCORDACCESS-NOTICE"))
    modification_date = checks.git_text(REPO, "log", "-1", "--format=%cs", "--", recipe["patch_manifest"]["path"])
    source["README-SOURCE.md"] = (
        f"# DiscordAccess {tag} corresponding engine source\n\n"
        f"Source commit: {commit}.\nEngine: {manifest['engine_version']} for macOS arm64 (darwin/arm64).\n"
        f"Engine SHA-256: {manifest['engine_sha256']}; cdhash: {manifest['engine_cdhash']}.\n\n"
        f"This package preserves complete source archives for all {manifest['module_count']} linked Go modules, "
        f"{manifest['go_version']}, the upstream main source and the exact modified main source the recipe builds. "
        "Module archives match the engine's recorded Go h1 values; notices are verified against each archive.\n\n"
        f"The main source is modified for DiscordAccess (reviewed overlay modification date: {modification_date}). Changed files:\n\n" +
        "".join("- `" + name + "`\n" for name in changed) +
        "\n`sources/main/sing-box-modified-source.zip` is the upstream archive with the pinned dependency locks and the exact "
        "overlay files of `engine-patches/http-limits/` applied, as `macos/scripts/build-engine.py` applies them; every input is "
        "hash checked. Source notices remain under their original licenses; sing-box stays GPL-3.0-or-later.\n\n"
        "`evidence/current-build/` is the checksum-bound report of a successful build with the exact current recipe, the "
        "engine pin enforced and the overlay's source tests passing. The engine binary itself is not included.\n\n"
        "To rebuild, extract this package into a writable folder and run on an Apple Silicon Mac with Python 3:\n\n"
        "```bash\npython3 macos/scripts/build-engine.py --run-source-tests\n```\n\n"
        "The recipe downloads the hash-pinned upstream source and Go archives and the pinned public modules; it is not an "
        "offline module cache. The result is hash and cdhash verified and is never executed.\n\n"
        "SOURCE_PACKAGE_MANIFEST.json lists every payload's SHA-256 and size, excluding itself and SHA256SUMS.txt; "
        "SHA256SUMS.txt also hashes that manifest. Distribute this package together with the engine it identifies.\n").encode("utf-8")
    forbidden = (".exe", ".dll", ".sys", ".log", ".dmp", ".prof", ".pprof", ".test", ".app")
    if any(name.lower().endswith(forbidden) for name in source) or len({name.casefold() for name in source}) != len(source):
        raise ValueError("Source payload holds a program, log or colliding path")
    package_manifest = {"schema": 3, "distribution_status": "release", "platform": "darwin/arm64", "release_tag": tag,
                        "release_version": version, "source_commit": commit, "engine_version": manifest["engine_version"],
                        "engine_sha256": manifest["engine_sha256"], "engine_bytes": manifest["engine_bytes"],
                        "engine_cdhash": manifest["engine_cdhash"], "module_count": manifest["module_count"],
                        "notice_count": manifest["notice_count"], "changed_files": changed,
                        "main_source_overlay": {"manifest_path": recipe["patch_manifest"]["path"], "manifest_sha256": checks.sha(patch_bytes),
                                                "modification_date": modification_date},
                        "file_hash_scope": "All payloads except this manifest/SHA256SUMS; SHA256SUMS also hashes the manifest",
                        "files": [{"path": name, "bytes": len(data), "sha256": checks.sha(data)} for name, data in sorted(source.items())]}
    source["SOURCE_PACKAGE_MANIFEST.json"] = checks.json_bytes(package_manifest)
    source["SHA256SUMS.txt"] = "".join(checks.sha(data) + "  " + name + "\n" for name, data in sorted(source.items())).encode("ascii")
    source_zip = deterministic_zip({name: (data, stat.S_IFREG | 0o644) for name, data in source.items()}, stored=(".zip", ".tar.gz"))
    source_name = prefix + "-engine-source.zip"

    # The runtime package.
    usage = checks.read(REPO / USAGE, REPO)
    if tag.encode() not in usage:
        raise ValueError("Usage notes do not name the release")
    heading = (f"DiscordAccess {tag} (macOS).\nEngine source modified by DiscordAccess; reviewed overlay modification date: "
               f"{modification_date}.\n").encode("utf-8")
    licenses = b"\n\n".join((heading, source["LICENSE"], notices, aggregate_bytes, overlay_notice))
    note = (f"DiscordAccess {tag} (macOS, Apple Silicon)\nRelease/tag: {repository}/releases/tag/{tag}\n"
            f"Source commit: {commit}\nExact source: {repository}/tree/{commit}\n"
            f"Engine: {manifest['engine_version']} (macOS arm64)\nEngine SHA256: {manifest['engine_sha256']}\n"
            f"Engine cdhash: {manifest['engine_cdhash']}\nCorresponding engine source: {source_name}\n"
            f"Source package SHA256: {checks.sha(source_zip)}\nSource package bytes: {len(source_zip)}\n"
            f"Recipe SHA256: {recipe['script_sha256']}\n"
            "Distribute this exact source package together with the runtime package. It is not needed to run DiscordAccess.\n").encode("utf-8")
    runtime = app_entries(app, prefix + "/", version, pins)
    runtime[prefix + "/"] = (b"", stat.S_IFDIR | 0o755)
    for name, data in (("OKU-BENI.md", usage), ("LISANSLAR.txt", licenses), ("KAYNAK.txt", note)):
        runtime[prefix + "/" + name] = (data, stat.S_IFREG | 0o644)
    assets = {prefix + ".zip": deterministic_zip(runtime), source_name: source_zip, "engine-source-manifest.json": manifest_bytes}
    assets["SHA256SUMS.txt"] = "".join(checks.sha(data) + "  " + name + "\n" for name, data in sorted(assets.items())).encode("ascii")
    checks.exact_head(REPO, commit)

    output.mkdir(parents=True)
    for name, data in sorted(assets.items()):
        with (output / name).open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if checks.read(output / name, output) != data:
            raise ValueError("Written release asset differs: " + name)
    return {"release_tag": tag, "source_commit": commit, "output": str(output), "published": False,
            "assets": [{"name": name, "bytes": len(data), "sha256": checks.sha(data)} for name, data in sorted(assets.items())],
            "engine_sha256": manifest["engine_sha256"], "modules": manifest["module_count"], "notices": manifest["notice_count"],
            "source_payloads": len(source), "changed_main_source_files": changed}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    notices = commands.add_parser("notices", help="Write the macOS source manifest and aggregate notices")
    notices.add_argument("--evidence", type=Path, required=True, help="Current engine build artifacts (macos/work/engine-build-*/artifacts)")
    notices.add_argument("--check", action="store_true", help="Only check that the committed files are current")
    fetching = commands.add_parser("fetch", help="Download and verify the source archives")
    fetching.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    packaging = commands.add_parser("package", help="Build the release assets into a new folder")
    packaging.add_argument("--version", required=True, help="Release version, such as 0.1 (tag macos-v0.1)")
    packaging.add_argument("--commit", required=True, help="Exact clean HEAD the app was built from")
    packaging.add_argument("--app", type=Path, required=True, help="DiscordAccess.app built by build-app.sh from that commit")
    packaging.add_argument("--evidence", type=Path, required=True, help="Current engine build artifacts")
    packaging.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    packaging.add_argument("--output", type=Path, required=True, help="New folder for the release assets")
    args = parser.parse_args()
    try:
        if args.command == "notices":
            pins = recipe_pins()
            evidence_files, _ = verify_evidence(args.evidence, pins)
            manifest_bytes, aggregate_bytes = derive(evidence_files, pins)
            current = all((REPO / name).exists() and checks.read(REPO / name, REPO) == data
                          for name, data in ((MANIFEST, manifest_bytes), (AGGREGATE, aggregate_bytes)))
            if not args.check and not current:
                (REPO / MANIFEST).parent.mkdir(parents=True, exist_ok=True)
                (REPO / MANIFEST).write_bytes(manifest_bytes)
                (REPO / AGGREGATE).write_bytes(aggregate_bytes)
            result = {"current": current, "written": not args.check and not current, "manifest_sha256": checks.sha(manifest_bytes),
                      "aggregate_sha256": checks.sha(aggregate_bytes)}
            if args.check and not current:
                print(json.dumps(result, indent=2))
                return 1
        elif args.command == "fetch":
            result = fetch(args.cache)
        else:
            result = package(args.version, args.commit, args.app, args.evidence, args.cache, args.output)
    except (ValueError, OSError, KeyError) as error:
        print("release: " + type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
