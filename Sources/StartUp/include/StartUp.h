#ifndef MULLIGAN_START_UP_H
#define MULLIGAN_START_UP_H

/// Run first thing in main. It's in C because Swift 6 won't touch glibc's and musl's mutable
/// `stdout` global, and because sigemptyset is a macro on some systems.
///
/// - Makes standard output line buffered even when it's a pipe, so each line shows up as soon as
///   it's printed.
/// - Unblocks every signal. A blocked mask is inherited from whatever started mulligan (on Linux,
///   any program started from a thread pool worker), and with it Ctrl-C, TERM and HUP would never
///   reach mulligan's handlers, nor the command `mulligan run` starts, which inherits the mask.
void mulligan_start_up(void);

#endif
