import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Opening an app through Launch Services, as Discord is opened. The stand-in app is background-only and writes the
/// arguments it got to a file; like the engine copies, it is kept under `build/test-apps` and never deleted (macOS scans
/// newly run files, and its scanner crashed when test files were deleted mid-scan).
@Suite struct LauncherTests {
    /// A background-only app under `build/test-apps` running `script`; made once, never replaced or deleted.
    static func app(named name: String, script: String) throws -> String {
        let app = TestEngine.packageRoot.appendingPathComponent("build/test-apps/" + name + ".app").path
        let executable = app + "/Contents/MacOS/probe"
        if !FileManager.default.fileExists(atPath: executable) {
            try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "com.discordaccess.tests." + name, "CFBundleExecutable": "probe",
                                       "CFBundlePackageType": "APPL", "LSUIElement": true, "LSBackgroundOnly": true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
            let partial = executable + ".partial-" + UUID().uuidString
            try SafeFileTests.write(partial, script, mode: 0o755)
            guard renamex_np(partial, executable, UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else { throw lastPOSIXError() }
        }
        return app
    }

    /// Writes the arguments after the first, then its environment, to the file the first names.
    static func probe() throws -> String {
        try app(named: "launch-probe", script: "#!/bin/sh\nout=\"$1\"\nshift\n{ for argument in \"$@\"; do printf '%s\\n' \"$argument\"; done; env | sort; } > " +
            "\"$out.partial\" && mv \"$out.partial\" \"$out\"\n")
    }

    @Test func stopsAnOpenThatTakesTooLong() throws {
        let sleeper = try Self.app(named: "launch-sleeper", script: "#!/bin/sh\nsleep 3\n")
        let started = Date()
        // A new instance each time: `-W` would otherwise wait only for one an earlier run left sleeping.
        #expect(!Launcher.open(["-n", "-W", "-g", "-a", sleeper], timeout: 0.5))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func opensAnAppWithItsArgumentsAndNoneOfThisProcessesEnvironment() throws {
        let app = try Self.probe()
        let directory = try TemporaryDirectory()
        let out = directory.path + "/arguments.txt"
        setenv("DISCORDACCESS_LAUNCHER_MARKER", "1", 1)
        let arguments = ["--proxy-server=http://127.0.0.1:43210", "--proxy-bypass-list=127.0.0.1;localhost", "--disable-quic"]
        #expect(Launcher.open(["-g", "-a", app, "--args", out] + arguments))
        let written = try #require(waitFor(timeout: 10) { SafeFileTests.text(out) })
        let lines = written.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(3)) == arguments)
        #expect(!written.contains("DISCORDACCESS_LAUNCHER_MARKER"))
        #expect(!Launcher.open(["-g", "-a", directory.path + "/Missing.app"]))
    }
}
