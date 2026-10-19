#define _POSIX_C_SOURCE 200809L
#include "ProcessSupport.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
int main(void) {
    int out[2], err[2], status;
    pid_t pid;
    char marker[] = "/tmp/sim-group-test-XXXXXX";
    int file = mkstemp(marker);
    assert(file >= 0);
    close(file);
    assert(unlink(marker) == 0);
    assert(pipe(out) == 0 && pipe(err) == 0);
    const char *args[] = {"/bin/sh", "-c",
        "(sleep 0.3; printf survived > \"$1\") & printf ready; exit 0", "fixture", marker, NULL};
    assert(sim_spawn_group(args[0], args, (const char *const *)environ,
                           out[0], out[1], err[0], err[1], &pid) == 0);
    close(out[1]); close(err[1]);
    char ready[5];
    assert(read(out[0], ready, sizeof ready) == sizeof ready);
    struct timespec pause = {0, 50000000};
    nanosleep(&pause, NULL); /* leader exits, child still owns the pipe */
    assert(sim_kill_group(pid) == 0);
    assert(sim_wait_child(pid, 0, &status) == 1);
    pause.tv_nsec = 500000000;
    nanosleep(&pause, NULL);
    assert(access(marker, F_OK) == -1 && errno == ENOENT);
    close(out[0]); close(err[0]);
    assert(sim_kill_group(0) == EINVAL);
    puts("PASS: owned group cleanup stops descendant after leader exit");
    return 0;
}
