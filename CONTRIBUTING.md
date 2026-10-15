# Contributing guide

## Building and checks (Windows)

Use .NET Framework 4.8 and Node.js on Windows 10/11 x64. The engine configuration check also needs PowerShell 7 (`pwsh`). The license inventory and release packaging scripts need Python 3.11 or later. In the repository root:

```powershell
powershell -NoProfile -File scripts/Fetch-Engine.ps1
.\Build.cmd
.\Test.cmd
node tests/attachment-download.test.cjs
node tests/external-wrapper.test.cjs
.\tests\shortcuts\Run.cmd
python -B tests/release-packaging.test.py
```

`Test.cmd` generates the synthetic wrapper files under `work/` that the second Node test needs, so keep this order. The shortcut tests use separate, temporary fixture data. Background and startup checks run in the same test runner with fake processes, registry and record data. The checks do not open a real Discord account; network checks use loopback and synthetic responses. Test output and build artifacts stay out of Git.

If Windows blocks a generated test EXE, do not report it as a full test pass. State in the PR which group did not run and which checks remain; do not add code that changes Windows security settings or works around the block.

### Running the Windows tests manually

GitHub Actions has been removed; pushing or opening a PR does not run tests automatically. Complete the build/test sequence above in a development environment where Windows security policy allows the generated test files to run. For a blocked EXE, do not lower security settings or use a different loading method. Do not count a group that did not run as passed.

For the engine source tests, also run:

```powershell
powershell -NoProfile -File scripts/Build-SecurityEngine.ps1 -RunSourceTests
pwsh -NoProfile -File scripts/Test-EngineConfig.ps1 -RunChecks
```

The first command rebuilds the engine from the pinned source/Go/dependency locks and the exact file changes, runs three HTTP/listener unit test groups over synthetic/loopback connections and verifies the resulting hash. The second command tests the six DNS settings of the already prepared pinned engine with the `check` command only; it does not start the engine with `run` and sends no Discord requests. Discord and its profile are not opened. These explicit options do not bypass Windows application control.

`engine-build/go.mod`, `go.sum` and the source changes are pinned byte for byte; `Build-SecurityEngine.ps1` checks file hashes before and after the changes and rejects normal output that differs from the expected engine hash. When updating the engine, first produce a separate review build with `-ReviewCandidate -RunSourceTests` and review the source diff, embedded modules and known vulnerabilities; then change the pins together. The review build cannot be combined with `-OutFile` and is not accepted as a ready-made package.

Keep test reports locally under `work/`; ship the engine's corresponding source and build evidence with the distribution. Earlier Windows test records are evidence for past releases. Report completed checks together with the exact commit that was checked; messaging, downloads, streaming and restart tests with a real account are separate.

## Building and checks (macOS)

The macOS app lives under `macos/`. It needs an Apple Silicon Mac with Xcode (Swift 6 or later) and Python 3. In the repository root:

```bash
python3 macos/scripts/build-engine.py --out macos/build/engine/sing-box
swift test --package-path macos
python3 macos/Tests/build-engine.test.py
macos/scripts/build-app.sh
```

Build the engine first: the Swift tests run the real engine from `macos/build/engine/sing-box`, with sample Discord bundles and profiles and without network access. When Node.js is installed, `swift test` also runs the session wrapper's Node test (`macos/Tests/wrapper.test.cjs`). They never open a real Discord account or touch the real Discord profile. Build and usage details are in [macos/README.md](macos/README.md); the design and its verification records are in [macos/docs/DESIGN.md](macos/docs/DESIGN.md). Keep macOS changes under `macos/`; the shared inputs (`bridge/attachment-download.cjs`, `engine-patches/`, `engine-build/`) and the Windows sources and scripts do not change for a Mac-only change.

## Submitting contributions

If you do not have write access to the repository, fork it on GitHub, clone your fork and add the main repository as `upstream`:

```powershell
git clone https://github.com/USERNAME/DiscordAccess.git
cd DiscordAccess
git remote add upstream https://github.com/alpertknn/DiscordAccess.git
git fetch upstream
git switch -c feature/short-name upstream/main
```

Replace `USERNAME` with your GitHub username, and `feature/short-name` with a short branch name. After you finish the change and the relevant manual checks, push the branch to your fork:

```powershell
git push -u origin feature/short-name
```

On GitHub, open a pull request that targets the `main` branch of the main repository. When you need updates, fetch the latest changes with `git fetch upstream`; do not rewrite someone else's branch or a published release tag.

Team members with write access can create their own work branch from `main`:

```powershell
git switch main
git pull --ff-only
git switch -c feature/short-name
```

In the PR description, include the concrete problem, the new behavior, the exact commit that was checked, the commands used, the results and any test groups that did not run. A blocked or skipped command does not count as a success. Split large edits that change the current working release into small, reviewable changes. Use the issue templates for normal bugs and the [SECURITY.md](SECURITY.md) policy for sensitive security findings.

## Directories and what they own

| Directory/file | Purpose |
| --- | --- |
| `src/` | The C# application; some `TEST_BUILD` checks also live here. |
| `bridge/` | Attachment download support, embedded in the app as a resource. |
| `tests/` | Test runners, JavaScript tests and synthetic shortcut fixtures. |
| `engine-build/` | Byte-for-byte pinned Go dependency locks. |
| `engine-patches/http-limits/` | Hash-verified upstream engine source changes and Go tests. |
| `scripts/` | Engine preparation, configuration checks, license collection and release packaging. |
| `licenses/` | Source/license inventory and original third-party notices. |
| `docs/` | Usage, trust boundaries and [release preparation](docs/RELEASING.md). |
| `macos/` | The native macOS app with its tests, build and release scripts, notices and [documents](macos/docs/DESIGN.md). |
| `work/`, `engine/` | Local evidence and the prepared engine; not added to Git. |

Release tags and the existing commit history preserve the source/build trail. Finished work branches can be removed once their changes are verified in `main`; do not rewrite history or old tags to tidy up the view.

## Behavior that must be preserved

- Keep the official Discord shortcut target and the existing profile; do not use a helper target or a separate copy.
- Do not start Discord automatically on a normal manual launch. At Windows sign-in, open it once after the connection is ready, and only if a preserved auto-start preference exists. Do not kill the normal Discord process on exit.
- Leave a single connection session and a single engine per user. Tray mode must not create an open CMD window, a second helper or a separate Discord copy.
- Coordinate the startup entry only with the personal Run entry of the verified, selected official Discord. Write recovery evidence before changing entries; do not overwrite user changes. Do not change StartupApproved, HKLM or other apps' entries.
- Do not add a global Windows proxy/DNS/routing setting, TUN, a driver or an administrator requirement.
- Limit proxy access to the official Discord executables verified in the current user/session and to the app's own diagnostics/download operations.
- Keep path discovery and shortcut scanning limited. During rollback, do not overwrite files or settings that the user changed.
- Limit download addresses to specific Discord attachment domains; never run downloaded files automatically.

Add meaningful fixtures for changes to connections, path discovery, shortcut arguments, module support or rollback. An anonymous Gateway HELLO check is not a live verification of account sign-in, messaging, files or streaming; report those results separately.

## Data that must not be added to the repository

Do not share tokens, passwords, code signing keys, Discord profiles, session/recovery records, `.lnk` files, real user paths, IP addresses or file download links. Use synthetic data in bug examples. Log folders, the engine EXE, packages and other build output are covered by `.gitignore`.

When changing the engine version, update the download URL, the ZIP/EXE SHA-256 values, the app's dependency verification and the third-party notices together. Derive the real module/version list from the binary's Go build info; verify source archives against the recorded `h1` sums. Include embedded native sources in the inventory as well: a Go module's license may not by itself cover all of the wrapper/DLL licenses inside it. Update the LICENSE/NOTICE/COPYING texts and `licenses/engine-source-manifest.json`; do not guess a license that cannot be found.

DiscordAccess's own app/tool code is MIT, and the engine files derived from upstream are GPL-3.0-or-later; native and other dependencies keep their own licenses. Include all of these notices in the ready-made package's `LICENSES.txt` file. Do not include test or local record files in the production package. Follow the steps in [RELEASING.md](docs/RELEASING.md) for releases.
