"""Offline checks for macos/scripts/build-engine.py: synthetic fixtures only; no network, Go or engine run."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import inspect
import io
import os
from pathlib import Path
import stat
import sys
import re
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
MACOS = Path(os.path.realpath(__file__)).parent.parent
REPO = MACOS.parent
_spec = importlib.util.spec_from_file_location("build_engine_under_test", MACOS / "scripts" / "build-engine.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class TemporaryRoot(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.temporary.name))

    def tearDown(self):
        self.temporary.cleanup()


class PathTests(TemporaryRoot):
    def test_paths_must_stay_inside_without_symlinks(self):
        (self.root / "real").mkdir()
        (self.root / "link").symlink_to(self.root / "real")
        self.assertEqual(build.require_inside(self.root / "real" / "x", self.root), self.root / "real" / "x")
        for path in (self.root / ".." / "x", self.root / "link" / "x", Path("/etc/hosts")):
            with self.subTest(path=str(path)), self.assertRaises(build.BuildError):
                build.require_inside(path, self.root)


class OverlayTests(TemporaryRoot):
    def setUp(self):
        super().setUp()
        self.repo, self.source = self.root / "repo", self.root / "source"
        self.payloads = self.repo / "engine-patches" / "http-limits" / "source"
        (self.payloads / "pkg").mkdir(parents=True)
        (self.source / "pkg").mkdir(parents=True)
        self.original, self.patched = b"package pkg\n", b"package pkg\n// reviewed change\n"
        (self.source / "pkg" / "a.go").write_bytes(self.original)
        (self.payloads / "pkg" / "a.go").write_bytes(self.patched)

    def manifest(self, **changes):
        record = {"source_relative": "pkg/a.go", "payload_relative": "engine-patches/http-limits/source/pkg/a.go",
                  "before_sha256": digest(self.original), "after_sha256": digest(self.patched), "bytes": len(self.patched)}
        record.update(changes)
        return {"files": [record]}

    def test_modified_file_is_replaced_when_both_hashes_match(self):
        self.assertEqual(build.apply_overlay(self.manifest(), self.repo, self.source), ["pkg/a.go"])
        self.assertEqual((self.source / "pkg" / "a.go").read_bytes(), self.patched)

    def test_changed_upstream_base_is_rejected(self):
        (self.source / "pkg" / "a.go").write_bytes(b"package pkg\n// drift\n")
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(), self.repo, self.source)

    def test_added_file_must_not_already_exist(self):
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(before_sha256=None), self.repo, self.source)

    def test_added_file_is_created(self):
        (self.payloads / "pkg" / "new.go").write_bytes(self.patched)
        manifest = self.manifest(source_relative="pkg/new.go", before_sha256=None,
                                 payload_relative="engine-patches/http-limits/source/pkg/new.go")
        build.apply_overlay(manifest, self.repo, self.source)
        self.assertEqual((self.source / "pkg" / "new.go").read_bytes(), self.patched)

    def test_payload_bytes_must_match_before_anything_is_written(self):
        (self.payloads / "pkg" / "a.go").write_bytes(b"package pkg\n// tampered\n")
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(), self.repo, self.source)
        self.assertEqual((self.source / "pkg" / "a.go").read_bytes(), self.original)

    def test_traversal_names_are_rejected(self):
        for name in ("../escape.go", "pkg/../../escape.go", "/abs.go", "pkg//a.go"):
            with self.subTest(name=name), self.assertRaises(build.BuildError):
                build.apply_overlay(self.manifest(source_relative=name, payload_relative="engine-patches/http-limits/source/" + name),
                                    self.repo, self.source)

    def test_symlinked_target_is_rejected(self):
        outside = self.root / "outside.go"
        outside.write_bytes(self.original)
        (self.source / "pkg" / "a.go").unlink()
        (self.source / "pkg" / "a.go").symlink_to(outside)
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(), self.repo, self.source)
        self.assertEqual(outside.read_bytes(), self.original)


class ArchiveTests(TemporaryRoot):
    def zip_file(self, entries):
        path = self.root / "source.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data, mode in entries:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                archive.writestr(info, data)
        return path

    def tar_file(self, members):
        path = self.root / "go.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, kind, data, mode in members:
                info = tarfile.TarInfo(name)
                info.type, info.mode = kind, mode
                if kind == tarfile.SYMTYPE:
                    info.linkname = "/etc/hosts"
                    archive.addfile(info)
                elif kind == tarfile.DIRTYPE:
                    archive.addfile(info)
                else:
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
        return path

    def test_zip_extracts_files_under_prefix(self):
        path = self.zip_file([("top/", b"", stat.S_IFDIR | 0o755), ("top/a/b.go", b"package b\n", stat.S_IFREG | 0o644)])
        self.assertEqual(build.extract_zip(path, self.root / "out", "top/", 1 << 20), 1)
        self.assertEqual((self.root / "out" / "a" / "b.go").read_bytes(), b"package b\n")

    def test_zip_rejects_foreign_prefix_and_traversal(self):
        for index, name in enumerate(("other/a.go", "top/../a.go", "top/a/../../b.go", "top\\a.go")):
            with self.subTest(name=name):
                path = self.zip_file([(name, b"x", stat.S_IFREG | 0o644)])
                with self.assertRaises(build.BuildError):
                    build.extract_zip(path, self.root / ("out-" + str(index)), "top/", 1 << 20)

    def test_zip_link_entry_is_written_as_plain_file(self):
        path = self.zip_file([("top/link", b"target-text", stat.S_IFLNK | 0o777)])
        build.extract_zip(path, self.root / "out", "top/", 1 << 20)
        self.assertFalse((self.root / "out" / "link").is_symlink())
        self.assertEqual((self.root / "out" / "link").read_bytes(), b"target-text")

    def test_zip_size_limit(self):
        path = self.zip_file([("top/big", b"x" * 2048, stat.S_IFREG | 0o644)])
        with self.assertRaises(build.BuildError):
            build.extract_zip(path, self.root / "out", "top/", 1024)

    def test_go_archive_keeps_executable_bits(self):
        path = self.tar_file([("go", tarfile.DIRTYPE, b"", 0o755), ("go/bin/go", tarfile.REGTYPE, b"#!fixture", 0o755),
                              ("go/VERSION", tarfile.REGTYPE, b"go1.26.9", 0o644)])
        self.assertEqual(build.extract_go_toolchain(path, self.root / "go"), 2)
        self.assertTrue(os.access(self.root / "go" / "bin" / "go", os.X_OK))
        self.assertFalse(os.access(self.root / "go" / "VERSION", os.X_OK))

    def test_go_archive_rejects_links_and_foreign_paths(self):
        cases = ([("go/link", tarfile.SYMTYPE, b"", 0o777)], [("other/file", tarfile.REGTYPE, b"x", 0o644)],
                 [("go/../escape", tarfile.REGTYPE, b"x", 0o644)])
        for index, members in enumerate(cases):
            with self.subTest(name=members[0][0]):
                path = self.tar_file(members)
                with self.assertRaises(build.BuildError):
                    build.extract_go_toolchain(path, self.root / ("go-" + str(index)))


class EnvironmentTests(TemporaryRoot):
    def test_environment_pins_target_and_drops_ambient_go_settings(self):
        environment = build.go_environment(self.root / "b", self.root / "b" / "go", base={
            "HOME": "/Users/fixture", "LANG": "tr_TR.UTF-8", "GOFLAGS": "-mod=mod", "GOPROXY": "direct", "GOARCH": "amd64",
            "CGO_ENABLED": "1", "GOFIPS140": "latest", "GOAMD64": "v3", "GOROOT_FINAL": "/fixture", "PATH": "/opt/homebrew/bin"})
        expected = {"GOOS": "darwin", "GOARCH": "arm64", "GOARM64": "v8.0", "CGO_ENABLED": "0", "GOTOOLCHAIN": "local",
                    "GOFLAGS": "", "GOPROXY": "https://proxy.golang.org", "GOSUMDB": "sum.golang.org", "GOVCS": "*:off",
                    "GOENV": "off", "GOWORK": "off", "HOME": str(self.root / "b" / "home"),
                    "GOTMPDIR": str(self.root / "b" / "tmp"), "GOCACHE": str(self.root / "b" / "gocache"), "LANG": "tr_TR.UTF-8"}
        for key, value in expected.items():
            self.assertEqual(environment[key], value, key)
        for key in ("GOFIPS140", "GOAMD64", "GOROOT_FINAL"):
            self.assertNotIn(key, environment)
        self.assertTrue(environment["PATH"].startswith(str(self.root / "b" / "go" / "bin") + os.pathsep))
        self.assertNotIn("/opt/homebrew/bin", environment["PATH"])


class PublishTests(TemporaryRoot):
    def setUp(self):
        super().setUp()
        self.engine = self.root / "artifacts" / "sing-box"
        self.engine.parent.mkdir()
        self.engine.write_bytes(b"engine-bytes")
        self.digest = digest(b"engine-bytes")
        self.output = self.root / "build" / "engine" / "sing-box"

    def test_new_output_is_a_complete_executable_copy(self):
        build.publish(self.engine, self.output, self.digest, root=self.root)
        self.assertEqual(self.output.read_bytes(), b"engine-bytes")
        self.assertTrue(os.access(self.output, os.X_OK))
        self.assertEqual(sorted(path.name for path in self.output.parent.iterdir()), ["sing-box"])

    def test_identical_existing_output_is_accepted(self):
        build.publish(self.engine, self.output, self.digest, root=self.root)
        build.publish(self.engine, self.output, self.digest, root=self.root)
        self.assertEqual(self.output.read_bytes(), b"engine-bytes")

    def test_different_existing_output_is_never_replaced(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"other-engine")
        with self.assertRaises(build.BuildError):
            build.publish(self.engine, self.output, self.digest, root=self.root)
        self.assertEqual(self.output.read_bytes(), b"other-engine")

    def test_symlinked_output_is_rejected(self):
        self.output.parent.mkdir(parents=True)
        elsewhere = self.root / "elsewhere"
        elsewhere.write_bytes(b"engine-bytes")
        self.output.symlink_to(elsewhere)
        with self.assertRaises(build.BuildError):
            build.publish(self.engine, self.output, self.digest, root=self.root)

    def test_digest_mismatch_leaves_no_output_or_partial_file(self):
        with self.assertRaises(build.BuildError):
            build.publish(self.engine, self.output, "0" * 64, root=self.root)
        self.assertEqual(list(self.output.parent.iterdir()), [])


class CodesignTests(unittest.TestCase):
    SAMPLE = ("Executable=/fixture/sing-box\nIdentifier=sing-box\nFormat=Mach-O thin (arm64)\n"
              "CodeDirectory v=20400 size=1 flags=0x20002(adhoc,linker-signed) hashes=1+0 location=embedded\n"
              "Hash type=sha256 size=32\nCandidateCDHash sha256=" + "ab" * 32 + "\nCDHash=" + "ab" * 20 + "\nSignature=adhoc\n")

    def test_cdhash_is_read_from_codesign_output(self):
        self.assertEqual(build.parse_cdhash(self.SAMPLE), "ab" * 20)

    def test_missing_cdhash_is_rejected(self):
        with self.assertRaises(build.BuildError):
            build.parse_cdhash("Signature=adhoc\n")


class RepositoryPinTests(unittest.TestCase):
    def test_shared_inputs_match_pins(self):
        manifest = build.load_overlay_manifest()
        build.require_locks(build.LOCK_MOD, build.LOCK_SUM)
        for record in manifest["files"]:
            self.assertEqual(build.sha256_file(REPO / record["payload_relative"]), record["after_sha256"], record["source_relative"])

    def test_pins_equal_the_windows_recipe(self):
        recipe = (REPO / "scripts" / "Build-SecurityEngine.ps1").read_text(encoding="utf-8")
        literals = ("$sourceCommit = '" + build.SOURCE_COMMIT + "'", "$sourceUrl = '" + build.SOURCE_URL + "'",
                    "$sourceSha = '" + build.SOURCE_SHA256.upper() + "'", "$goVersion = '" + build.GO_VERSION + "'",
                    "$engineVersion = '" + build.ENGINE_VERSION + "'",
                    "$patchManifestSha = '" + build.PATCH_MANIFEST_SHA256.upper() + "'",
                    "$lockModSha = '" + build.LOCK_MOD_SHA256.upper() + "'", "$lockSumSha = '" + build.LOCK_SUM_SHA256.upper() + "'",
                    "$buildTags = '" + build.BUILD_TAGS + "'",
                    "'-X github.com/sagernet/sing-box/constant.Version=' + $engineVersion + ' -checklinkname=0 -s -w -buildid='")
        for literal in literals:
            self.assertIn(literal, recipe)
        self.assertEqual(build.LINKER_FLAGS, "-X github.com/sagernet/sing-box/constant.Version=" + build.ENGINE_VERSION +
                         " -checklinkname=0 -s -w -buildid=")


class BuildRecordTests(unittest.TestCase):
    VALID = ["sing-box: go1.26.9", "\tpath\tgithub.com/sagernet/sing-box/cmd/sing-box",
             "\tmod\tgithub.com/sagernet/sing-box\t(devel)\t", "\tbuild\t-buildmode=exe", "\tbuild\t-compiler=gc",
             "\tbuild\t-tags=with_purego,badlinkname,tfogo_checklinkname0", "\tbuild\t-trimpath=true", "\tbuild\tCGO_ENABLED=0",
             "\tbuild\tGOARCH=arm64", "\tbuild\tGOOS=darwin", "\tbuild\tGOARM64=v8.0"]

    def test_pinned_record_is_accepted(self):
        build.require_build_record(list(self.VALID))

    def test_changed_target_tags_or_toolchain_is_rejected(self):
        changes = {"\tbuild\tGOOS=darwin": "\tbuild\tGOOS=linux", "\tbuild\tCGO_ENABLED=0": "\tbuild\tCGO_ENABLED=1",
                   "\tbuild\t-trimpath=true": None,
                   "\tbuild\t-tags=with_purego,badlinkname,tfogo_checklinkname0": "\tbuild\t-tags=with_purego",
                   "sing-box: go1.26.9": "sing-box: go1.26.8",
                   "\tpath\tgithub.com/sagernet/sing-box/cmd/sing-box": "\tpath\texample.com/other"}
        for old, new in changes.items():
            with self.subTest(old=old):
                lines = [new if line == old else line for line in self.VALID if not (line == old and new is None)]
                with self.assertRaises(build.BuildError):
                    build.require_build_record(lines)

    def test_extra_or_repeated_settings_are_rejected(self):
        position = self.VALID.index("\tbuild\tGOOS=darwin")
        # A repeated key must not let a later line overwrite an earlier, wrong one.
        repeated = self.VALID[:position] + ["\tbuild\tGOOS=linux"] + self.VALID[position:]
        for name, lines in (("extra", self.VALID + ["\tbuild\t-gcflags=all=-N"]), ("repeated", repeated)):
            with self.subTest(name), self.assertRaises(build.BuildError):
                build.require_build_record(lines)


class EngineIdentityTests(unittest.TestCase):
    @staticmethod
    def pinned() -> list:
        return [build.ENGINE_SHA256, build.ENGINE_BYTES, build.ENGINE_CDHASH]

    def test_exact_pinned_engine_is_accepted(self):
        build.require_engine_identity(*self.pinned())

    def test_any_differing_field_is_rejected_with_the_measured_values(self):
        for index, value in enumerate(("0" * 64, build.ENGINE_BYTES + 1, "0" * 40)):
            measured = self.pinned()
            measured[index] = value
            with self.subTest(field=index):
                with self.assertRaises(build.BuildError) as raised:
                    build.require_engine_identity(*measured)
                self.assertIn(str(value), str(raised.exception))

    def test_build_checks_the_identity_before_publishing(self):
        source = inspect.getsource(build.build)
        self.assertLess(source.index("require_engine_identity("), source.index("publish("))


class FetchTests(TemporaryRoot):
    def setUp(self):
        super().setUp()
        self.saved_work = build.WORK_ROOT
        build.WORK_ROOT = self.root / "work"

    def tearDown(self):
        build.WORK_ROOT = self.saved_work
        super().tearDown()

    def source(self, data: bytes) -> str:
        path = self.root / "source.bin"
        path.write_bytes(data)
        return path.as_uri()

    def test_verified_download_and_cache_reuse(self):
        data = b"archive-bytes"
        destination = self.root / "work" / "cache" / "archive.bin"
        self.assertEqual(build.fetch_verified(self.source(data), destination, digest(data), 1024), destination)
        self.assertEqual(destination.read_bytes(), data)
        (self.root / "source.bin").unlink()
        self.assertEqual(build.fetch_verified("file:///nonexistent/archive.bin", destination, digest(data), 1024), destination)

    def test_cached_file_with_wrong_hash_is_replaced(self):
        data = b"archive-bytes"
        destination = self.root / "work" / "cache" / "archive.bin"
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b"stale")
        self.assertEqual(build.fetch_verified(self.source(data), destination, digest(data), 1024), destination)
        self.assertEqual(destination.read_bytes(), data)

    def test_oversized_or_mismatched_download_leaves_nothing(self):
        destination = self.root / "work" / "cache" / "archive.bin"
        for data, expected in ((b"x" * 2048, digest(b"x" * 2048)), (b"other", digest(b"archive"))):
            with self.subTest(size=len(data)), self.assertRaises(build.BuildError):
                build.fetch_verified(self.source(data), destination, expected, 1024)
            self.assertEqual(sorted(path.name for path in destination.parent.iterdir()), [])


class PinTests(unittest.TestCase):
    def test_engine_pins_match_the_swift_identity(self):
        swift = (MACOS / "Sources" / "DiscordAccessKit" / "Engine" / "EngineImage.swift").read_text(encoding="utf-8")
        matches = re.findall(r'static let pinned = EngineIdentity\(sha256: "([0-9a-f]{64})",\s*cdhash: "([0-9a-f]{40})"\)', swift)
        self.assertEqual(matches, [(build.ENGINE_SHA256, build.ENGINE_CDHASH)])


class MainTests(unittest.TestCase):
    def test_os_errors_are_reported_in_turkish(self):
        stream = io.StringIO()
        with mock.patch.object(build, "build", side_effect=OSError(2, "No such file or directory")), contextlib.redirect_stderr(stream):
            self.assertEqual(build.main([]), 1)
        self.assertTrue(stream.getvalue().startswith("HATA: "))
        self.assertNotIn("Traceback", stream.getvalue())


if __name__ == "__main__":
    unittest.main()
