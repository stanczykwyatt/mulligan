#ifndef MULLIGAN_LINE_BUFFER_H
#define MULLIGAN_LINE_BUFFER_H

/// Makes standard output line buffered even when it's a pipe, so each line shows up as soon as
/// it's printed. In C because Swift 6 won't touch glibc's and musl's mutable `stdout` global.
void mulligan_line_buffer_stdout(void);

#endif
