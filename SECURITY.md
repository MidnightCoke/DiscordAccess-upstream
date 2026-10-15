# Security policy

## Supported versions

Security fixes are considered for the latest published release. For Windows, that is v4.22; earlier versions no longer receive new fixes. For macOS, the latest release is the `macos-v0.2` pre-release. Old tags preserve source history and are not a recommendation for a safe or current binary download.

For normal usage problems, use the [Issues](https://github.com/alpertknn/DiscordAccess/issues) templates. Do not share details of a security vulnerability in a public issue, PR, comment or log attachment.

## Reporting a vulnerability privately

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**, or go directly to:

[Report a vulnerability](https://github.com/alpertknn/DiscordAccess/security/advisories/new)

The report is visible only to you and the repository maintainers. Do not post sensitive details publicly, including in issues, pull requests or discussions. If the **Report a vulnerability** button is not available, open an issue that only asks for a private contact channel, without any vulnerability details.

Include only the information that is needed:

- The affected version/commit and your Windows or macOS version.
- The expected trust boundary, the observed behavior and its impact.
- Short reproduction steps using synthetic data.
- If available, a suggested fix or test with personal data removed.

Do not send Discord tokens, passwords, profiles, `journal.json`, `.preserved` backups, full user paths, IP addresses or signed attachment URLs. Do not run tests that harm a real account, someone else's data or a system. Reviews are volunteer maintainer work; no fixed response or fix time and no bounty program are promised.

The technical scope and known limits are in [SECURITY-NOTES.md](docs/SECURITY-NOTES.md) (Windows) and [macos/docs/SECURITY-NOTES.md](macos/docs/SECURITY-NOTES.md) (macOS). The project is not an official Discord product; it is unsigned and does not bypass Windows or macOS security controls.
