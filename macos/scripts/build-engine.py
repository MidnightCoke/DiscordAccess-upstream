#!/usr/bin/env python3
"""Build the pinned DiscordAccess sing-box engine for macOS arm64.

This mirrors scripts/Build-SecurityEngine.ps1 without changing it: the same
upstream commit, Go release, byte-pinned dependency locks, reviewed source
overlay, build tags and linker flags. Only GOOS/GOARCH and the Go archive for
this host differ. The script never runs sing-box and never edits system
settings. Downloads, caches, Go work files, Go's home/telemetry files and
outputs stay under macos/work and macos/build; only the patch tests themselves
may create short-lived files in the system temporary directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import urllib.request
import uuid
import zipfile
from pathlib import Path

MACOS_ROOT = Path(os.path.realpath(__file__)).parent.parent
REPO_ROOT = MACOS_ROOT.parent
WORK_ROOT = MACOS_ROOT / "work"
CACHE_ROOT = WORK_ROOT / "cache"
OUTPUT_ROOT = MACOS_ROOT / "build" / "engine"

SOURCE_COMMIT = "7054cac5124465ffdb145870d7c01885566711b1"
SOURCE_URL = "https://github.com/SagerNet/sing-box/archive/" + SOURCE_COMMIT + ".zip"
SOURCE_SHA256 = "cd8a3508f36d74ef7c9c515bdc8586f048fd06c22499d38ee3787faa7d220f74"
GO_VERSION = "go1.26.9"
GO_URL = "https://go.dev/dl/go1.26.9.darwin-arm64.tar.gz"
GO_SHA256 = "f9bb7c0a02506c5d9bf0d1eb1f7ee6c7684f844ae49558308a0427b830e022cc"
ENGINE_VERSION = "1.14.3-discordaccess.2"
PATCH_MANIFEST = REPO_ROOT / "engine-patches" / "http-limits" / "manifest.json"
PATCH_MANIFEST_SHA256 = "14f99d93af5f910bd5c00f0f536b8ae2e018dea910400043c821493c0569e367"
LOCK_MOD = REPO_ROOT / "engine-build" / "go.mod"
LOCK_SUM = REPO_ROOT / "engine-build" / "go.sum"
LOCK_MOD_SHA256 = "2c335df61e036819c4a0694e32748b4a3998c0faf898fc05bcc7c0213c27baf5"
LOCK_SUM_SHA256 = "c391d32564c5c66c7eb76fae8595129e234784b03a0e4100ecb762beec9a103e"
BUILD_TAGS = "with_purego,badlinkname,tfogo_checklinkname0"
LINKER_FLAGS = "-X github.com/sagernet/sing-box/constant.Version=" + ENGINE_VERSION + " -checklinkname=0 -s -w -buildid="
SOURCE_TEST_PACKAGES = ("./internal/discordaccess/httpguard", "./protocol/http", "./common/listener")
# Pinned after stage 0 reproduced two identical builds; must equal EngineIdentity.pinned in
# macos/Sources/DiscordAccessKit/Engine/EngineImage.swift (checked by the tests).
ENGINE_SHA256 = "013ba5d5055988953ebec1a1ac0eceb8aead52415e3ef186a5c7481083472cb0"
ENGINE_BYTES = 33315362
ENGINE_CDHASH = "344f8bd088ce068a1745cf16e7bb0c9a4bbbe99e"
SOURCE_MAX_BYTES = 64 * 1024 * 1024
GO_MAX_BYTES = 128 * 1024 * 1024
# `go version -m` omits -ldflags under -trimpath; everything else that shapes the target is recorded.
EXPECTED_BUILD_SETTINGS = {"-buildmode": "exe", "-compiler": "gc", "-tags": BUILD_TAGS, "-trimpath": "true",
                           "CGO_ENABLED": "0", "GOARCH": "arm64", "GOOS": "darwin", "GOARM64": "v8.0"}
CA_FILE = "/etc/ssl/cert.pem"
NAME_PATTERN = re.compile(r"\A[A-Za-z0-9_./-]+\Z")
DIGEST_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")


class BuildError(Exception):
    """A pinned input, archive, overlay or toolchain check failed."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_digest(path: Path, expected: str, label: str) -> None:
    if not path.is_file() or sha256_file(path) != expected:
        raise BuildError(label + " does not match its pinned SHA-256: " + str(path))


def require_locks(go_mod: Path, go_sum: Path) -> None:
    require_digest(go_mod, LOCK_MOD_SHA256, "go.mod lock")
    require_digest(go_sum, LOCK_SUM_SHA256, "go.sum lock")


def require_inside(path: Path, root: Path) -> Path:
    """Return path when it stays under root and no component below root is a symlink."""
    root = Path(os.path.realpath(root))
    full = Path(os.path.normpath(path if Path(path).is_absolute() else root / path))
    try:
        relative = full.relative_to(root)
    except ValueError:
        raise BuildError("Path leaves the allowed folder: " + str(full)) from None
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError("Path contains a symbolic link: " + str(current))
    return full


def _relative_member(name: str, prefix: str) -> str:
    if not name.startswith(prefix) or "\\" in name or ":" in name or "\x00" in name or name.startswith("/"):
        raise BuildError("Unexpected archive path: " + name)
    relative = name[len(prefix):]
    if relative and any(part in ("", ".", "..") for part in relative.rstrip("/").split("/")):
        raise BuildError("Path traversal in archive: " + name)
    return relative


def extract_zip(archive: Path, destination: Path, prefix: str, max_bytes: int, max_entries: int = 40000) -> int:
    """Extract a verified source zip like the Windows recipe: links are written as plain files."""
    destination.mkdir(parents=True, exist_ok=True)
    destination = Path(os.path.realpath(destination))
    written = total = 0
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > max_entries:
            raise BuildError("Source archive exceeds its entry limit.")
        for entry in entries:
            relative = _relative_member(entry.filename, prefix)
            if not relative:
                continue
            total += entry.file_size
            if entry.file_size > 268435456 or total > max_bytes:
                raise BuildError("Source archive exceeds its size limit.")
            target = require_inside(destination / relative.rstrip("/"), destination)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as data, open(target, "xb") as output:
                shutil.copyfileobj(data, output)
            written += 1
    return written


def extract_go_toolchain(archive: Path, destination: Path, max_bytes: int = 1073741824, max_entries: int = 40000) -> int:
    """Extract the pinned Go archive; only regular files and directories are accepted."""
    destination.mkdir(parents=True, exist_ok=True)
    destination = Path(os.path.realpath(destination))
    written = total = count = 0
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            count += 1
            if count > max_entries:
                raise BuildError("Toolchain archive exceeds its entry limit.")
            if member.name == "go" and member.isdir():
                continue
            relative = _relative_member(member.name, "go/")
            if not relative:
                continue
            target = require_inside(destination / relative.rstrip("/"), destination)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise BuildError("Toolchain archive entry is not a regular file: " + member.name)
            total += member.size
            if member.size > 268435456 or total > max_bytes:
                raise BuildError("Toolchain archive exceeds its size limit.")
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.extractfile(member)
            if data is None:
                raise BuildError("Cannot read toolchain file: " + member.name)
            with data, open(target, "xb") as output:
                shutil.copyfileobj(data, output)
            os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)
            written += 1
    return written


def load_overlay_manifest(path: Path = PATCH_MANIFEST) -> dict:
    require_digest(path, PATCH_MANIFEST_SHA256, "Patch manifest")
    manifest = json.loads(path.read_bytes())
    files = manifest.get("files")
    if (manifest.get("schema") != 1 or manifest.get("main_source_commit") != SOURCE_COMMIT or
            manifest.get("source_archive_sha256") != SOURCE_SHA256 or manifest.get("engine_version") != ENGINE_VERSION or
            not isinstance(files, list) or not 1 <= len(files) <= 16):
        raise BuildError("Invalid patch manifest identity.")
    return manifest


def apply_overlay(manifest: dict, repo_root: Path, source_root: Path) -> list:
    """Apply the reviewed exact-file overlay; every base and payload byte is hash checked first."""
    repo_root = Path(os.path.realpath(repo_root))
    source_root = Path(os.path.realpath(source_root))
    applied, seen = [], set()
    for record in manifest["files"]:
        name, after, size = record.get("source_relative"), record.get("after_sha256"), record.get("bytes")
        if (not isinstance(name, str) or not NAME_PATTERN.match(name) or name.startswith("/") or
                any(part in ("", ".", "..") for part in name.split("/")) or name in seen or
                record.get("payload_relative") != "engine-patches/http-limits/source/" + name or
                not isinstance(after, str) or not DIGEST_PATTERN.match(after) or
                type(size) is not int or not 1 <= size <= 1048576):
            raise BuildError("Invalid patch path or identity: " + str(name))
        seen.add(name)
        target = require_inside(source_root / name, source_root)
        payload = require_inside(repo_root / record["payload_relative"], repo_root)
        before = record.get("before_sha256")
        if before is None:
            if os.path.lexists(target):
                raise BuildError("Added patch file already exists in the upstream source: " + name)
        elif (not isinstance(before, str) or not DIGEST_PATTERN.match(before) or
              not target.is_file() or sha256_file(target) != before):
            raise BuildError("Patch base source bytes do not match: " + name)
        data = payload.read_bytes() if payload.is_file() else b""
        if len(data) != size or hashlib.sha256(data).hexdigest() != after:
            raise BuildError("Patch payload bytes do not match: " + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "wb") as output:
            output.write(data)
        if sha256_file(target) != after:
            raise BuildError("Applied patch bytes do not match: " + name)
        applied.append(name)
    return applied


def go_environment(build_root: Path, go_root: Path, base: dict | None = None) -> dict:
    """Isolated, reproducible Go settings; ambient GO* variables never leak into the build."""
    inherited = dict(os.environ if base is None else base)
    environment = {key: value for key, value in inherited.items() if not key.startswith("GO") and key != "CGO_ENABLED"}
    environment.update({
        "GOENV": "off", "GOAUTH": "off", "GOROOT": str(go_root), "GOPATH": str(build_root / "gopath"),
        "GOCACHE": str(build_root / "gocache"), "GOMODCACHE": str(build_root / "modules"), "GOTOOLCHAIN": "local",
        "GOOS": "darwin", "GOARCH": "arm64", "GOARM64": "v8.0", "CGO_ENABLED": "0", "GOFLAGS": "", "GOEXPERIMENT": "",
        "GOWORK": "off", "GOPROXY": "https://proxy.golang.org", "GOSUMDB": "sum.golang.org", "GONOSUMDB": "",
        "GONOPROXY": "", "GOPRIVATE": "", "GOINSECURE": "", "GOVCS": "*:off", "GODEBUG": "",
        # Go keeps its config/telemetry under HOME and its work files under GOTMPDIR; both stay in the build root.
        "HOME": str(build_root / "home"), "GOTMPDIR": str(build_root / "tmp"),
    })
    environment["PATH"] = str(go_root / "bin") + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
    return environment


def parse_cdhash(output: str) -> str:
    match = re.search(r"^CDHash=([0-9a-f]{40}|[0-9a-f]{64})$", output, re.MULTILINE)
    if match is None:
        raise BuildError("No CDHash in the codesign output.")
    return match.group(1)


def require_build_record(lines: list) -> None:
    """The binary's own Go build record must show exactly the pinned toolchain, target and tags."""
    settings, repeated = {}, False
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) == 3 and fields[0] == "" and fields[1] == "build" and "=" in fields[2]:
            key, value = fields[2].split("=", 1)
            repeated = repeated or key in settings
            settings[key] = value
    if (repeated or not lines or not lines[0].endswith(": " + GO_VERSION) or
            "\tpath\tgithub.com/sagernet/sing-box/cmd/sing-box" not in lines or settings != EXPECTED_BUILD_SETTINGS):
        raise BuildError("The engine's Go build info does not match the pinned toolchain, target or tags.")


def require_engine_identity(digest: str, size: int, cdhash: str, evidence: str = "") -> None:
    """Only the pinned engine is ever published: its SHA-256, size and cdhash must all match."""
    if (digest, size, cdhash) != (ENGINE_SHA256, ENGINE_BYTES, ENGINE_CDHASH):
        raise BuildError("The built engine does not match the pinned SHA-256, size and cdhash; it was not copied. Measured: SHA-256 " + digest +
                         ", " + str(size) + " bytes, cdhash " + cdhash + "." + (" Evidence: " + evidence if evidence else ""))


def read_cdhash(binary: Path) -> str:
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(binary)], capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError("codesign could not read the engine signature: " + result.stderr.strip())
    return parse_cdhash(result.stderr + result.stdout)


def fetch_verified(url: str, destination: Path, expected: str, max_bytes: int) -> Path:
    destination = require_inside(destination, WORK_ROOT)
    if destination.is_file() and sha256_file(destination) == expected:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    for stale in (destination, partial):
        if os.path.lexists(stale):
            stale.unlink()
    context = ssl.create_default_context(cafile=CA_FILE)
    try:
        with urllib.request.urlopen(url, timeout=300, context=context) as response, open(partial, "xb") as output:
            received = 0
            for chunk in iter(lambda: response.read(1 << 20), b""):
                received += len(chunk)
                if received > max_bytes:
                    raise BuildError("Downloaded archive exceeds its size limit: " + url)
                output.write(chunk)
    except BaseException:
        if os.path.lexists(partial):
            partial.unlink()
        raise
    if sha256_file(partial) != expected:
        partial.unlink()
        raise BuildError("Downloaded archive does not match its pinned SHA-256: " + url)
    os.replace(partial, destination)
    return destination


def run_go(go: Path, arguments: list, environment: dict, cwd: Path) -> str:
    result = subprocess.run([str(go), *arguments], cwd=cwd, env=environment, capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError("Pinned Go command failed (exit " + str(result.returncode) + "): go " + " ".join(arguments) +
                         "\n" + result.stdout[-4000:] + result.stderr[-4000:])
    return result.stdout


def publish(engine: Path, output: Path, digest: str, root: Path = MACOS_ROOT) -> None:
    """Publish a verified engine: never overwrite a different file, follow a link or leave a partial file."""
    output = require_inside(output, root)
    if os.path.lexists(output):
        if output.is_symlink() or not output.is_file() or sha256_file(output) != digest:
            raise BuildError("The existing output engine differs; it was not overwritten. New build: " + str(engine))
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output = require_inside(output, root)
    partial = output.with_name(".sing-box.partial-" + uuid.uuid4().hex)
    descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755)
    try:
        with os.fdopen(descriptor, "wb") as target, open(engine, "rb") as source:
            shutil.copyfileobj(source, target)
        if sha256_file(partial) != digest:
            raise BuildError("The copied engine could not be verified; it was not published.")
        try:
            os.link(partial, output)
        except FileExistsError:
            raise BuildError("An output engine appeared during the build; it was not overwritten.") from None
    finally:
        partial.unlink()


def build(run_source_tests: bool, output: Path | None) -> dict:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise BuildError("This target requires macOS arm64.")
    require_locks(LOCK_MOD, LOCK_SUM)
    manifest = load_overlay_manifest()
    if output is not None:
        output = require_inside(output, MACOS_ROOT)
        if output.name != "sing-box" or not (output.parent == OUTPUT_ROOT or WORK_ROOT in output.parents):
            raise BuildError("--out must be macos/build/engine/sing-box or a sing-box path under macos/work.")
        if output.is_dir():
            raise BuildError("The output path is a folder; it was not changed.")
    build_root = require_inside(WORK_ROOT / ("engine-build-" + uuid.uuid4().hex), WORK_ROOT)
    build_root.mkdir(parents=True)
    for folder in ("home", "tmp"):
        (build_root / folder).mkdir()
    source_root, go_root, artifacts = build_root / "source", build_root / "go", build_root / "artifacts"
    artifacts.mkdir()
    source_zip = fetch_verified(SOURCE_URL, CACHE_ROOT / ("sing-box-" + SOURCE_COMMIT + ".zip"), SOURCE_SHA256, SOURCE_MAX_BYTES)
    go_archive = fetch_verified(GO_URL, CACHE_ROOT / "go1.26.9.darwin-arm64.tar.gz", GO_SHA256, GO_MAX_BYTES)
    extract_zip(source_zip, source_root, "sing-box-" + SOURCE_COMMIT + "/", 268435456)
    applied = apply_overlay(manifest, REPO_ROOT, source_root)
    extract_go_toolchain(go_archive, go_root)
    go = go_root / "bin" / "go"
    if not go.is_file():
        raise BuildError("The pinned Go executable is missing from the verified archive.")
    shutil.copyfile(source_root / "go.mod", artifacts / "upstream-go.mod")
    shutil.copyfile(source_root / "go.sum", artifacts / "upstream-go.sum")
    shutil.copyfile(LOCK_MOD, source_root / "go.mod")
    shutil.copyfile(LOCK_SUM, source_root / "go.sum")
    require_locks(source_root / "go.mod", source_root / "go.sum")
    environment = go_environment(build_root, go_root)
    toolchain = run_go(go, ["version"], environment, source_root).strip()
    if toolchain != "go version " + GO_VERSION + " darwin/arm64":
        raise BuildError("Pinned toolchain identity does not match: " + toolchain)
    run_go(go, ["mod", "download"], environment, source_root)
    run_go(go, ["mod", "verify"], environment, source_root)
    require_locks(source_root / "go.mod", source_root / "go.sum")
    if run_source_tests:
        report = run_go(go, ["test", "-mod=readonly", "-count=1", "-tags=" + BUILD_TAGS, "-ldflags=-checklinkname=0",
                             "-timeout=60s", *SOURCE_TEST_PACKAGES], environment, source_root)
        (artifacts / "source-unit-tests.txt").write_text(report, encoding="utf-8")
    modules = run_go(go, ["list", "-mod=readonly", "-m", "all"], environment, source_root)
    (artifacts / "selected-modules.txt").write_text(modules, encoding="utf-8")
    packages = run_go(go, ["list", "-mod=readonly", "-tags=" + BUILD_TAGS, "-deps", "./cmd/sing-box"], environment, source_root)
    (artifacts / "compiled-packages.txt").write_text(packages, encoding="utf-8")
    if any(line == "golang.org/x/crypto/openpgp" or line.startswith("golang.org/x/crypto/openpgp/") for line in packages.splitlines()):
        raise BuildError("The unmaintained OpenPGP package must not be compiled into this target.")
    engine = artifacts / "sing-box"
    run_go(go, ["build", "-trimpath", "-buildvcs=false", "-mod=readonly", "-tags=" + BUILD_TAGS, "-ldflags=" + LINKER_FLAGS,
                "-o", str(engine), "./cmd/sing-box"], environment, source_root)
    require_locks(source_root / "go.mod", source_root / "go.sum")
    digest, size, cdhash = sha256_file(engine), engine.stat().st_size, read_cdhash(engine)
    build_info = run_go(go, ["version", "-m", str(engine)], environment, source_root).splitlines()
    # Written before the checks as evidence; the first line names the output path, so only the file name is kept.
    record = ["sing-box:" + line.rsplit(":", 1)[-1] if index == 0 else line for index, line in enumerate(build_info)]
    (artifacts / "go-version-m.txt").write_text("\n".join(record) + "\n", encoding="utf-8")
    require_build_record(build_info)
    require_engine_identity(digest, size, cdhash, str(artifacts))
    metadata = {
        "schema": 1, "target": "darwin/arm64", "engine_version": ENGINE_VERSION, "engine_sha256": digest,
        "engine_bytes": size, "engine_cdhash": cdhash, "engine_pin_enforced": True,
        "go_version": GO_VERSION, "go_archive_url": GO_URL, "go_archive_sha256": GO_SHA256,
        "main_source_commit": SOURCE_COMMIT, "source_archive_url": SOURCE_URL, "source_archive_sha256": SOURCE_SHA256,
        "main_source_patch_sha256": PATCH_MANIFEST_SHA256, "patched_files": applied,
        "lock_go_mod_sha256": LOCK_MOD_SHA256, "lock_go_sum_sha256": LOCK_SUM_SHA256,
        "build_tags": BUILD_TAGS, "linker_flags": LINKER_FLAGS, "source_unit_tests_ran": run_source_tests,
        "build_script_sha256": sha256_file(Path(os.path.realpath(__file__))), "engine_executed": False,
    }
    (artifacts / "build-metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    sums = "".join(sha256_file(path) + "  " + path.name + "\n"
                   for path in sorted(artifacts.iterdir()) if path.is_file() and path.name != "SHA256SUMS.txt")
    (artifacts / "SHA256SUMS.txt").write_text(sums, encoding="ascii")
    if output is not None:
        publish(engine, output, digest)
    metadata["artifacts"] = str(artifacts)
    return metadata


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description="Builds the DiscordAccess engine for macOS arm64 from pinned inputs; never runs the engine.")
    parser.add_argument("--run-source-tests", action="store_true", help="Also run the patches' Go tests")
    parser.add_argument("--out", type=Path, help="macos/build/engine/sing-box (without it, the engine is built only into the evidence folder)")
    args = parser.parse_args(argv)
    try:
        result = build(args.run_source_tests, Path(os.path.abspath(args.out)) if args.out else None)
    except BuildError as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    except OSError as error:
        print("ERROR: A file or network operation failed (" + type(error).__name__ + "): " + str(error)[:300], file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
