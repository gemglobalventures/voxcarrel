import DemoContent
import Foundation

let usage = """
    Usage: voxcarrel-demo inbox <folder>                loose sample files, ready to import
           voxcarrel-demo library <folder>              a library with the sample books imported
           voxcarrel-demo library <folder> --count N    the same, filled up to N books with
                                                        numbered copies of the sample books
    The folder must be new or empty.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 || arguments.count == 4 else { fail(usage) }
let command = arguments[0]
let path = arguments[1]
var count = 0
if arguments.count == 4 {
    guard command == "library", arguments[2] == "--count", let number = Int(arguments[3]), number > 0 else {
        fail(usage)
    }
    count = number
}
let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)

do {
    switch command {
    case "inbox":
        let items = try DemoContent.makeInbox(at: folder)
        print("Made a demo inbox with \(items.count) items at \(folder.path)")
    case "library":
        try DemoContent.makeLibrary(at: folder, count: count)
        print("Made a demo library at \(folder.path)")
    default:
        fail(usage)
    }
} catch {
    fail("voxcarrel-demo: \(error)")
}
