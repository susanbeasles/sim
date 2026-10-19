#ifndef SIM_PROCESS_SUPPORT_H
#define SIM_PROCESS_SUPPORT_H
#include <sys/types.h>

/* Launch a command in a group owned by its child PID, before it executes. */
int sim_spawn_group(const char *path, const char *const argv[],
                    const char *const envp[], int out_read, int out_write,
                    int err_read, int err_write, pid_t *pid);
/* Return 1 when reaped, 0 while running, or a negative errno on failure. */
int sim_wait_child(pid_t pid, int nonblocking, int *status);
int sim_kill_group(pid_t pid);
#endif
