import DiscordAccessKit
import Foundation

/// The engine and the attachment download hook: in the app bundle's resources, or in this source tree for a development
/// build. Both are verified against their pinned digests before use, wherever they are found.
let resources: (engine: String, hook: String) = {
    if Bundle.main.bundleURL.pathExtension == "app", let folder = Bundle.main.resourceURL {
        return (folder.appendingPathComponent("sing-box").path, folder.appendingPathComponent("attachment-download.cjs").path)
    }
    let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (macos.appendingPathComponent("build/engine/sing-box").path,
            macos.deletingLastPathComponent().appendingPathComponent("bridge/attachment-download.cjs").path)
}()

exit(ConsoleProgram.run(arguments: Array(CommandLine.arguments.dropFirst()), engine: resources.engine, hook: resources.hook))
