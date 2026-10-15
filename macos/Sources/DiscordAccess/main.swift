import DiscordAccessKit
import Foundation

/// The engine and the attachment download hook: in the app bundle (`Contents/Helpers`, `Contents/Resources`), or in this
/// source tree for a development build. Both are verified against their pinned digests before use, wherever they are.
let resources: (engine: String, hook: String) = {
    let bundle = Bundle.main.bundleURL
    if bundle.pathExtension == "app" {
        return (bundle.appendingPathComponent("Contents/Helpers/sing-box").path, bundle.appendingPathComponent("Contents/Resources/attachment-download.cjs").path)
    }
    let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (macos.appendingPathComponent("build/engine/sing-box").path,
            macos.deletingLastPathComponent().appendingPathComponent("bridge/attachment-download.cjs").path)
}()

exit(ConsoleProgram.run(arguments: Array(CommandLine.arguments.dropFirst()), engine: resources.engine, hook: resources.hook) { options in
    MenuBarApp.run(options: options, engine: resources.engine, hook: resources.hook)
})
