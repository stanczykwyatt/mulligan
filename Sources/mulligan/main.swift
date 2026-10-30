import Foundation
import UndoCore

// Glibc and Musl declare `stdout` as a plain mutable global, which Swift 6 rejects unless the
// module is imported with @preconcurrency. It's only touched here, before anything else runs.
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#endif

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let status = CLI(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment).run()
exit(status)
