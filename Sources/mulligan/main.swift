import Foundation
import LineBuffer
import UndoCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

mulligan_line_buffer_stdout()
signal(SIGPIPE, SIG_IGN)
let status = CLI(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment).run()
exit(status)
