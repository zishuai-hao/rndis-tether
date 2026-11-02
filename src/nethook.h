/* An optional root-owned executable for network policy; never blocks USB I/O. */
#ifndef NETHOOK_H
#define NETHOOK_H

#include <stdbool.h>

/* Main run loop only. Empty path disables hooks. Each invocation gets host as argv[1]. */
bool nethook_start(const char *path, const char *host);
void nethook_notify(void);
void nethook_stop(void);

#endif
