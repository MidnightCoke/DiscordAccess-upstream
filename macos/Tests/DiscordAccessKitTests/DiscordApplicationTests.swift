import Foundation
import Security
import Testing
@testable import DiscordAccessKit

@Suite struct DiscordApplicationTests {
    static let installed = "/Applications/Discord.app"
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installed + "/Contents/MacOS/Discord") }

    /// Discord's designated requirement for the executable, read from its signature without validating it: static
    /// validation registers the stapled notarization ticket with syspolicyd and can wait on it for minutes.
    static func designatedRequirement(_ path: String) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information) == errSecSuccess,
              let designated = (information as? [String: Any])?[kSecCodeInfoDesignatedRequirement as String] else { return nil }
        return text(of: designated as! SecRequirement)
    }

    /// The canonical text of a requirement, as Security.framework prints it.
    static func text(of requirement: SecRequirement) -> String? {
        var text: CFString?
        return SecRequirementCopyString(requirement, [], &text) == errSecSuccess ? text as String? : nil
    }

    static func canonical(_ source: String) -> String? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess, let requirement else { return nil }
        return text(of: requirement)
    }

    @Test func approvesTheMainExecutableAndEveryHelperWithItsOwnIdentifier() {
        let approved = DiscordApplication.approvedExecutables(bundle: "/Applications/Discord.app")
        let frameworks = "/Applications/Discord.app/Contents/Frameworks/"
        #expect(approved.map(\.path) == ["/Applications/Discord.app/Contents/MacOS/Discord",
                                         frameworks + "Discord Helper.app/Contents/MacOS/Discord Helper",
                                         frameworks + "Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)",
                                         frameworks + "Discord Helper (Plugin).app/Contents/MacOS/Discord Helper (Plugin)",
                                         frameworks + "Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"])
        #expect(approved.map { $0.requirement.components(separatedBy: "\"")[1] } ==
            ["com.hnc.Discord", "com.hnc.Discord.helper", "com.hnc.Discord.helper.GPU", "com.hnc.Discord.helper.Plugin", "com.hnc.Discord.helper.Renderer"])
        #expect(approved[0].requirement == "identifier \"com.hnc.Discord\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]" +
            " exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"53Q6R32WPB\"")
    }

    /// Each requirement is the installed Discord's own designated requirement for that executable.
    @Test(.enabled(if: isInstalled)) func requirementsAreTheInstalledDiscordsDesignatedRequirements() {
        for executable in DiscordApplication.approvedExecutables(bundle: Self.installed) {
            let designated = Self.designatedRequirement(executable.path)
            #expect(designated != nil, "\(executable.path)")
            #expect(Self.canonical(executable.requirement) == designated, "\(executable.path)")
        }
    }

    /// The connections of a helper missing from the list would be refused silently at run time, so a helper app that
    /// Discord adds or renames must fail this test instead.
    @Test(.enabled(if: isInstalled)) func approvesEveryExecutableOfTheInstalledApp() throws {
        let files = FileManager.default
        let contents = Self.installed + "/Contents"
        var executables = try files.contentsOfDirectory(atPath: contents + "/MacOS").map { contents + "/MacOS/" + $0 }
        for helper in try files.contentsOfDirectory(atPath: contents + "/Frameworks") where helper.hasSuffix(".app") {
            let folder = contents + "/Frameworks/" + helper + "/Contents/MacOS"
            executables += try files.contentsOfDirectory(atPath: folder).map { folder + "/" + $0 }
        }
        #expect(Set(executables) == Set(DiscordApplication.approvedExecutables(bundle: Self.installed).map(\.path)))
    }
}
