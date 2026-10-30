#include <stdio.h>
#include "LineBuffer.h"

void mulligan_line_buffer_stdout(void) {
	setvbuf(stdout, NULL, _IOLBF, 0);
}
