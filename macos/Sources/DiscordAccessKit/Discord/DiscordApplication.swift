/// The executables of a Discord.app that may use the gate. Each one is bound to its own signing identifier and to
/// Discord's Developer ID, as in the designated requirements of Discord 0.0.415.
public enum DiscordApplication {
    public static let teamIdentifier = "53Q6R32WPB"
    static let executables = [
        (path: "Contents/MacOS/Discord", identifier: "com.hnc.Discord"),
        (path: "Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper", identifier: "com.hnc.Discord.helper"),
        (path: "Contents/Frameworks/Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)", identifier: "com.hnc.Discord.helper.GPU"),
        (path: "Contents/Frameworks/Discord Helper (Plugin).app/Contents/MacOS/Discord Helper (Plugin)", identifier: "com.hnc.Discord.helper.Plugin"),
        (path: "Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
         identifier: "com.hnc.Discord.helper.Renderer"),
    ]

    /// Discord's designated requirement for one of its signing identifiers.
    public static func requirement(identifier: String) -> String {
        "identifier \"" + identifier + "\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists" +
            " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"" + teamIdentifier + "\""
    }

    /// The approved executables inside `bundle`, the real path of the selected Discord.app.
    public static func approvedExecutables(bundle: String) -> [ApprovedExecutable] {
        executables.map { ApprovedExecutable(path: bundle + "/" + $0.path, requirement: requirement(identifier: $0.identifier)) }
    }
}
