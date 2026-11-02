/* Real child processes over a temporary working directory; no phone or root needed. */
#include "nethook.h"
#include "config.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned checks, failures;
#define CHECK(x) do { ++checks; if (!(x)) { ++failures; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); } } while (0)

static void pump(double seconds) {
    (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static bool exists(void) { return access("feth50", F_OK) == 0; }

int main(void) {
    char previous[4096], directory[] = "/tmp/rndis-tether-hook-XXXXXX";
    if (!getcwd(previous, sizeof previous) || !mkdtemp(directory) || chdir(directory)) return 1;
    Config cfg;
    char why[CONFIG_PROBLEM_SIZE];
    config_defaults(&cfg);
    CHECK(!cfg.network_hook[0]);
    CHECK(config_set(&cfg, SETTING_NETWORK_HOOK, "/usr/bin/touch", why, sizeof why));
    CHECK(!config_set(&cfg, SETTING_NETWORK_HOOK, "relative", why, sizeof why));
    CHECK(!config_set(&cfg, SETTING_NETWORK_HOOK, "/tmp/hook\nother", why, sizeof why));
    CHECK(!config_set(&cfg, SETTING_NETWORK_HOOK, "/tmp/hook#suffix", why, sizeof why));
    CHECK(!config_set_live(&cfg, SETTING_NETWORK_HOOK, "/usr/bin/touch", why, sizeof why));
    CHECK(!strcmp(cfg.network_hook, "/usr/bin/touch"));
    CHECK(config_save(&cfg, "config", why, sizeof why));
    Config loaded;
    config_defaults(&loaded);
    CHECK(config_load(&loaded, "config", why, sizeof why));
    CHECK(!strcmp(loaded.network_hook, cfg.network_hook));
    CHECK(config_set(&cfg, SETTING_NETWORK_HOOK, "none", why, sizeof why));
    CHECK(!cfg.network_hook[0]);

    CHECK(nethook_start("", "feth50"));
    nethook_notify(); pump(0.4);
    CHECK(!exists());

    CHECK(nethook_start("/usr/bin/touch", "feth50"));
    for (unsigned i = 0; i < 20; ++i) nethook_notify();
    pump(0.8);
    CHECK(exists());
    CHECK(unlink("feth50") == 0);
    pump(0.5);
    CHECK(!exists()); /* burst events did not queue 20 invocations */
    nethook_stop();

    /* A symlink may resolve to a trusted system file: the canonical target,
     * not the original user-writable path, is used for the spawn. */
    CHECK(symlink("/usr/bin/touch", "trusted-link") == 0);
    CHECK(nethook_start("trusted-link", "feth50"));
    pump(0.8);
    CHECK(exists());
    nethook_stop();
    CHECK(unlink("feth50") == 0);
    CHECK(unlink("trusted-link") == 0);

    /* A FIFO keeps cat in a real blocking syscall. The shortened test timeout must
     * kill/reap it without blocking the main run loop, then process pending events. */
    CHECK(mkfifo("feth50", 0600) == 0);
    CHECK(nethook_start("/bin/cat", "feth50"));
    pump(0.4);
    nethook_notify();
    pump(1.2);
    nethook_stop();
    int status = 0;
    CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    CHECK(unlink("feth50") == 0);

    int file = open("untrusted", O_WRONLY | O_CREAT, 0777);
    CHECK(file >= 0);
    if (file >= 0) close(file);
    CHECK(chmod("untrusted", 0777) == 0);
    char absolute[4096];
    snprintf(absolute, sizeof absolute, "%s/untrusted", directory);
    CHECK(!nethook_start(absolute, "feth50"));
    nethook_stop();
    CHECK(unlink("untrusted") == 0);
    CHECK(unlink("config") == 0);
    CHECK(chdir(previous) == 0);
    CHECK(rmdir(directory) == 0);
    printf("nethooktest: %u checks, %u failures\n", checks, failures);
    return failures ? 1 : 0;
}
