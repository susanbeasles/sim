#include "ProcessSupport.h"
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

int sim_spawn_group(const char *path, const char *const argv[],
                    const char *const envp[], int out_read, int out_write,
                    int err_read, int err_write, pid_t *pid) {
    /* Do not risk closing a standard stream if the host started without it. */
    if (out_read <= STDERR_FILENO || out_write <= STDERR_FILENO ||
        err_read <= STDERR_FILENO || err_write <= STDERR_FILENO) return EINVAL;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int rc = posix_spawnattr_init(&attr);
    if (rc) return rc;
    rc = posix_spawn_file_actions_init(&actions);
    if (rc) { posix_spawnattr_destroy(&attr); return rc; }
    /* Pipes are duplicated onto stdout/stderr before their original ends close. */
    if (!(rc = posix_spawnattr_setpgroup(&attr, 0)) &&
        !(rc = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP)) &&
        !(rc = posix_spawn_file_actions_adddup2(&actions, out_write, STDOUT_FILENO)) &&
        !(rc = posix_spawn_file_actions_adddup2(&actions, err_write, STDERR_FILENO)) &&
        !(rc = posix_spawn_file_actions_addclose(&actions, out_read)) &&
        !(rc = posix_spawn_file_actions_addclose(&actions, err_read)) &&
        !(rc = posix_spawn_file_actions_addclose(&actions, out_write)) &&
        !(rc = posix_spawn_file_actions_addclose(&actions, err_write))) {
        rc = posix_spawn(pid, path, &actions, &attr,
                         (char *const *)argv, (char *const *)envp);
    }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    return rc;
}

int sim_wait_child(pid_t pid, int nonblocking, int *status) {
    int raw;
    pid_t result;
    do { result = waitpid(pid, &raw, nonblocking ? WNOHANG : 0); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    if (result == 0) return 0;
    *status = WIFEXITED(raw) ? WEXITSTATUS(raw) : WTERMSIG(raw);
    return 1;
}

int sim_kill_group(pid_t pid) {
    if (pid <= 0) return EINVAL;
    if (kill(-pid, SIGKILL) == 0 || errno == ESRCH) return 0;
    return errno;
}
