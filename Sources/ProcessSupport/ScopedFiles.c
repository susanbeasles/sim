#include "ScopedFiles.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int sim_tree_root(const char *path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    return fd < 0 ? -errno : fd;
}

static int parent(int root, const char *path, int create, char **leaf) {
    if (!path || !*path || *path == '/' || strstr(path, "//")) return -EINVAL;
    size_t size = strlen(path);
    if (path[size - 1] == '/') return -EINVAL;
    char *copy = strdup(path);
    if (!copy) return -ENOMEM;
    int fd = fcntl(root, F_DUPFD_CLOEXEC, 3);
    if (fd < 0) { int error = errno; free(copy); return -error; }
    char *saved = NULL, *part = strtok_r(copy, "/", &saved);
    while (part) {
        if (!strcmp(part, ".") || !strcmp(part, "..")) {
            close(fd); free(copy); return -EINVAL;
        }
        char *next = strtok_r(NULL, "/", &saved);
        if (!next) {
            *leaf = strdup(part);
            free(copy);
            if (!*leaf) { close(fd); return -ENOMEM; }
            return fd;
        }
        int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (child < 0 && errno == ENOENT && create) {
            if (mkdirat(fd, part, 0755) == 0 || errno == EEXIST)
                child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (child < 0) { int error = errno; close(fd); free(copy); return -error; }
        close(fd); fd = child; part = next;
    }
    close(fd); free(copy); return -EINVAL;
}

int sim_tree_read(int root, const char *path, int *mode) {
    char *leaf = NULL;
    int dir = parent(root, path, 0, &leaf);
    if (dir < 0) return dir;
    int fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int error = errno;
    free(leaf); close(dir);
    if (fd < 0) return -error;
    struct stat info;
    if (fstat(fd, &info) < 0) { error = errno; close(fd); return -error; }
    if (!S_ISREG(info.st_mode)) { close(fd); return -EINVAL; }
    *mode = (info.st_mode & 0111) ? 0755 : 0644;
    return fd;
}

int sim_tree_write(int root, const char *path, const char *temporary,
                   const unsigned char *bytes, size_t size, int mode) {
    if (!temporary || !*temporary || strchr(temporary, '/') ||
        !strcmp(temporary, ".") || !strcmp(temporary, "..") ||
        (mode != 0644 && mode != 0755)) return EINVAL;
    char *leaf = NULL;
    int dir = parent(root, path, 1, &leaf);
    if (dir < 0) return -dir;
    if (!strcmp(temporary, leaf)) { free(leaf); close(dir); return EINVAL; }
    int fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { int error = errno; free(leaf); close(dir); return error; }
    int error = 0;
    for (size_t offset = 0; offset < size;) {
        ssize_t count = write(fd, bytes + offset, size - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { error = count < 0 ? errno : EIO; break; }
        offset += (size_t)count;
    }
    if (!error && fchmod(fd, (mode_t)mode) < 0) error = errno;
    if (close(fd) < 0 && !error) error = errno;
    if (!error && renameat(dir, temporary, dir, leaf) < 0) error = errno;
    if (error) unlinkat(dir, temporary, 0);
    free(leaf); close(dir);
    return error;
}

int sim_tree_remove(int root, const char *path) {
    char *leaf = NULL;
    int dir = parent(root, path, 0, &leaf);
    if (dir < 0) return dir == -ENOENT ? 0 : -dir;
    int result = unlinkat(dir, leaf, 0), error = errno;
    free(leaf); close(dir);
    return result == 0 || error == ENOENT ? 0 : error;
}
