#include "nethook.h"
#include "clock.h"
#include "log.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <net/if.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef NETHOOK_TIMEOUT_MS
#define NETHOOK_TIMEOUT_MS 30000u
#endif
#define NETHOOK_DEBOUNCE_S 0.3
#define NETHOOK_REFRESH_S 300.0

/* Only the main run loop touches this state. A child, not another thread, performs
 * optional policy work. Duplicate events coalesce into at most one following run. */
static struct {
    bool enabled, pending, refresh_due;
    char path[PATH_MAX], host[IFNAMSIZ];
    pid_t pid;
    uint64_t deadline;
    CFRunLoopTimerRef debounce, child, refresh;
} hook;

/* Resolve symlinks, then check the executable AND every canonical parent. Root must
 * not execute a file that a user can replace by renaming its writable parent. */
static bool trusted_path(const char *path, char out[PATH_MAX]) {
    if (!realpath(path, out)) return false;
    char current[PATH_MAX];
    strlcpy(current, out, sizeof current);
    bool file = true;
    for (;;) {
        struct stat st;
        if (lstat(current, &st) || st.st_uid != 0 || (st.st_mode & 0022) ||
            (file ? !S_ISREG(st.st_mode) || !(st.st_mode & 0111) : !S_ISDIR(st.st_mode))) return false;
        if (!strcmp(current, "/")) return true;
        char *slash = strrchr(current, '/');
        if (!slash) return false;
        if (slash == current) current[1] = 0;
        else *slash = 0;
        file = false;
    }
}

static void reap(void) {
    int status;
    /* The child has its own process group: timeout/stop also ends its subprocesses. */
    (void)kill(-hook.pid, SIGKILL);
    while (waitpid(hook.pid, &status, 0) < 0 && errno == EINTR) {}
    hook.pid = 0;
}

static void child_changed(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    if (!hook.pid) return;
    int status = 0;
    pid_t done = waitpid(hook.pid, &status, WNOHANG);
    if (done < 0 && errno == EINTR) { timer_set(hook.child, 0.05); return; }
    if (!done && now_ms() < hook.deadline) { timer_set(hook.child, 0.05); return; }
    if (!done) {
        logmsg("network hook timed out; stopping its process group");
        reap();
    } else {
        if (done > 0 && (!WIFEXITED(status) || WEXITSTATUS(status)))
            logmsg("network hook did not complete successfully");
        hook.pid = 0;
    }
    if (hook.enabled && hook.pending) timer_set(hook.debounce, NETHOOK_DEBOUNCE_S);
}

static void invoke(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    if (!hook.enabled || hook.pid) return;
    hook.pending = false;
    char executable[PATH_MAX];
    if (!trusted_path(hook.path, executable)) {
        logmsg("network hook skipped: executable and parent directories must be root-owned and not group/world-writable");
        return;
    }
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&actions);
    sigset_t all, none;
    sigfillset(&all); sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF |
                                  POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addinherit_np(&actions, 2);
    char *const argv[] = {executable, hook.host, NULL};
    char *const environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C",
        hook.refresh_due ? "RNDIS_TETHER_EVENT=refresh" : "RNDIS_TETHER_EVENT=network-change", NULL};
    pid_t pid = 0;
    int error = posix_spawn(&pid, executable, &actions, &attr, argv, environment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (error) { logmsg("cannot start network hook: %s", strerror(error)); return; }
    hook.refresh_due = false;
    hook.pid = pid;
    hook.deadline = now_ms() + NETHOOK_TIMEOUT_MS;
    timer_set(hook.child, 0.05);
}

void nethook_notify(void) {
    if (!hook.enabled) return;
    hook.pending = true;
    timer_set(hook.debounce, NETHOOK_DEBOUNCE_S);
}

static void refresh(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    hook.refresh_due = true;
    nethook_notify(); /* A slow refresh also lets a policy observe DNS TTL changes. */
}

bool nethook_start(const char *path, const char *host) {
    nethook_stop();
    if (!path[0]) return true;
    if (!trusted_path(path, hook.path) || strlcpy(hook.host, host, sizeof hook.host) >= sizeof hook.host) return false;
    if (!hook.debounce) hook.debounce = timer_new(invoke, NULL, 0, 0.1);
    if (!hook.child) hook.child = timer_new(child_changed, NULL, 0, 0.01);
    if (!hook.refresh) hook.refresh = timer_new(refresh, NULL, NETHOOK_REFRESH_S, 5);
    if (!hook.debounce || !hook.child || !hook.refresh) return false;
    hook.enabled = true;
    timer_set(hook.refresh, NETHOOK_REFRESH_S);
    nethook_notify();
    return true;
}

void nethook_stop(void) {
    hook.enabled = hook.pending = hook.refresh_due = false;
    if (hook.debounce) timer_disarm(hook.debounce);
    if (hook.child) timer_disarm(hook.child);
    if (hook.refresh) timer_disarm(hook.refresh);
    if (hook.pid) reap();
}
