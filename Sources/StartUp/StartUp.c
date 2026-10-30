#include <signal.h>
#include <stdio.h>
#include "StartUp.h"

void mulligan_start_up(void) {
	setvbuf(stdout, NULL, _IOLBF, 0);
	sigset_t none;
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
}
