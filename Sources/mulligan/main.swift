import Foundation
import UndoCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let status = CLI(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment).run()
exit(status)
