import DemoContent
import Foundation

let usage = """
    Usage: voxcarrel-demo inbox <folder>     loose sample files, ready to import
           voxcarrel-demo library <folder>   a library with the sample books imported
    The folder must be new or empty.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let command = arguments.first, let path = arguments.last else {
    fail(usage)
}
let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)

do {
    switch command {
    case "inbox":
        let items = try DemoContent.makeInbox(at: folder)
        print("Made a demo inbox with \(items.count) items at \(folder.path)")
    case "library":
        try DemoContent.makeLibrary(at: folder)
        print("Made a demo library at \(folder.path)")
    default:
        fail(usage)
    }
} catch {
    fail("voxcarrel-demo: \(error)")
}
