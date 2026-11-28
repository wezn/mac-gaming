import ArgumentParser
import Foundation
import MGCore

struct Licenses: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the third-party notices: the licenses of the software mgx, the app and the runtimes ship.",
        discussion: """
        Prints THIRD_PARTY_NOTICES.md, which ships next to mgx in the release tarball (and in
        MacGaming.app/Contents/Resources). Exits 1, naming the online copy, if the file is missing.
        """)
    @Flag(help: "Print the file's path instead of its contents.") var path = false

    func run() throws {
        guard let url = ThirdPartyNotices.locate(executable: ThirdPartyNotices.currentExecutable) else {
            Context.note("error: \(ThirdPartyNotices.fileName) is not installed next to mgx. Read it at \(ThirdPartyNotices.onlineURL())")
            throw ExitCode.failure
        }
        if path { print(url.path); return }
        do {
            FileHandle.standardOutput.write(try Data(contentsOf: url))
        } catch {
            Context.note("error: cannot read \(url.path): \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
