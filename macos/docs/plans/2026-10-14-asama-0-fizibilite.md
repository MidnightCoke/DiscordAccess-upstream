# Aşama 0 — macOS Fizibilite Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Hedef:** Tasarımın (`macos/docs/2026-10-14-macos-tasarim.md`) dayandığı belirsizlikleri bu Mac'te ve gerçek engelli ağda kanıtla kapatmak:

- motorun macOS'ta tekrarlanabilir derlenmesi
- güncelleme köprüsü
- argümanla açılış
- eş kimliği
- Dock'tan açılışta çalışma anı proxy'si

**Mimari:** Kalıcı iş yalnız motor derleme betiği ve testleridir (Aşama 1'de sabitlenecek). Kapı, köprü, profil aracı ve kimlik yoklaması `macos/work/spike/` altında atılabilir deneme araçlarıdır. Bunlar Windows kurallarının (`ProcessGate`, `UpdateBridge`, `Package.Config`) birebir kopyasıdır ama süreç kimliği doğrulaması yapmaz. Discord profiline dokunan her adım yedekli, geri alınabilir ve kullanıcı onaylıdır.

**Teknolojiler:** Python 3.12 (standart kütüphane), Swift 6.4 (Darwin libproc, Security.framework), Go 1.26.9 (betik tarafından sabit hash'le indirilir), sing-box `1.14.3-discordaccess.2`, Discord 0.0.397 (Electron 37.6.0).

---

## Yürütme notları

- **Kullanıcı onayı:** Görev 7–12 Discord profiline dokunur veya Discord'u açar. Her biri **ONAY** işaretlidir; adım çalıştırılmadan önce kullanıcıdan açık onay alınır. Bu görevler alt ajanla değil, ana oturumda yürütülür.
- **Sandbox:** Şu adımlar sandbox dışında (`dangerouslyDisableSandbox: true`) çalıştırılır, kullanıcı ayrıca izin verir:
  - Discord profil klasörünü okuma veya yazma
  - Discord'u açma
  - `spike.py`'yi başlatma (Discord'un bağlanacağı yerel dinleyiciler)

  Diğer adımlar önce sandbox içinde denenir. Sandbox engeli çıkarsa aynı komut sandbox dışında yeniden çalıştırılır.
- **Commit:** Kullanıcının genel kuralı gereği commit yalnız açık istekle yapılır. "Kontrol noktası" adımları Git durumunu doğrular. Commit komutu yalnız kullanıcı isterse çalıştırılır.
- **Windows dokunulmazlığı:** Her kontrol noktasında `git status --porcelain --untracked-files=all` ve `git diff --name-only main` çıktısında yalnız `macos/` yolları bulunmalıdır.
- **Değişkenler:** Her Bash çağrısı ayrı bir kabuktur; değişkenler adımlar arasında korunmaz. Düzenek çalışırken `macos/work/spike/vars.sh` dosyası `PROXY`, `UPD`, `NEWUPD` ve `GATE` değerlerini taşır. Görev 6–12'deki komutlar `. macos/work/spike/vars.sh` ile başlar. Discord sürümü her seferinde `Info.plist`'ten okunur, çünkü Görev 8'de değişebilir.
- **Bekleme:** Ön planda `sleep` engellidir. Bir koşulu beklemek için Monitor aracı `until <koşul>; do sleep 2; done` döngüsüyle kullanılır.
- Tüm komutlar depo kökünden (`/Users/alpertekin/Documents/GitHub/DiscordAccess`), `feature/macos` dalında çalıştırılır.

## Dosya yapısı

| Dosya | Durum | Sorumluluk |
| --- | --- | --- |
| `macos/.gitignore` | Kalıcı, yeni | `macos/.build/`, `macos/build/`, `macos/work/` Git dışında. |
| `macos/scripts/build-engine.py` | Kalıcı, yeni | Sabit girdilerle macOS arm64 motoru; Windows tarifinin aynası. |
| `macos/tests/build-engine.test.py` | Kalıcı, yeni | Derleme betiğinin çevrimdışı testleri. |
| `macos/docs/2026-10-14-macos-tasarim.md` | Kalıcı, değişir | Aşama 0 sonuçları işlenir (Görev 13). |
| `macos/work/spike/spike.py` | Atılabilir | Motor + deneme kapısı + deneme köprüsü + 6 yapılandırma denetimi. |
| `macos/work/spike/profile_edit.py` | Atılabilir | Discord profilini inceleme, geçici değiştirme, geri alma. |
| `macos/work/spike/peer_probe.swift` | Atılabilir | Kapı istemcisini libproc ile bulma ve Team ID imza denetimi. |
| `~/Library/Application Support/DiscordAccess-spike/` | Atılabilir, depo dışı | Profil yedekleri ve sarmalayıcı kaydı. Discord, Documents klasörüne erişim izni istemesin diye depo dışında tutulur. |

---

### Görev 1: Çalışma alanı ve Git dışı kurallar

**Files:**
- Create: `macos/.gitignore`

- [ ] **Adım 1: Dalı ve temiz durumu doğrula**

Run: `git branch --show-current && git status --porcelain --untracked-files=all`
Expected: `feature/macos` ve yalnız `?? macos/...` satırları.

- [ ] **Adım 2: `macos/.gitignore` dosyasını oluştur**

```gitignore
# Mac derleme ve deneme çıktıları Git dışında kalır (yayın betiği temiz çalışma ağacı ister).
/.build/
/build/
/work/
```

- [ ] **Adım 3: Kuralların çalıştığını doğrula**

Run: `git check-ignore -v macos/work/x macos/build/engine/sing-box macos/.build/x`
Expected: üç satır da `macos/.gitignore:` ile başlar.

- [ ] **Adım 4: Kontrol noktası**

Run: `git diff --name-only main; git status --porcelain --untracked-files=all`
Expected: `git diff` boş; durum yalnız `macos/` altındaki yeni dosyaları gösterir.

---

### Görev 2: Motor derleme betiğinin testleri (önce başarısız)

**Files:**
- Create: `macos/tests/build-engine.test.py`

- [ ] **Adım 1: Test dosyasını yaz**

```python
"""Offline checks for macos/scripts/build-engine.py: synthetic fixtures only; no network, Go or engine run."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
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
            "HOME": "/Users/fixture", "GOFLAGS": "-mod=mod", "GOPROXY": "direct", "GOARCH": "amd64",
            "CGO_ENABLED": "1", "PATH": "/opt/homebrew/bin"})
        expected = {"GOOS": "darwin", "GOARCH": "arm64", "GOARM64": "v8.0", "CGO_ENABLED": "0", "GOTOOLCHAIN": "local",
                    "GOFLAGS": "", "GOPROXY": "https://proxy.golang.org", "GOSUMDB": "sum.golang.org", "GOVCS": "*:off",
                    "GOENV": "off", "GOWORK": "off"}
        for key, value in expected.items():
            self.assertEqual(environment[key], value, key)
        self.assertEqual(environment["HOME"], "/Users/fixture")
        self.assertEqual(environment["GOCACHE"], str(self.root / "b" / "gocache"))
        self.assertTrue(environment["PATH"].startswith(str(self.root / "b" / "go" / "bin") + os.pathsep))
        self.assertNotIn("/opt/homebrew/bin", environment["PATH"])


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


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `python3 -B macos/tests/build-engine.test.py`
Expected: `FileNotFoundError: [Errno 2] No such file or directory: '.../macos/scripts/build-engine.py'`

---

### Görev 3: Motor derleme betiği (testleri geçir)

**Files:**
- Create: `macos/scripts/build-engine.py`

- [ ] **Adım 1: Betiği yaz**

```python
#!/usr/bin/env python3
"""Build the pinned DiscordAccess sing-box engine for macOS arm64.

This mirrors scripts/Build-SecurityEngine.ps1 without changing it: the same
upstream commit, Go release, byte-pinned dependency locks, reviewed source
overlay, build tags and linker flags. Only GOOS/GOARCH and the Go archive for
this host differ. The script never runs sing-box and never edits system
settings. All output stays under macos/work and macos/build.
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
# Pinned in Aşama 1 after two identical builds. Empty: report the digest only.
ENGINE_SHA256 = ""
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
        raise BuildError(label + " sabit SHA-256 ile eşleşmedi: " + str(path))


def require_locks(go_mod: Path, go_sum: Path) -> None:
    require_digest(go_mod, LOCK_MOD_SHA256, "go.mod kilidi")
    require_digest(go_sum, LOCK_SUM_SHA256, "go.sum kilidi")


def require_inside(path: Path, root: Path) -> Path:
    """Return path when it stays under root and no component below root is a symlink."""
    root = Path(os.path.realpath(root))
    full = Path(os.path.normpath(path if Path(path).is_absolute() else root / path))
    try:
        relative = full.relative_to(root)
    except ValueError:
        raise BuildError("Yol izin verilen klasörün dışına çıktı: " + str(full)) from None
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError("Yolda sembolik bağ var: " + str(current))
    return full


def _relative_member(name: str, prefix: str) -> str:
    if not name.startswith(prefix) or "\\" in name or ":" in name or "\x00" in name or name.startswith("/"):
        raise BuildError("Beklenmeyen arşiv yolu: " + name)
    relative = name[len(prefix):]
    if relative and any(part in ("", ".", "..") for part in relative.rstrip("/").split("/")):
        raise BuildError("Arşivde yol geçişi yasak: " + name)
    return relative


def extract_zip(archive: Path, destination: Path, prefix: str, max_bytes: int, max_entries: int = 40000) -> int:
    """Extract a verified source zip like the Windows recipe: links are written as plain files."""
    destination.mkdir(parents=True, exist_ok=True)
    destination = Path(os.path.realpath(destination))
    written = total = 0
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > max_entries:
            raise BuildError("Kaynak arşivi girdi sınırını aştı.")
        for entry in entries:
            relative = _relative_member(entry.filename, prefix)
            if not relative:
                continue
            total += entry.file_size
            if entry.file_size > 268435456 or total > max_bytes:
                raise BuildError("Kaynak arşivi boyut sınırını aştı.")
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
                raise BuildError("Araç zinciri arşivi girdi sınırını aştı.")
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
                raise BuildError("Araç zinciri arşivinde normal dosya olmayan girdi: " + member.name)
            total += member.size
            if member.size > 268435456 or total > max_bytes:
                raise BuildError("Araç zinciri arşivi boyut sınırını aştı.")
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.extractfile(member)
            if data is None:
                raise BuildError("Araç zinciri dosyası okunamadı: " + member.name)
            with data, open(target, "xb") as output:
                shutil.copyfileobj(data, output)
            os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)
            written += 1
    return written


def load_overlay_manifest(path: Path = PATCH_MANIFEST) -> dict:
    require_digest(path, PATCH_MANIFEST_SHA256, "Yama manifesti")
    manifest = json.loads(path.read_bytes())
    files = manifest.get("files")
    if (manifest.get("schema") != 1 or manifest.get("main_source_commit") != SOURCE_COMMIT or
            manifest.get("source_archive_sha256") != SOURCE_SHA256 or manifest.get("engine_version") != ENGINE_VERSION or
            not isinstance(files, list) or not 1 <= len(files) <= 16):
        raise BuildError("Yama manifestinin kimliği geçersiz.")
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
            raise BuildError("Yama yolu veya kimliği geçersiz: " + str(name))
        seen.add(name)
        target = require_inside(source_root / name, source_root)
        payload = require_inside(repo_root / record["payload_relative"], repo_root)
        before = record.get("before_sha256")
        if before is None:
            if os.path.lexists(target):
                raise BuildError("Eklenen yama dosyası upstream kaynakta zaten var: " + name)
        elif (not isinstance(before, str) or not DIGEST_PATTERN.match(before) or
              not target.is_file() or sha256_file(target) != before):
            raise BuildError("Yamanın temel kaynak baytları eşleşmedi: " + name)
        data = payload.read_bytes() if payload.is_file() else b""
        if len(data) != size or hashlib.sha256(data).hexdigest() != after:
            raise BuildError("Yama yükünün baytları eşleşmedi: " + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "wb") as output:
            output.write(data)
        if sha256_file(target) != after:
            raise BuildError("Uygulanan yama baytları eşleşmedi: " + name)
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
    })
    environment["PATH"] = str(go_root / "bin") + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
    return environment


def parse_cdhash(output: str) -> str:
    match = re.search(r"^CDHash=([0-9a-f]{40}|[0-9a-f]{64})$", output, re.MULTILINE)
    if match is None:
        raise BuildError("codesign çıktısında CDHash bulunamadı.")
    return match.group(1)


def read_cdhash(binary: Path) -> str:
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(binary)], capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError("codesign motor imzasını okuyamadı: " + result.stderr.strip())
    return parse_cdhash(result.stderr + result.stdout)


def fetch_verified(url: str, destination: Path, expected: str) -> Path:
    destination = require_inside(destination, WORK_ROOT)
    if destination.is_file() and sha256_file(destination) == expected:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    for stale in (destination, partial):
        if os.path.lexists(stale):
            stale.unlink()
    context = ssl.create_default_context(cafile=CA_FILE)
    with urllib.request.urlopen(url, timeout=300, context=context) as response, open(partial, "xb") as output:
        shutil.copyfileobj(response, output)
    if sha256_file(partial) != expected:
        partial.unlink()
        raise BuildError("İndirilen arşiv sabit SHA-256 ile eşleşmedi: " + url)
    os.replace(partial, destination)
    return destination


def run_go(go: Path, arguments: list, environment: dict, cwd: Path) -> str:
    result = subprocess.run([str(go), *arguments], cwd=cwd, env=environment, capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError("Sabit Go komutu başarısız (çıkış " + str(result.returncode) + "): go " + " ".join(arguments) +
                         "\n" + result.stdout[-4000:] + result.stderr[-4000:])
    return result.stdout


def build(run_source_tests: bool, output: Path | None) -> dict:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise BuildError("Bu hedef macOS arm64 gerektirir.")
    require_locks(LOCK_MOD, LOCK_SUM)
    manifest = load_overlay_manifest()
    if output is not None:
        output = require_inside(output, MACOS_ROOT)
        if output.name != "sing-box" or not (output.parent == OUTPUT_ROOT or WORK_ROOT in output.parents):
            raise BuildError("--out yalnız macos/build/engine/sing-box veya macos/work altında bir sing-box yolu olabilir.")
        if output.is_dir():
            raise BuildError("Çıktı yolu bir klasör; değiştirilmedi.")
    build_root = require_inside(WORK_ROOT / ("engine-build-" + uuid.uuid4().hex), WORK_ROOT)
    build_root.mkdir(parents=True)
    source_root, go_root, artifacts = build_root / "source", build_root / "go", build_root / "artifacts"
    artifacts.mkdir()
    source_zip = fetch_verified(SOURCE_URL, CACHE_ROOT / ("sing-box-" + SOURCE_COMMIT + ".zip"), SOURCE_SHA256)
    go_archive = fetch_verified(GO_URL, CACHE_ROOT / "go1.26.9.darwin-arm64.tar.gz", GO_SHA256)
    extract_zip(source_zip, source_root, "sing-box-" + SOURCE_COMMIT + "/", 268435456)
    applied = apply_overlay(manifest, REPO_ROOT, source_root)
    extract_go_toolchain(go_archive, go_root)
    go = go_root / "bin" / "go"
    if not go.is_file():
        raise BuildError("Sabit Go çalıştırılabilir dosyası doğrulanmış arşivde yok.")
    shutil.copyfile(source_root / "go.mod", artifacts / "upstream-go.mod")
    shutil.copyfile(source_root / "go.sum", artifacts / "upstream-go.sum")
    shutil.copyfile(LOCK_MOD, source_root / "go.mod")
    shutil.copyfile(LOCK_SUM, source_root / "go.sum")
    require_locks(source_root / "go.mod", source_root / "go.sum")
    environment = go_environment(build_root, go_root)
    toolchain = run_go(go, ["version"], environment, source_root).strip()
    if toolchain != "go version " + GO_VERSION + " darwin/arm64":
        raise BuildError("Sabit araç zinciri kimliği eşleşmedi: " + toolchain)
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
        raise BuildError("Bakımı bırakılmış OpenPGP paketi bu hedefe derlenmemeli.")
    engine = artifacts / "sing-box"
    run_go(go, ["build", "-trimpath", "-buildvcs=false", "-mod=readonly", "-tags=" + BUILD_TAGS, "-ldflags=" + LINKER_FLAGS,
                "-o", str(engine), "./cmd/sing-box"], environment, source_root)
    require_locks(source_root / "go.mod", source_root / "go.sum")
    digest, size, cdhash = sha256_file(engine), engine.stat().st_size, read_cdhash(engine)
    if ENGINE_SHA256 and digest != ENGINE_SHA256:
        raise BuildError("Derlenen motor sabit SHA-256 ile eşleşmedi; kopyalanmadı. Kanıtlar: " + str(artifacts))
    build_info = run_go(go, ["version", "-m", str(engine)], environment, source_root).splitlines()
    build_info[0] = "sing-box: " + GO_VERSION
    (artifacts / "go-version-m.txt").write_text("\n".join(build_info) + "\n", encoding="utf-8")
    metadata = {
        "schema": 1, "target": "darwin/arm64", "engine_version": ENGINE_VERSION, "engine_sha256": digest,
        "engine_bytes": size, "engine_cdhash": cdhash, "engine_pin_enforced": bool(ENGINE_SHA256),
        "go_version": GO_VERSION, "go_archive_url": GO_URL, "go_archive_sha256": GO_SHA256,
        "main_source_commit": SOURCE_COMMIT, "source_archive_url": SOURCE_URL, "source_archive_sha256": SOURCE_SHA256,
        "main_source_patch_sha256": PATCH_MANIFEST_SHA256, "patched_files": applied,
        "lock_go_mod_sha256": LOCK_MOD_SHA256, "lock_go_sum_sha256": LOCK_SUM_SHA256,
        "build_tags": BUILD_TAGS, "linker_flags": LINKER_FLAGS, "source_unit_tests_ran": run_source_tests,
        "engine_executed": False,
    }
    (artifacts / "build-metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if output is not None:
        if output.exists():
            if sha256_file(output) != digest:
                raise BuildError("Mevcut çıktı motoru farklı; üzerine yazılmadı. Yeni derleme: " + str(engine))
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(engine, output)
    metadata["artifacts"] = str(artifacts)
    return metadata


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description="DiscordAccess motorunu macOS arm64 için sabit girdilerle derler; motoru çalıştırmaz.")
    parser.add_argument("--run-source-tests", action="store_true", help="Yamaların Go testlerini de çalıştır")
    parser.add_argument("--out", type=Path, help="macos/build/engine/sing-box (verilmezse yalnız kanıt klasörüne derlenir)")
    args = parser.parse_args(argv)
    try:
        result = build(args.run_source_tests, Path(os.path.abspath(args.out)) if args.out else None)
    except BuildError as error:
        print("HATA: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Adım 2: Testleri çalıştır, geçtiğini gör**

Run: `python3 -B macos/tests/build-engine.test.py -v`
Expected: `Ran 19 tests` ve `OK`.

- [ ] **Adım 3: Kontrol noktası**

Run: `git diff --name-only main; git status --porcelain --untracked-files=all`
Expected: `git diff` boş; yalnız `macos/` altında yeni dosyalar. Commit yalnız kullanıcı isterse:

```bash
git add macos/.gitignore macos/scripts/build-engine.py macos/tests/build-engine.test.py
git commit -m "build: add pinned macOS engine builder with offline checks"
```

- [ ] **Adım 4: Kod incelemesi düzeltmeleri (I1–I3)**

Kod kalitesi incelemesi kritik sorun bulmadı. Üç önemli bulgu Görev 4'ten önce test-önce düzeltilir. Önce testler güncellenir; bu aşamada 1 hata ve 5 eksik fonksiyon hatası beklenir. Ardından betik düzeltilir; 24 test geçer.

- **I1:** `go_environment`, `HOME` ve `GOTMPDIR` değerlerini derleme kökündeki `home/` ve `tmp/` klasörlerine yönlendirir. Böylece Go'nun ayar, telemetri ve iş dosyaları `macos/` dışına yazılmaz. Yalnız yamaların kendi testleri sistem geçici klasöründe kısa ömürlü dosya oluşturabilir.
- **I2:** Ortam testi, dışarıdan gelen `GOFIPS140`, `GOAMD64` ve `GOROOT_FINAL` değişkenlerinin atıldığını ve ilgisiz değişkenlerin korunduğunu doğrular.
- **I3:** `--out` yayımlaması `publish()` ile atomik yapılır. Yol yeniden denetlenir, farklı bir dosyanın üzerine yazılmaz, bağ izlenmez ve yarım dosya bırakılmaz (geçici dosya + SHA-256 + `os.link`).
- **Kanıt:** `build-metadata.json` içine `build_script_sha256`, kanıt klasörüne `SHA256SUMS.txt` eklenir.

Güncel hash'ler:
- `macos/scripts/build-engine.py`: `9d1f3c3fbcb1e6bca9d8ceed4ecd48660f79ac79b109cf2f8fe3d5d495c663c4`
- `macos/tests/build-engine.test.py`: `4c92e60f523ebba1af6f515a683d72eccb9a39c4b6c2dc21edaf14bd6430facc`

Görev 2–3'teki kod blokları ilk onaylanan sürümdür; güncel kod depodaki dosyalardır.

Aşama 1'e ertelenen küçük bulgular:
- `OSError` için Türkçe hata mesajı
- indirme boyut sınırı
- `go version -m` alanlarının doğrulanması
- ek uç durum testleri

---

### Görev 4: Motoru derle, Go testlerini çalıştır, tekrarlanabilirliği göster

**Files:**
- Output (Git dışı): `macos/build/engine/sing-box`, `macos/work/engine-build-*/artifacts/`

- [ ] **Adım 1: İlk derleme (yamaların Go testleriyle)**

Süre: ilk derleme 5–10 dakika. Bash aracında 600000 ms zaman aşımıyla veya arka planda çalıştırılır.

Run: `python3 -B macos/scripts/build-engine.py --run-source-tests --out macos/build/engine/sing-box`
Expected: Sıfır çıkış kodu ve JSON çıktısı. Çıktıda `"source_unit_tests_ran": true`, `"engine_pin_enforced": false`, 64 haneli `"engine_sha256"`, 40 haneli `"engine_cdhash"` ve `"artifacts"` yolu bulunur. Bu dört değeri not edin.

- [ ] **Adım 2: Go test raporunu doğrula**

Run: `grep -E "^(ok|FAIL|---)" macos/work/engine-build-*/artifacts/source-unit-tests.txt`
Expected: Üç paket için `ok` satırı (`internal/discordaccess/httpguard`, `protocol/http`, `common/listener`); `FAIL` yok.

- [ ] **Adım 3: İkinci, bağımsız derleme (tekrarlanabilirlik)**

Run: `python3 -B macos/scripts/build-engine.py --out macos/build/engine/sing-box`
Expected: Sıfır çıkış kodu ve Adım 1 ile aynı `engine_sha256`. Betik, farklı bir motorun `--out` üzerine yazılmasını reddeder. Bu yüzden başarılı çıkış iki derlemenin byte düzeyinde aynı olduğunu kanıtlar. Hash farklıysa betik `HATA: Mevcut çıktı motoru farklı` ile durur. Bu durumda Görev 13'e "tekrarlanabilir değil" olarak kaydedilir ve devam edilir; deney görevleri ilk motorla sürer.

- [ ] **Adım 4: İmzayı ve sürümü kontrol et**

Run: `codesign -dv --verbose=4 macos/build/engine/sing-box 2>&1 | grep -E "^(Identifier|CDHash|Signature)="; macos/build/engine/sing-box version | head -1`
Expected: `Identifier=a.out`, `CDHash=<Adım 1 ile aynı>`, `Signature=adhoc`, `sing-box version 1.14.3-discordaccess.2`.

Go'nun iç bağlayıcısı ad-hoc imzada tanımlayıcıyı her zaman `a.out` olarak yazar (`cmd/link/internal/ld/macho.go`). Uygulama paketine gömülürken motor anlamlı bir tanımlayıcıyla yeniden imzalanacaktır. Bu işlem cdhash'i değiştirir; bu yüzden sabitleme imza sonrası değerlerle yapılmalıdır (Aşama 2).

- [ ] **Adım 5: Büyük ara dosyaları temizle, kanıtları sakla**

Go modül önbelleği salt okunur dosyalar içerir; önce yazma izni verilir. Yalnız bu görevde oluşturulan derleme klasörleri hedeflenir.

```bash
for d in macos/work/engine-build-*; do chmod -R u+w "$d/modules" "$d/gopath" 2>/dev/null; rm -rf "$d/go" "$d/gopath" "$d/gocache" "$d/modules" "$d/source" "$d/home" "$d/tmp"; done
ls macos/work/engine-build-*/artifacts
```

Expected: Her derleme klasöründe yalnız `artifacts/` kalır. İçinde `build-metadata.json`, `SHA256SUMS.txt`, `sing-box`, `go-version-m.txt` ve diğer kanıtlar bulunur.

---

### Görev 5: Deneme düzeneği ve altı DNS yapılandırmasının motorla denetimi

**Files:**
- Create (Git dışı): `macos/work/spike/spike.py`

- [ ] **Adım 1: `spike.py` dosyasını yaz**

```python
#!/usr/bin/env python3
"""Aşama 0 deneme düzeneği: motor + deneme kapısı + deneme köprüsü.

Atılabilir bir fizibilite aracıdır; üretim kodu değildir. Kapı süreç kimliği
doğrulamaz (bu, Aşama 1'deki PeerIdentity'nin işidir). Yalnız 127.0.0.1
üzerinde ve yalnız çalıştığı süre boyunca dinler.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import http.client
import http.server
import json
import os
import secrets
import shlex
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

SPIKE = Path(os.path.realpath(__file__)).parent
MACOS = SPIKE.parent.parent
LOGS = SPIKE / "logs"
STATE = SPIKE / "state.json"
VARS = SPIKE / "vars.sh"
DEFAULT_ENGINE = MACOS / "build" / "engine" / "sing-box"
# Same lists as Windows ProcessGate (src/Proxy.cs).
ALLOWED = ("discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media", "discordcdn.com",
           "discordstatus.com", "discord.gift")
UPLOAD_HOSTS = ("discord-attachments-uploads-prd.storage.googleapis.com",)
CHALLENGE = ("hcaptcha.com",)
METHODS = {"GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"}
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection", "te",
              "trailers", "transfer-encoding", "upgrade"}
CA_FILE = "/etc/ssl/cert.pem"
LOG_LOCK = threading.Lock()


def log(name: str, line: str) -> None:
    LOGS.mkdir(parents=True, exist_ok=True)
    with LOG_LOCK, open(LOGS / name, "a", encoding="utf-8") as stream:
        stream.write(time.strftime("%H:%M:%S ") + line + "\n")


def under(host: str, domains) -> bool:
    host = host.lower().rstrip(".")
    return any(host == domain or host.endswith("." + domain) for domain in domains)


def engine_config(provider: str, record_fragment: bool, username: str, password: str, port: int) -> dict:
    """Same policy as Windows Package.Config (src/DiscordAccess.cs)."""
    server_name = {"google": "dns.google", "cloudflare-ip": "1.1.1.1"}.get(provider, "cloudflare-dns.com")
    dns_tls = {"enabled": True, "server_name": server_name}
    if record_fragment:
        dns_tls["record_fragment"] = True
    allowed, inbound = list(ALLOWED), ["private-backend"]
    return {
        "log": {"disabled": True},
        "dns": {"servers": [{"type": "https", "tag": "discord-dns", "server": "8.8.8.8" if provider == "google" else "1.1.1.1",
                             "server_port": 443, "path": "/dns-query", "tls": dns_tls}],
                "final": "discord-dns", "strategy": "ipv4_only"},
        "inbounds": [{"type": "http", "tag": "private-backend", "listen": "127.0.0.1", "listen_port": port,
                      "users": [{"username": username, "password": password}]}],
        "outbounds": [{"type": "direct", "tag": "discord-direct", "domain_resolver": {"server": "discord-dns", "strategy": "ipv4_only"}}],
        "route": {"rules": [
            {"inbound": inbound, "network": "tcp", "domain_suffix": allowed, "port": 443, "action": "route",
             "outbound": "discord-direct", "tls_record_fragment": True},
            {"inbound": inbound, "network": "tcp", "domain_suffix": ["discord.media"], "port_range": ["1:65535"],
             "action": "route", "outbound": "discord-direct"},
            {"inbound": inbound, "network": "tcp", "domain_suffix": allowed, "port": 80, "action": "route", "outbound": "discord-direct"},
            {"inbound": inbound, "network": "tcp", "domain": list(UPLOAD_HOSTS), "port": 443, "action": "route", "outbound": "discord-direct"},
            {"inbound": inbound, "network": "tcp", "domain_suffix": list(CHALLENGE), "port": 443, "action": "route", "outbound": "discord-direct"},
            {"action": "reject"},
        ], "default_domain_resolver": "discord-dns"},
    }


def check_configs(engine: Path) -> int:
    folder = SPIKE / "configs"
    folder.mkdir(parents=True, exist_ok=True)
    failures = 0
    for provider in ("cloudflare", "cloudflare-ip", "google"):
        for fragment in (False, True):
            name = provider + ("-fragment" if fragment else "-plain")
            path = folder / (name + ".json")
            config = engine_config(provider, fragment, "engine-smoke-fixture-user", "engine-smoke-fixture-password", 32123)
            path.write_text(json.dumps(config), encoding="utf-8")
            result = subprocess.run([str(engine), "check", "-c", str(path)], capture_output=True, text=True, timeout=10)
            passed = result.returncode == 0
            failures += 0 if passed else 1
            print(name + ": " + ("PASS" if passed else "FAIL " + (result.stderr or result.stdout).strip()[:300]))
    print(("PASS" if failures == 0 else "FAIL") + ": 6 yapılandırmadan " + str(6 - failures) + " tanesi motor tarafından kabul edildi.")
    return 0 if failures == 0 else 1


class Gate:
    """Spike-only gate: same host/port policy as ProcessGate, adds the engine credential."""

    def __init__(self, engine_port: int, authorization: str):
        self.engine_port, self.authorization, self.port, self.server = engine_port, authorization, 0, None

    async def start(self) -> None:
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", 0, limit=65536)
        self.port = self.server.sockets[0].getsockname()[1]

    @staticmethod
    def permitted(method: str, host: str, port: int) -> bool:
        if method == "CONNECT":
            allowed = under(host, ALLOWED) or (port == 443 and (under(host, CHALLENGE) or host.lower() in UPLOAD_HOSTS))
            return allowed and (port == 443 or under(host, ("discord.media",)))
        return method in METHODS and port == 80 and under(host, ALLOWED)

    async def handle(self, reader, writer) -> None:
        target, upstream = "unknown", None
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 15)
            if len(head) > 32768 or any(byte > 127 for byte in head):
                raise ValueError("header")
            lines = head.decode("ascii")[:-4].split("\r\n")
            method, uri, _version = lines[0].split(" ")
            if method == "CONNECT":
                host, _, port_text = uri.rpartition(":")
                port = int(port_text)
            else:
                parts = urllib.parse.urlsplit(uri)
                if parts.scheme != "http" or not parts.hostname:
                    raise ValueError("target")
                host, port = parts.hostname, parts.port or 80
            target = method + " " + host.lower() + ":" + str(port)
            if not self.permitted(method, host, port):
                log("gate.log", "REJECT " + target)
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
                return
            headers = [line for line in lines[1:] if not line.lower().startswith("proxy-authorization:")]
            outgoing = "\r\n".join([lines[0], *headers, "Proxy-Authorization: " + self.authorization, "", ""])
            upstream_reader, upstream = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", self.engine_port), 5)
            upstream.write(outgoing.encode("ascii"))
            await upstream.drain()
            log("gate.log", "OK " + target)
            await asyncio.gather(pipe(reader, upstream), pipe(upstream_reader, writer))
        except Exception as error:
            log("gate.log", "FAIL " + target + " " + type(error).__name__)
        finally:
            for stream in (writer, upstream):
                if stream is not None:
                    stream.close()


async def pipe(reader, writer) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except Exception:
            pass


class BridgeServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    token = ""
    base_url = ""
    engine_port = 0
    authorization = ""


class BridgeHandler(http.server.BaseHTTPRequestHandler):
    """Spike-only update bridge: Windows UpdateBridge routes and URL rewriting, without peer checks."""

    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args) -> None:
        pass

    def do_GET(self) -> None:
        self.forward()

    def do_HEAD(self) -> None:
        self.forward()

    def do_POST(self) -> None:
        self.forward()

    def target(self):
        prefix = "/" + self.server.token
        if not self.path.startswith(prefix + "/"):
            raise ValueError("token")
        rest = self.path[len(prefix):]
        if rest.startswith("/updates/"):
            return "https://updates.discord.com/" + rest[len("/updates/"):], "updates"
        if rest == "/legacy" or rest.startswith("/legacy/") or rest.startswith("/legacy?"):
            return "https://discord.com/api" + rest[len("/legacy"):], "legacy"
        if rest.startswith("/download/"):
            remainder = rest[len("/download/"):]
            slash = remainder.find("/")
            host = remainder[:slash] if slash > 0 else ""
            if not host or not under(host, ALLOWED):
                raise ValueError("download-host")
            return "https://" + host + remainder[slash:], "download:" + host.lower()
        raise ValueError("route")

    def local_url(self, url: str) -> str:
        parts = urllib.parse.urlsplit(url)
        if (parts.scheme != "https" or not parts.hostname or not under(parts.hostname, ALLOWED) or
                parts.port not in (None, 443) or parts.username):
            raise ValueError("redirect-host " + str(parts.hostname))
        query = "?" + parts.query if parts.query else ""
        return self.server.base_url + "/download/" + parts.hostname.lower() + (parts.path or "/") + query

    def rewrite(self, value):
        if isinstance(value, dict):
            return {key: self.rewrite(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.rewrite(item) for item in value]
        if isinstance(value, str) and value.startswith("https://"):
            try:
                return self.local_url(value)
            except ValueError:
                return value
        return value

    def forward(self) -> None:
        category = "?"
        try:
            url, category = self.target()
            parts = urllib.parse.urlsplit(url)
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length > 0 else None
            headers = {key: value for key, value in self.headers.items()
                       if key.lower() not in HOP_BY_HOP and key.lower() not in ("host", "accept-encoding", "content-length")}
            connection = http.client.HTTPSConnection("127.0.0.1", self.server.engine_port, timeout=120,
                                                     context=ssl.create_default_context(cafile=CA_FILE))
            connection.set_tunnel(parts.hostname, 443, headers={"Proxy-Authorization": self.server.authorization})
            query = "?" + parts.query if parts.query else ""
            connection.request(self.command, (parts.path or "/") + query, body=body, headers=headers)
            response = connection.getresponse()
            location = response.getheader("Location")
            if location:
                absolute = urllib.parse.urljoin(url, location)
                log("bridge.log", self.command + " " + category + " redirect-host=" + str(urllib.parse.urlsplit(absolute).hostname))
                location = self.local_url(absolute)
            content_type = response.getheader("Content-Type") or ""
            no_body = self.command == "HEAD" or response.status in (204, 304) or 100 <= response.status < 200
            if "json" in content_type.lower() and response.status == 200 and not no_body:
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise ValueError("json-too-large")
                data = json.dumps(self.rewrite(json.loads(raw))).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(data)
                log("bridge.log", self.command + " " + category + " 200 json-rewritten " + str(len(data)) + "B")
            else:
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in HOP_BY_HOP and key.lower() not in ("location", "content-length", "connection"):
                        self.send_header(key, value)
                if location:
                    self.send_header("Location", location)
                declared = response.getheader("Content-Length")
                chunked = not no_body and declared is None
                if declared is not None:
                    self.send_header("Content-Length", declared)
                elif chunked:
                    self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Connection", "close")
                self.end_headers()
                total = 0
                if not no_body:
                    while True:
                        chunk = response.read(65536)
                        if not chunk:
                            break
                        total += len(chunk)
                        self.wfile.write(b"%X\r\n%s\r\n" % (len(chunk), chunk) if chunked else chunk)
                    if chunked:
                        self.wfile.write(b"0\r\n\r\n")
                log("bridge.log", self.command + " " + category + " " + str(response.status) + " " + str(total) + "B")
            connection.close()
        except Exception as error:
            log("bridge.log", self.command + " " + category + " FAIL " + type(error).__name__ + " " + str(error)[:120])
            try:
                self.send_error(502)
            except Exception:
                pass
        finally:
            self.close_connection = True


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_listener(port: int, engine: subprocess.Popen, seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if engine.poll() is not None:
            raise RuntimeError("Motor erken kapandı (çıkış " + str(engine.returncode) + ").")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("Motor dinleyicisi hazır olmadı.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Aşama 0 deneme düzeneği")
    parser.add_argument("--engine", type=Path, default=DEFAULT_ENGINE)
    parser.add_argument("--dns", choices=("cloudflare-ip", "cloudflare", "google"), default="cloudflare-ip")
    parser.add_argument("--dns-record-fragment", action="store_true")
    parser.add_argument("--check-configs", action="store_true", help="6 DNS yapılandırmasını 'sing-box check' ile doğrula ve çık")
    parser.add_argument("--engine-log", action="store_true", help="Tanı için motor kaydını logs/engine.log dosyasına yaz")
    args = parser.parse_args()
    engine_path = Path(os.path.abspath(args.engine))
    if not os.access(engine_path, os.X_OK):
        print("Motor bulunamadı: " + str(engine_path), file=sys.stderr)
        return 1
    if args.check_configs:
        return check_configs(engine_path)
    LOGS.mkdir(parents=True, exist_ok=True)
    username, password = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    authorization = "Basic " + base64.b64encode((username + ":" + password).encode()).decode()
    engine_port = free_port()
    config = engine_config(args.dns, args.dns_record_fragment, username, password, engine_port)
    if args.engine_log:
        config["log"] = {"level": "info", "timestamp": True}
    engine_output = open(LOGS / "engine.log", "ab")
    engine = subprocess.Popen([str(engine_path), "run", "-c", "stdin", "--disable-color"], stdin=subprocess.PIPE,
                              stdout=engine_output, stderr=engine_output, cwd=str(engine_path.parent))
    try:
        engine.stdin.write(json.dumps(config).encode("utf-8"))
        engine.stdin.close()
        wait_for_listener(engine_port, engine, 12)
        bridge = BridgeServer(("127.0.0.1", 0), BridgeHandler)
        bridge.token = secrets.token_hex(24)
        bridge.engine_port, bridge.authorization = engine_port, authorization
        bridge.base_url = "http://127.0.0.1:" + str(bridge.server_address[1]) + "/" + bridge.token
        threading.Thread(target=bridge.serve_forever, daemon=True).start()
        loop = asyncio.new_event_loop()
        gate = Gate(engine_port, authorization)
        loop.run_until_complete(gate.start())
        state = {"gate_port": gate.port, "proxy_url": "http://127.0.0.1:" + str(gate.port), "bridge_base": bridge.base_url,
                 "update_endpoint": bridge.base_url + "/legacy", "new_update_endpoint": bridge.base_url + "/updates/",
                 "engine_pid": engine.pid, "dns": args.dns}
        STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        os.chmod(STATE, 0o600)
        exports = (("PROXY", state["proxy_url"]), ("UPD", state["update_endpoint"]),
                   ("NEWUPD", state["new_update_endpoint"]), ("GATE", state["gate_port"]))
        VARS.write_text("".join("export " + name + "=" + shlex.quote(str(value)) + "\n" for name, value in exports), encoding="utf-8")
        os.chmod(VARS, 0o600)
        print(json.dumps(state, indent=2), flush=True)
        print("Hazır. Durdurmak için Ctrl+C veya SIGTERM.", flush=True)
        for signum in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(signum, loop.stop)
        loop.run_forever()
        gate.server.close()
        bridge.shutdown()
        return 0
    finally:
        if engine.poll() is None:
            engine.terminate()
            try:
                engine.wait(5)
            except subprocess.TimeoutExpired:
                engine.kill()
                engine.wait(5)
        engine_output.close()
        for path in (STATE, VARS):
            if path.exists():
                path.unlink()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Adım 2: Altı DNS yapılandırmasını motorla denetle**

Run: `python3 -B macos/work/spike/spike.py --check-configs`
Expected:

```
cloudflare-plain: PASS
cloudflare-fragment: PASS
cloudflare-ip-plain: PASS
cloudflare-ip-fragment: PASS
google-plain: PASS
google-fragment: PASS
PASS: 6 yapılandırmadan 6 tanesi motor tarafından kabul edildi.
```

---

### Görev 6: Düzeneği başlat ve Discord'suz duman testleri yap

- [ ] **Adım 1: Düzeneği arka planda başlat (sandbox dışında)**

Bash aracında `run_in_background: true` ve `dangerouslyDisableSandbox: true` ile:

Run: `python3 -B macos/work/spike/spike.py`
Expected: `gate_port`, `proxy_url`, `bridge_base`, `update_endpoint`, `new_update_endpoint`, `engine_pid` içeren JSON ve `Hazır.` satırı. Aynı değerler `macos/work/spike/state.json` dosyasındadır; kabuk değişkenleri `macos/work/spike/vars.sh` dosyasındadır.

- [ ] **Adım 2: Kapı üzerinden engelli API'ye ulaşıldığını doğrula**

```bash
. macos/work/spike/vars.sh
curl -sS -m 20 -x "$PROXY" https://discord.com/api/v10/gateway; echo
```

Expected: `{"url":"wss://gateway.discord.gg"}` (veya aynı alanı içeren JSON). Bu, motorun DoH ve TLS kayıt parçalamayla engeli macOS'ta aştığının ilk kanıtıdır.

- [ ] **Adım 3: Kapının izinsiz hedefi reddettiğini doğrula**

Run: `. macos/work/spike/vars.sh; curl -sS -m 10 -x "$PROXY" -o /dev/null -w '%{http_connect}\n' https://example.com/; tail -n 3 macos/work/spike/logs/gate.log`
Expected: `403` ve kayıtta `REJECT CONNECT example.com:443`.

- [ ] **Adım 4: Squirrel adresini köprüden sorgula**

```bash
. macos/work/spike/vars.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Discord.app/Contents/Info.plist)
curl -sS -m 30 -o macos/work/spike/feed.json -w '%{http_code}\n' "$UPD/updates/stable?platform=osx&version=$VERSION"
```

Expected: `204` (güncelleme yok) veya `200` (güncelleme var). `200` ise:

Run: `python3 -c 'import json;d=json.load(open("macos/work/spike/feed.json"));print(d.get("name"), d.get("url","")[:80])'`
Expected: Yeni sürüm adı ve `http://127.0.0.1:<köprü>/<belirteç>/download/dl.discordapp.net/...` ile başlayan, köprüye yeniden yazılmış adres. Sonucu (204/200, sürüm) Görev 8 için not edin.

- [ ] **Adım 5: Modül sürüm listesini köprüden sorgula**

```bash
. macos/work/spike/vars.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Discord.app/Contents/Info.plist)
curl -sS -m 30 -o macos/work/spike/versions.json -w '%{http_code}\n' "$UPD/modules/stable/versions.json?host_version=$VERSION&platform=osx"
python3 -c 'import json;print(sorted(json.load(open("macos/work/spike/versions.json")))[:12])'
tail -n 5 macos/work/spike/logs/bridge.log
```

Expected: `200`; listede `discord_desktop_core` dahil modül adları; köprü kaydında `GET legacy 200 json-rewritten ...` satırları.

---

### Görev 7: Discord profil yapısını incele (ONAY)

**Files:**
- Create (Git dışı): `macos/work/spike/profile_edit.py`

- [ ] **Adım 1: `profile_edit.py` dosyasını yaz**

```python
#!/usr/bin/env python3
"""Aşama 0: Discord profilinde geçici ve geri alınabilir değişiklikler.

Atılabilir bir deneme aracıdır. Yalnız settings.json içindeki sahiplenilen
anahtarlara ve seçilen sürümün discord_desktop_core/index.js dosyasına dokunur.
Discord açıkken çalışmaz. Yedekler:
~/Library/Application Support/DiscordAccess-spike/backup
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

DISCORD_DATA = Path.home() / "Library" / "Application Support" / "discord"
SETTINGS = DISCORD_DATA / "settings.json"
SPIKE_DATA = Path.home() / "Library" / "Application Support" / "DiscordAccess-spike"
BACKUP = SPIKE_DATA / "backup"
STATE = BACKUP / "state.json"
WRAPPER_LOG = SPIKE_DATA / "wrapper.log"
OWNED_KEYS = ("UPDATE_ENDPOINT", "NEW_UPDATE_ENDPOINT", "SKIP_HOST_UPDATE")
OFFICIAL_ENTRY = re.compile(r"\Amodule\.exports\s*=\s*require\(\s*(['\"])\./core\.asar\1\s*\);?\Z")
VERSION_NAME = re.compile(r"\A[0-9]+\.[0-9]+\.[0-9]+\Z")
WRAPPER = """// DiscordAccess macOS spike wrapper (Asama 0) - temporary; profile_edit.py restore removes it
if (process.type === 'browser') {
  try {
    const electron = require('electron');
    const fs = require('fs');
    const proxy = __PROXY_JSON__;
    const logPath = __LOG_JSON__;
    const log = (message) => { try { fs.appendFileSync(logPath, new Date().toISOString() + ' ' + message + '\\n'); } catch (_) {} };
    const current = electron.app.commandLine.getSwitchValue('proxy-server');
    log('wrapper loaded; proxy switch ' + (current === proxy ? 'matches session' : (current ? 'differs' : 'absent')));
    if (current !== proxy) {
      const session = electron.session.defaultSession;
      const ready = session.setProxy({ proxyRules: proxy, proxyBypassRules: '127.0.0.1;localhost' })
        .then(() => session.resolveProxy('https://discord.com/app'))
        .then((resolved) => log('setProxy applied; resolveProxy=' + resolved),
              (error) => log('setProxy failed: ' + (error && error.message)));
      electron.app.on('web-contents-created', (_event, contents) => {
        const original = contents.loadURL;
        contents.loadURL = function (...args) {
          let host = 'unknown';
          try { host = new URL(String(args[0])).host; } catch (_) {}
          log('loadURL waits for proxy: ' + host);
          return ready.then(() => original.apply(this, args));
        };
      });
    }
  } catch (error) {
    try { require('fs').appendFileSync(__LOG_JSON__, new Date().toISOString() + ' wrapper error: ' + (error && error.message) + '\\n'); } catch (_) {}
  }
}
module.exports = require('./core.asar');
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def discord_running() -> bool:
    return subprocess.run(["/usr/bin/pgrep", "-x", "Discord"], capture_output=True).returncode == 0


def require_closed() -> None:
    if discord_running():
        sys.exit("Discord açık. Önce Discord'u tamamen kapatın (Cmd+Q) ve tekrar deneyin.")


def write_replacing(path: Path, data: bytes) -> None:
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    temporary = path.with_name("." + path.name + ".discordaccess-spike-" + str(os.getpid()))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def versions() -> list:
    return sorted(path for path in DISCORD_DATA.iterdir()
                  if VERSION_NAME.match(path.name) and path.is_dir() and not path.is_symlink())


def core_entry(version: str) -> Path:
    if not VERSION_NAME.match(version):
        sys.exit("Geçersiz sürüm adı: " + version)
    return DISCORD_DATA / version / "modules" / "discord_desktop_core" / "index.js"


def inspect() -> int:
    print("Discord veri klasörü:", DISCORD_DATA)
    print("Üst düzey adlar:", sorted(path.name for path in DISCORD_DATA.iterdir()))
    settings = json.loads(SETTINGS.read_text(encoding="utf-8"))
    print("settings.json anahtarları:", sorted(settings))
    for key in OWNED_KEYS + ("USE_NEW_UPDATER", "SKIP_MODULE_UPDATE", "chromiumSwitches"):
        print("  " + key + " =", json.dumps(settings[key]) if key in settings else "<yok>")
    for version in versions():
        modules = version / "modules"
        print("Sürüm klasörü:", version.name)
        print("  modules:", sorted(path.name for path in modules.iterdir()) if modules.is_dir() else "<yok>")
        entry = core_entry(version.name)
        if entry.is_file():
            text = entry.read_text(encoding="utf-8")
            print("  core giriş dosyası:", repr(text[:300]), "| resmi biçim:", bool(OFFICIAL_ENTRY.match(text.strip())))
            print("  core klasörü:", sorted(path.name for path in entry.parent.iterdir()))
        installed = modules / "installed.json"
        if installed.is_file():
            print("  installed.json:", installed.read_text(encoding="utf-8")[:1500])
    logs = DISCORD_DATA / "logs"
    if logs.is_dir():
        print("logs:", sorted(path.name for path in logs.iterdir()))
    return 0


def load_state() -> dict:
    return json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {}


def save_state(state: dict) -> None:
    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    os.chmod(STATE, 0o600)


def apply(update_endpoint: str, new_update_endpoint: str, skip_host_update: bool,
          wrapper_proxy: str | None, version: str | None) -> int:
    require_closed()
    BACKUP.mkdir(parents=True, exist_ok=True)
    os.chmod(SPIKE_DATA, 0o700)
    os.chmod(BACKUP, 0o700)
    state = load_state()
    raw = SETTINGS.read_bytes()
    settings = json.loads(raw)
    if "settings" not in state:
        backup = BACKUP / "settings.json.orig"
        backup.write_bytes(raw)
        os.chmod(backup, 0o600)
        state["settings"] = {key: {"present": key in settings, "value": settings.get(key)} for key in OWNED_KEYS}
    settings["UPDATE_ENDPOINT"] = update_endpoint
    settings["NEW_UPDATE_ENDPOINT"] = new_update_endpoint
    if skip_host_update:
        settings["SKIP_HOST_UPDATE"] = True
    write_replacing(SETTINGS, (json.dumps(settings, indent=2) + "\n").encode("utf-8"))
    print("settings.json güncellendi: UPDATE_ENDPOINT, NEW_UPDATE_ENDPOINT" + (", SKIP_HOST_UPDATE" if skip_host_update else ""))
    if wrapper_proxy:
        if version is None:
            sys.exit("--wrapper-proxy için --version gerekir.")
        entry = core_entry(version)
        current = entry.read_bytes()
        if "core" not in state:
            if not OFFICIAL_ENTRY.match(current.decode("utf-8").strip()):
                sys.exit("Çekirdek giriş dosyası beklenen resmi biçimde değil; değiştirilmedi.")
            backup = BACKUP / "index.js.orig"
            backup.write_bytes(current)
            os.chmod(backup, 0o600)
            state["core"] = {"path": str(entry), "sha256": digest(current)}
        elif state["core"]["path"] != str(entry):
            sys.exit("Başka bir sürümün çekirdek dosyası zaten değiştirilmiş; önce restore çalıştırın.")
        wrapper = (WRAPPER.replace("__PROXY_JSON__", json.dumps(wrapper_proxy))
                   .replace("__LOG_JSON__", json.dumps(str(WRAPPER_LOG)))).encode("utf-8")
        write_replacing(entry, wrapper)
        state["core"]["wrapper_sha256"] = digest(wrapper)
        print("Çekirdek giriş dosyasına deneme sarmalayıcısı yazıldı:", entry)
    save_state(state)
    return 0


def restore() -> int:
    require_closed()
    state = load_state()
    if not state:
        print("Geri alınacak deneme değişikliği yok.")
        return 0
    if "settings" in state:
        settings = json.loads(SETTINGS.read_text(encoding="utf-8"))
        for key, original in state["settings"].items():
            if original["present"]:
                settings[key] = original["value"]
            else:
                settings.pop(key, None)
        write_replacing(SETTINGS, (json.dumps(settings, indent=2) + "\n").encode("utf-8"))
        print("settings.json sahiplenilen anahtarları özgün değerlerine döndü.")
    core = state.get("core")
    if core:
        entry = Path(core["path"])
        current = entry.read_bytes() if entry.is_file() else None
        if current is not None and digest(current) == core.get("wrapper_sha256"):
            write_replacing(entry, (BACKUP / "index.js.orig").read_bytes())
            if digest(entry.read_bytes()) != core["sha256"]:
                sys.exit("Çekirdek giriş dosyası geri yazıldı ama hash eşleşmedi; yedek korunuyor: " + str(BACKUP))
            print("Çekirdek giriş dosyası özgün haline döndü.")
        else:
            print("UYARI: çekirdek giriş dosyası deneme sarmalayıcısı değil (Discord güncellemiş olabilir); üzerine yazılmadı.")
    STATE.rename(BACKUP / ("state-restored-" + str(int(time.time())) + ".json"))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Aşama 0 Discord profil aracı")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inspect")
    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("--update-endpoint", required=True)
    apply_parser.add_argument("--new-update-endpoint", required=True)
    apply_parser.add_argument("--skip-host-update", action="store_true")
    apply_parser.add_argument("--wrapper-proxy")
    apply_parser.add_argument("--version")
    commands.add_parser("restore")
    args = parser.parse_args()
    if args.command == "inspect":
        return inspect()
    if args.command == "apply":
        return apply(args.update_endpoint, args.new_update_endpoint, args.skip_host_update, args.wrapper_proxy, args.version)
    return restore()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Adım 2: ONAY al, ardından profili salt okunur incele (sandbox dışında)**

Kullanıcıya sorulacak: "Discord profil klasörünüzden yalnız klasör adlarını, `settings.json` anahtar adlarını ve güncellemeyle ilgili değerleri, çekirdek giriş dosyasını ve `installed.json` dosyasını okuyacağım. Hesap veya oturum verisi okunmaz. Onaylıyor musunuz?"

Run: `python3 -B macos/work/spike/profile_edit.py inspect`
Expected:
- `Sürüm klasörü: <sürüm>` satırında bir sürüm klasörü (beklenen `0.0.397`).
- `modules:` içinde `discord_desktop_core`.
- `core giriş dosyası: "module.exports = require('./core.asar');" | resmi biçim: True` biçiminde bir satır.

Sürüm adını ve sahiplenilen anahtarların özgün durumunu Görev 13 için not edin.

---

### Görev 8: Ana uygulama güncellemesi kararı (ONAY, koşullu)

- [ ] **Adım 1: Görev 6 Adım 4 sonucuna göre dallan**

- `204` ise güncelleme yoktur; bu görev atlanır, Görev 9'da `--skip-host-update` kullanılmaz.
- `200` ise kullanıcıya sorulur: "Discord'un yeni sürümü (`<name>`) var. Deneme sırasında köprü üzerinden indirilip kurulabilir; bu resmi, Discord imzalı güncellemedir ve Discord kendini yeniden başlatır. İzin veriyor musunuz?"
  - **Hayır:** Görev 9 ve 11'de `--skip-host-update` eklenir; bu görev atlanır.
  - **Evet:** Adım 2–5 uygulanır.

- [ ] **Adım 2: Discord'un kapalı olduğunu doğrula**

Run: `pgrep -x Discord || echo kapali`
Expected: `kapali`. Değilse kullanıcıdan Discord'u Cmd+Q ile kapatması istenir.

- [ ] **Adım 3: Güncelleme adreslerini köprüye yönlendir ve Discord'u aç (sandbox dışında)**

```bash
. macos/work/spike/vars.sh
python3 -B macos/work/spike/profile_edit.py apply --update-endpoint "$UPD" --new-update-endpoint "$NEWUPD"
open -a /Applications/Discord.app
```

Expected: `settings.json güncellendi: UPDATE_ENDPOINT, NEW_UPDATE_ENDPOINT`. Discord açılış ekranında güncelleme indirmeye başlar.

- [ ] **Adım 4: Squirrel indirmesini izle**

Monitor ile bekle (en fazla 15 dakika): `until grep -q "download:dl.discordapp.net 200" macos/work/spike/logs/bridge.log; do sleep 5; done`
Ardından Run: `tail -n 20 macos/work/spike/logs/bridge.log`
Expected: `GET legacy 200 json-rewritten` (besleme), ardından `GET download:dl.discordapp.net 200 <büyük bayt sayısı>`. Discord yeniden başlar; yeni sürüm modülleri `GET legacy ...` ve `download:` satırlarıyla iner. Ana pencere proxy'siz olduğu için bağlanmayabilir; bu beklenen durumdur. Kullanıcı Discord'u Cmd+Q ile kapatır.

- [ ] **Adım 5: Yeni sürüm klasörünü doğrula (sandbox dışında)**

Run: `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Discord.app/Contents/Info.plist; python3 -B macos/work/spike/profile_edit.py inspect | grep -E "Sürüm klasörü|core giriş"`
Expected: Yeni sürüm numarası ve onun sürüm klasörü. Görev 9–11'de yeni sürüm adı kullanılır. Sonuç Görev 13'e kaydedilir: güncelleme köprüden geçti mi, modüller yeni sürüm klasörüne mi indi.

---

### Görev 9: Deney A — argümanla açılış (ONAY)

- [ ] **Adım 1: ONAY al ve Discord'un kapalı olduğunu doğrula**

Kullanıcıya sorulacak: "Discord'u deneme proxy'siyle açacağım. `settings.json` içindeki güncelleme adresleri geçici olarak yerel köprüye yönlendirilecek ve deneme sonunda geri alınacak. Onaylıyor musunuz?"

Run: `pgrep -x Discord || echo kapali`
Expected: `kapali`

- [ ] **Adım 2: Önceki kayıtları ayır**

Run: `for f in gate bridge; do test -f macos/work/spike/logs/$f.log && mv macos/work/spike/logs/$f.log macos/work/spike/logs/$f-oncesi-A.log; done; ls macos/work/spike/logs`
Expected: `gate.log` ve `bridge.log` yok; `*-oncesi-A.log` dosyaları var. Düzenek yeni kayıtları yeni dosyalara yazar.

- [ ] **Adım 3: Ayarları uygula ve Discord'u argümanla aç (sandbox dışında)**

Görev 8'de güncelleme reddedildiyse `apply` komutuna `--skip-host-update` eklenir.

```bash
. macos/work/spike/vars.sh
python3 -B macos/work/spike/profile_edit.py apply --update-endpoint "$UPD" --new-update-endpoint "$NEWUPD"
open -a /Applications/Discord.app --args "--proxy-server=$PROXY" "--proxy-bypass-list=127.0.0.1;localhost" --disable-quic
```

Expected: `settings.json güncellendi: ...` ve Discord penceresi açılır.

- [ ] **Adım 4: Kayıtları kontrol et**

Monitor ile bekle (en fazla 3 dakika): `until grep -q "OK CONNECT gateway.discord.gg:443" macos/work/spike/logs/gate.log 2>/dev/null; do sleep 2; done`
Ardından Run: `tail -n 15 macos/work/spike/logs/bridge.log; grep -cE " OK " macos/work/spike/logs/gate.log; grep -E " (OK|REJECT) " macos/work/spike/logs/gate.log | awk '{print $2, $4}' | sort | uniq -c | sort -rn | head -25`
Expected:
- Köprüde açılıştan sonra besleme ve `versions.json` için `GET legacy 204` veya `GET legacy 200 json-rewritten` satırları.
- Kapıda `OK CONNECT discord.com:443`, `OK CONNECT gateway.discord.gg:443`, `cdn.discordapp.com`, `media.discordapp.net` gibi satırlar.
- `REJECT` satırları, izin listesi dışındaki hostların listesidir (Windows'taki davranışla karşılaştırma için Görev 13'e kaydedilir).

- [ ] **Adım 5: Kullanıcı doğrulaması**

Kullanıcıya sorulacak:

- Discord açıldı mı?
- Sunucu listesi ve mesajlar yükleniyor mu?
- Bir mesaj gönderip küçük bir resim yükleyebilir misiniz?
- İsterseniz sesli bir kanala katılıp sesin çalışıp çalışmadığını söyleyin.

Yanıtlar Görev 13'e kaydedilir. Discord açık bırakılır (Görev 10 için).

- [ ] **Adım 6: Discord'un güncelleyici kaydını oku (sandbox dışında)**

Run: `tail -n 40 "$HOME/Library/Application Support/discord/logs/legacyModulesUpdater.log"`
Expected: `Checking for module updates at http://127.0.0.1:<köprü>/<belirteç>/legacy/modules/stable/versions.json` ve hata içermeyen sonuç satırları. `Host update failed` varsa metni Görev 13'e kaydedilir.

---

### Görev 10: Eş kimliği yoklaması (Deney A sürerken)

**Files:**
- Create (Git dışı): `macos/work/spike/peer_probe.swift`

- [ ] **Adım 1: `peer_probe.swift` dosyasını yaz**

```swift
// Aşama 0 deneme aracı: kapıya bağlı istemci soketlerini libproc ile bulur,
// sahibi olan süreci ve Discord Team ID imzasını doğrular. Atılabilir.
// Kullanım: macos/work/spike/peer_probe <kapı-portu>
import Darwin
import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count == 2, let gatePort = UInt16(arguments[1]) else {
    FileHandle.standardError.write(Data("kullanım: peer_probe <kapı-portu>\n".utf8))
    exit(64)
}
let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"53Q6R32WPB\""

func userProcessIDs() -> [pid_t] {
    let uid = getuid()
    let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
    guard needed > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 32)
    let filled = pids.withUnsafeMutableBytes { buffer in
        proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return [] }
    return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
}

func socketDescriptors(_ pid: pid_t) -> [Int32] {
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16)
    let filled = descriptors.withUnsafeMutableBytes { buffer in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return [] }
    return descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
        .map { $0.proc_fd }
}

func networkPort(_ value: Int32) -> UInt16 {
    UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
}

struct Peer {
    let pid: pid_t
    let localPort: UInt16
}

func gateClients(of pid: pid_t) -> [Peer] {
    var peers: [Peer] = []
    for descriptor in socketDescriptors(pid) {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size,
              info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
        let endpoint = info.psi.soi_proto.pri_tcp.tcpsi_ini
        guard endpoint.insi_vflag & UInt8(INI_IPV4) != 0,
              endpoint.insi_faddr.ina_46.i46a_addr4.s_addr == inet_addr("127.0.0.1"),
              networkPort(endpoint.insi_fport) == gatePort else { continue }
        peers.append(Peer(pid: pid, localPort: networkPort(endpoint.insi_lport)))
    }
    return peers
}

func executablePath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : "?"
}

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

func signatureCheck(_ pid: pid_t) -> String {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    var status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard status == errSecSuccess, let code else { return "guest-error \(status)" }
    var requirement: SecRequirement?
    status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
    guard status == errSecSuccess, let requirement else { return "requirement-error \(status)" }
    let validity = SecCodeCheckValidity(code, [], requirement)
    var identifier = "?"
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
       SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
       let dictionary = information as? [String: Any] {
        identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? "?"
    }
    return (validity == errSecSuccess ? "OK" : "FAIL \(validity)") + " identifier=\(identifier)"
}

let started = Date()
let processIDs = userProcessIDs()
var found: [Peer] = []
for pid in processIDs { found += gateClients(of: pid) }
let elapsed = Int(Date().timeIntervalSince(started) * 1000)
print("Taranan süreç: \(processIDs.count), kapıya bağlı istemci soketi: \(found.count), süre: \(elapsed) ms")
for pid in Set(found.map { $0.pid }).sorted() {
    let ports = found.filter { $0.pid == pid }.map { String($0.localPort) }.joined(separator: ",")
    let info = bsdInfo(pid)
    let start = info.map { String($0.pbi_start_tvsec) } ?? "?"
    let parent = info.map { String($0.pbi_ppid) } ?? "?"
    print("pid=\(pid) ppid=\(parent) start=\(start) yerel-portlar=\(ports)")
    print("  yol=\(executablePath(pid))")
    print("  imza=\(signatureCheck(pid))")
}
```

- [ ] **Adım 2: Derle**

Run: `swiftc -O -module-cache-path macos/work/spike/.module-cache -o macos/work/spike/peer_probe macos/work/spike/peer_probe.swift`
Expected: Çıktısız başarı.

- [ ] **Adım 3: Discord bağlıyken çalıştır**

Run: `. macos/work/spike/vars.sh; macos/work/spike/peer_probe "$GATE"`
Expected:
- `kapıya bağlı istemci soketi: <1 veya daha fazla>`.
- `Discord Helper` yolu, `/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/...`.
- `imza=OK identifier=com.hnc.Discord.helper` (veya `com.hnc.Discord` ile başlayan bir tanımlayıcı).
- Tarama süresi birkaç milisaniye.

Sandbox engeli çıkarsa sandbox dışında yeniden çalıştırılır. Sonuç Görev 13'e kaydedilir. Yoklama tamamlanınca kullanıcı Discord'u Cmd+Q ile kapatır.

---

### Görev 11: Deney B — Dock'tan açılış ve çalışma anı proxy'si (ONAY)

- [ ] **Adım 1: ONAY al ve Discord'un kapalı olduğunu doğrula**

Kullanıcıya sorulacak: "Discord'un çekirdek giriş dosyasına geçici bir deneme sarmalayıcısı yazacağım (yedekli) ve Discord'u argümansız, Dock'tan açılır gibi açacağım. Deneme sonunda özgün dosya geri yüklenecek. Onaylıyor musunuz?"

Run: `pgrep -x Discord || echo kapali`
Expected: `kapali`

- [ ] **Adım 2: Önceki kayıtları ayır**

Run: `for f in gate bridge; do test -f macos/work/spike/logs/$f.log && mv macos/work/spike/logs/$f.log macos/work/spike/logs/$f-deney-A.log; done; ls macos/work/spike/logs`
Expected: `gate.log` ve `bridge.log` yok; `*-deney-A.log` dosyaları var.

- [ ] **Adım 3: Sarmalayıcıyı uygula (sandbox dışında)**

Sürüm `Info.plist`'ten okunur. Legacy güncelleyicide modül klasörü ana uygulama sürümüyle adlandırılır; Görev 7 veya 8'deki inceleme bu klasörün varlığını gösterir. Görev 8'de güncelleme reddedildiyse `apply` komutuna `--skip-host-update` eklenir.

```bash
. macos/work/spike/vars.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Discord.app/Contents/Info.plist)
python3 -B macos/work/spike/profile_edit.py apply --update-endpoint "$UPD" --new-update-endpoint "$NEWUPD" --wrapper-proxy "$PROXY" --version "$VERSION"
```

Expected: `settings.json güncellendi: ...` ve `Çekirdek giriş dosyasına deneme sarmalayıcısı yazıldı: .../<sürüm>/modules/discord_desktop_core/index.js`

- [ ] **Adım 4: Discord'u argümansız aç (sandbox dışında)**

Run: `open -a /Applications/Discord.app`
Expected: Discord açılır.

- [ ] **Adım 5: Sarmalayıcı ve kapı kayıtlarını kontrol et (sandbox dışında)**

Monitor ile bekle (en fazla 3 dakika): `until grep -qE "setProxy (applied|failed)" "$HOME/Library/Application Support/DiscordAccess-spike/wrapper.log" 2>/dev/null; do sleep 2; done`
Ardından Run: `cat "$HOME/Library/Application Support/DiscordAccess-spike/wrapper.log"; tail -n 20 macos/work/spike/logs/gate.log`
Expected:
- `wrapper loaded; proxy switch absent`
- `loadURL waits for proxy: discord.com`
- `setProxy applied; resolveProxy=PROXY 127.0.0.1:<kapı>`
- Kapı kaydında açılış saatinden sonra `OK CONNECT discord.com:443` ve `OK CONNECT gateway.discord.gg:443` satırları.

- [ ] **Adım 6: Kullanıcı doğrulaması ve gerçek Dock tıklaması**

Kullanıcıya sorulacak:

- Discord açıldı mı, sunucular ve mesajlar yükleniyor mu, mesaj gönderilebiliyor mu?
- Ardından Discord'u Cmd+Q ile kapatıp Dock'taki Discord simgesine tıklayarak yeniden açar mısınız? Aynı şekilde bağlanıyor mu?

Dock tıklamasından sonra `wrapper.log` dosyasına yeni üç satır eklenmiş olmalıdır. Yanıtlar Görev 13'e kaydedilir. Kullanıcı Discord'u kapatır.

---

### Görev 12: Geri alma ve düzeneği durdurma (ONAY)

- [ ] **Adım 1: Discord'un kapalı olduğunu doğrula**

Run: `pgrep -x Discord || echo kapali`
Expected: `kapali`

- [ ] **Adım 2: Profil değişikliklerini geri al (sandbox dışında)**

Run: `python3 -B macos/work/spike/profile_edit.py restore`
Expected: `settings.json sahiplenilen anahtarları özgün değerlerine döndü.` ve (Görev 11 yapıldıysa) `Çekirdek giriş dosyası özgün haline döndü.`

- [ ] **Adım 3: Özgün duruma dönüldüğünü doğrula (sandbox dışında)**

Run: `python3 -B macos/work/spike/profile_edit.py inspect | grep -E "UPDATE_ENDPOINT|SKIP_HOST_UPDATE|core giriş"`
Expected: Sahiplenilen anahtarlar Görev 7'de not edilen özgün durumdadır (çoğunlukla `<yok>`). Çekirdek giriş satırında `resmi biçim: True` yazar.

- [ ] **Adım 4: Düzeneği durdur ve motorun kalmadığını doğrula**

Run: `pkill -TERM -f 'macos/work/spike/spike.py'`
Monitor ile bekle (en fazla 30 saniye): `until ! pgrep -f 'macos/build/engine/sing-box' >/dev/null; do sleep 1; done`
Ardından Run: `pgrep -fl 'macos/build/engine/sing-box' || echo "motor kapali"; ls macos/work/spike/state.json macos/work/spike/vars.sh 2>/dev/null || echo "durum dosyalari silindi"`
Expected: `motor kapali` ve `durum dosyalari silindi`.

- [ ] **Adım 5: Deneme yedeklerinin silinmesi (ONAY, isteğe bağlı)**

Görev 13'teki kayıt tamamlandıktan sonra kullanıcıya sorulur: "`~/Library/Application Support/DiscordAccess-spike` klasörü (profil yedekleri ve sarmalayıcı kaydı) silinsin mi?" Onay verilirse:

```bash
ls -la "$HOME/Library/Application Support/DiscordAccess-spike" "$HOME/Library/Application Support/DiscordAccess-spike/backup"
rm -rf "$HOME/Library/Application Support/DiscordAccess-spike"
```

---

### Görev 13: Sonuçları tasarım belgesine işle

**Files:**
- Modify: `macos/docs/2026-10-14-macos-tasarim.md` (Bölüm 3'ün sonuna yeni alt bölüm; Bölüm 7.2 ve 12'deki kararlar)

- [ ] **Adım 1: Bölüm 3'ün sonuna "Aşama 0 sonuçları" alt bölümünü ekle**

Aşağıdaki tablo, Görev 4–12'de gözlenen gerçek değerlerle doldurulur. Gözlenmeyen satıra "yapılmadı" yazılır; yapılmamış kontrol başarılı gösterilmez.

```markdown
### Aşama 0 sonuçları (YYYY-AA-GG, Discord <sürüm>)

| Kontrol | Sonuç | Kanıt |
| --- | --- | --- |
| Motor derlemesi (darwin/arm64) | SHA-256 `<64 hane>`, cdhash `<40 hane>`, imza adhoc | `macos/work/engine-build-*/artifacts/build-metadata.json` |
| Tekrarlanabilirlik | İki bağımsız derleme aynı / farklı | Görev 4 Adım 3 çıktısı |
| Yamaların Go testleri | 3 paket ok / başarısız paket adı | `source-unit-tests.txt` |
| 6 DNS yapılandırması | 6/6 PASS / başarısız varyant | Görev 5 Adım 2 |
| Kapı üzerinden API | `/api/v10/gateway` yanıtı | Görev 6 Adım 2 |
| Squirrel beslemesi köprüden | 204 / 200 (sürüm) | Görev 6 Adım 4 |
| Modül listesi köprüden | 200, modül sayısı | Görev 6 Adım 5 |
| Ana uygulama güncellemesi köprüden | indirildi ve kuruldu / reddedildi / gerekmedi | Görev 8 |
| Profil yapısı | `<veri klasörü>/<sürüm>/modules/discord_desktop_core/index.js`, resmi giriş biçimi | Görev 7 |
| Deney A (argümanla açılış) | mesaj / yükleme / ses sonuçları | Görev 9 |
| Kapının reddettiği hostlar | liste | `gate.log` REJECT satırları |
| Eş kimliği (libproc + Team ID) | süreç adı, tanımlayıcı, tarama süresi | Görev 10 |
| Deney B (Dock + sarmalayıcı) | `open -a` ve gerçek Dock tıklaması sonuçları | Görev 11 |
| Geri alma | özgün değerler ve resmi giriş biçimi geri geldi | Görev 12 |
```

- [ ] **Adım 2: Kararları işle**

- Bölüm 7.2 ("Proxy'nin uygulanması"):
  - Deney B başarılıysa "Aşama 0'da doğrulandı" notu eklenir.
  - Başarısızsa yöntem Bölüm 12'deki yedek plana (menü + Dock başlatıcısı) çevrilir.
- Bölüm 12 risk tablosunda ilgili satırların "Doğrulama" sütununa sonuç yazılır:
  - çalışma anı proxy'si
  - Squirrel.Mac
- Aşama 1 için motor pini notu eklenir: `ENGINE_SHA256` olarak Görev 4'teki değer, ancak yalnız tekrarlanabilirlik doğrulandıysa.

- [ ] **Adım 3: Son kontrol noktası**

Run: `git diff --name-only main; git status --porcelain --untracked-files=all`
Expected:
- `git diff` boş.
- Durumda yalnız şu dosyalar:
  - `macos/.gitignore`
  - `macos/docs/2026-10-14-macos-tasarim.md`
  - `macos/docs/plans/2026-10-14-asama-0-fizibilite.md`
  - `macos/scripts/build-engine.py`
  - `macos/tests/build-engine.test.py`
- `macos/work/` ve `macos/build/` görünmez.

- [ ] **Adım 4: Teslim ve commit sorusu**

Kullanıcıya şunlar raporlanır:

- değişen dosyalar ve Git durumu
- yapılan kontroller ve sonuçları
- yapılmayan kontroller

Ardından commit isteyip istemediği sorulur. İsterse:

```bash
git add macos/.gitignore macos/docs macos/scripts/build-engine.py macos/tests/build-engine.test.py
git commit -m "docs: record macOS feasibility results and pinned engine builder"
```

---

## Uygulama notları (2026-10-14)

Plan yürütülürken yapılan ve yukarıdaki adımlardan farklı olan noktalar aşağıdadır. Sonuçların tamamı tasarım belgesinin Bölüm 3'ündedir.

**Deneme araçlarının güvenlik incelemesi.** Görev 7'den önce `spike.py`, `profile_edit.py` ve `peer_probe.swift` incelendi. Bulunan sorunlar ve düzeltmeleri:

- **C1 (kritik):** `apply`, özgün değerleri kaydetmeden önce `settings.json` dosyasını değiştiriyordu. Düzeltilmiş akış: doğrulama → yedek ve durum kaydı → dosya değişikliği.
- **I1:** Uç noktalar doğrulanmıyordu. Artık uç nokta biçimi doğrulanıyor ve dinleyicilerin açık olduğu denetleniyor.
- **I2:** Sarmalayıcıya `,direct://` yedeği eklendi.
- **I3:** Kapıya Windows `RewriteHeader` kurallarının birebir karşılığı eklendi.
- **I4:** Köprüde `#` ve `?` ile host denetimini atlatma kapatıldı.
- **I5:** Sinyaller kurulumun başında yakalanıyor.
- **I6:** Yarım gövdeye hata sayfası eklenmesi önlendi.

Düzeltmeler `macos/work/spike/test_spike_tools.py` ile sınandı: Windows fixture örnekleri, profil senaryoları ve sahte Electron. Test sonuçları:

- Eski araçlarda 13 hata ve 73 istisna.
- Düzeltilmiş araçlarda testlerin tamamı geçti (son durum 21 test).

Kurulumdan sonra incelemeci her bulguyu "çözüldü" olarak onayladı. Plandaki Görev 5 ve 7 kod blokları ilk sürümdür; kullanılan sürümler şunlardır:

| Dosya | SHA-256 |
| --- | --- |
| `spike.py` | `19d9f312…6193` |
| `profile_edit.py` | `8dd95473…13f2` |
| `test_spike_tools.py` | `772e1873…a9d7` |

**Yeni güncelleyici düzeni.** Gerçek profilde `USE_NEW_UPDATER = true` çıktı. Çekirdek dosyası `app-<sürüm>/modules/discord_desktop_core-<N>/discord_desktop_core/index.js` yolunda; bu, Windows'taki düzenin aynısı. `profile_edit.py` bu düzene uyarlandı (en yüksek `N` seçilir) ve incelemeden geçti.

**Discord veri klasörüne erişim (TCC).** macOS, `~/Library/Application Support/discord` klasörünü Claude'a da, Terminal'e de kapattı (`kTCCServiceSystemPolicyAppDataDetailed`, izin penceresi yok). Profile dokunan komutlar, kullanıcının Tam Disk Erişimi verdiği Terminal.app'te çalıştırıldı:

- Kullanılan araç: `macos/work/spike/profile.sh` (`inspect`, `layout`, `apply-settings`, `apply-wrapper`, `restore`, `updater-log`, `wrapper-log`).
- Her komutun çıktısı `macos/work/spike/terminal-<komut>.txt` dosyasına da yazıldı.

**Beklenen kayıt biçimi.** Sarmalayıcı kaydı `resolveProxy=PROXY 127.0.0.1:<kapı>;DIRECT` biçimindedir. Kapı reddi `REJECT <hedef> <kategori>` biçiminde kaydedilir.

**Kapsam dışı bırakılanlar.** Ek dosyası kancası denemeye eklenmedi; kullanıcı kararıyla Aşama 1'de, gerçek kurulum biçimiyle doğrulanacak. Deney A'da Discord içinden ek dosyası indirme tarayıcıya yönlendi; bu beklenen bir davranıştı.

**Kalan adım.** Kullanıcıdan istenen tek iş: deneme bitince Terminal'in Tam Disk Erişimi izninin kapatılması.

**Sonradan taşınan dosya (Aşama 1a).** `macos/tests/build-engine.test.py`, içeriği değişmeden `macos/Tests/build-engine.test.py` yoluna taşındı. Bu planda geçen eski yol tarihsel kayıttır. Sebep: macOS'un varsayılan diski büyük/küçük harf ayırmadığı için `tests/` ile SwiftPM'in `Tests/` klasörü aynı klasör oluyordu. Bütün macOS testleri artık `macos/Tests/` altında.
