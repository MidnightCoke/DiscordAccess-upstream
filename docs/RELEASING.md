# Preparing a release

These steps are for the maintainer. GitHub Actions is not used; adding a document or a JSON settings file to the repository does not mean that tests or GitHub protections are active. Do not rewrite old commits or release tags to tidy up the history.

## Source, licenses and verification

1. Update the version together in the README, usage notes, changelog, app metadata and build message. Do not present a change that alters the official Discord/profile/network flow as merely a version or distribution fix.
2. Run the C#, Node and shortcut checks in [CONTRIBUTING.md](../CONTRIBUTING.md) in an approved Windows environment. Use `-RunSourceTests` for the engine and the explicit `-RunChecks` option for the configuration. A blocked or skipped group has not passed; do not lower Windows security settings or use a different loading method.
3. Refresh the inventory of the distributed engine's actual Go modules, wrapper/native sources and licenses. For example, with the pinned engine hash:

```powershell
python scripts/Collect-EngineNotices.py --engine engine/sing-box.exe --expected-sha256 8bb84e511d9c4dd86e7685c9654d25248b7ff23ea0226fc52a64f9a4066587a0
```

This hash is for `1.14.3-discordaccess.2`; if the engine changes, the script, the app pins and the manifest must change together. Do not treat the Go module's top-level license alone as sufficient for native sources. Do not publish a package with missing or unverified sources/licenses.

4. Commit the final source changes; record the exact commit for packaging. Build a new `DiscordAccess.exe` with `Build.cmd` from the final build inputs. In the verification note, record the checked commit, commands, results and any groups that did not run. List the real-account, voice/streaming, tray and Windows restart checks separately.

## Preparing the four release files

Python 3.11 or later is required. In the example below, take `ENGINE_BUILD_COMMIT` and the evidence folder (`BUILD_ID`) from the actual successful manual engine build. The source/release commit is the final HEAD; the engine evidence commit may be an earlier verified commit if the script, lock and source bytes have not changed. The packager checks this distinction; an old record does not count as a passing test of changed code.

```powershell
$releaseCommit = (git rev-parse HEAD).Trim()
$engineBuildCommit = 'ENGINE_BUILD_COMMIT'
$buildEvidence = 'work/security-engine-build-BUILD_ID/artifacts'
$verifiedCache = 'work/license-source-cache'
$prepareRoot = Join-Path 'work' ('release-v4.22-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $prepareRoot | Out-Null
$sourceZip = Join-Path $prepareRoot 'DiscordAccess-v4.22-engine-source.zip'
$assets = Join-Path $prepareRoot 'assets'
$receipt = Join-Path $prepareRoot 'release-validation-local.json'

python scripts/Package-EngineSource.py --repo . --version 4.22 --commit $releaseCommit --build-evidence $buildEvidence --evidence-commit $engineBuildCommit --cache-dir $verifiedCache --output $sourceZip
python scripts/Package-Release.py --repo . --version 4.22 --commit $releaseCommit --engine engine/sing-box.exe --source $sourceZip --build-evidence $buildEvidence --output-dir $assets --receipt $receipt
```

If archives must be taken from a previously verified source package, `--source-companion PREVIOUS_SOURCE_ZIP` can be added to the first command. This does not replace current evidence of a successful manual build. Native archives must also be present under the cache names and hashes the collector expects.

Re-verify the prepared files with the same inputs:

```powershell
python scripts/Package-EngineSource.py --repo . --version 4.22 --commit $releaseCommit --build-evidence $buildEvidence --evidence-commit $engineBuildCommit --cache-dir $verifiedCache --output $sourceZip --validate-only
python scripts/Package-Release.py --repo . --version 4.22 --commit $releaseCommit --engine engine/sing-box.exe --source $sourceZip --build-evidence $buildEvidence --output-dir $assets --receipt $receipt --validate-only
```

If `--source-companion` was used in the initial preparation, add the same input to the source validation command. Both commands check that the existing outputs match the expected bytes and do not modify files. Record the `existing_output_verified: true` result together with a zero exit code. If the output path does not exist yet, `--validate-only` only computes the expected hashes; this does not mean the prepared release files were verified. The packagers use the already-built `DiscordAccess.exe` as it is; they do not run the engine or the app.

Only these four files are attached to the Release:

- `DiscordAccess-v4.22.zip`
- `DiscordAccess-v4.22-engine-source.zip`
- `engine-source-manifest.json`
- `SHA256SUMS.txt`

The local `$receipt`, test reports, raw logs and the cache folder are not release files. The receipt may contain machine paths; do not share it as is. The runtime ZIP must not contain test, profile or recovery data; `LISANSLAR.txt` must keep the app, engine, native and dependency notices. A ZIP/hash check is not a code signature.

## GitHub release and old downloads

With the four verified files, prepare a draft Release whose target is the exact source commit. The release notes must state the scope of the version, upgrade steps, the engine pin, the completed verification and the remaining live tests. Do not move an existing tag; use a new version tag. After the file names and hashes are checked, publish the draft and mark it as the latest release.

Withdraw old ready-made binary downloads with incomplete license/source notices, or correct them with complete and verified distribution materials. The v4.16–v4.20 tags and source history are kept; the existence of an old tag does not mean that binary package is supported. For past security boundaries or installation instructions, rely on the current README/SECURITY policy.

Remove finished topic branches only after their changes are verified in `main` and no open work or PR remains. With squash/cherry-pick history, do not rely only on `git branch --merged`; review the PR state and change equivalence. Do not delete release tags or rewrite history with force-push.

## Protections to enable after the repository becomes public

Making the repository public is a separate maintainer decision; this checklist by itself does not change its visibility. A settings file in the repository does not mean a protection is active; only the remote setting read back from GitHub counts.

Once the repository is public:

1. Enable **Private vulnerability reporting**; verify that the [private report path](https://github.com/alpertknn/DiscordAccess/security/advisories/new) and the Report a vulnerability button work. `SECURITY.md` must not present a channel that is not active.
2. Apply the `.github/main-protection.json` policy to GitHub and read back the result from the server:

```powershell
gh api --method PUT repos/alpertknn/DiscordAccess/branches/main/protection --input .github/main-protection.json
gh api repos/alpertknn/DiscordAccess/branches/main/protection
```

The file is only a declaration of intent; a successful API response and the remote setting read back are the proof of protection. The policy must require a PR, approval from at least one other accepted reviewer, enforcement for admins, resolved conversations, and blocking of force-pushes and branch deletion. You cannot meet this requirement by approving your own PR. Because GitHub Actions is disabled, do not make nonexistent Actions checks required status checks.

3. Check the repository About/topics, the latest Release, the four download files, the source/license links and the issue forms in the public view. The automatic merged-branch deletion setting does not delete history or release tags.

Do not report an API rejection or a missing check as a success. If remote settings cannot be applied yet, record which step is pending in a maintenance record separate from the release notes.
