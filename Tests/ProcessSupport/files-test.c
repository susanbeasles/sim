#define _POSIX_C_SOURCE 200809L
#include "ScopedFiles.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char name[] = "/tmp/sim-files-XXXXXX";
    assert(mkdtemp(name));
    int root = sim_tree_root(name), mode;
    assert(root >= 0);
    assert(mkdirat(root, "outside", 0700) == 0);
    assert(mkdirat(root, "repo", 0700) == 0);
    int repo = openat(root, "repo", O_RDONLY | O_DIRECTORY);
    int outside = openat(root, "outside", O_RDONLY | O_DIRECTORY);
    assert(repo >= 0 && outside >= 0);
    const unsigned char original[] = "original";
    assert(sim_tree_write(outside, "file", "new1", original, 8, 0644) == 0);
    assert(symlinkat("../outside", repo, "link") == 0);
    assert(sim_tree_read(repo, "link/file", &mode) < 0);
    assert(sim_tree_write(repo, "link/file", "new2", original, 8, 0644) != 0);
    assert(sim_tree_remove(repo, "link/file") != 0);
    assert(sim_tree_write(repo, "../outside/file", "new2", original, 8, 0644) != 0);
    int fd = sim_tree_read(outside, "file", &mode);
    char bytes[9] = {0};
    assert(fd >= 0 && read(fd, bytes, 8) == 8 && !strcmp(bytes, "original"));
    close(fd);
    assert(sim_tree_write(repo, "new/file", "new3", original, 8, 0755) == 0);
    fd = sim_tree_read(repo, "new/file", &mode);
    assert(fd >= 0 && mode == 0755);
    close(fd);
    /* Replacing a leaf hardlink/symlink must never overwrite its target. */
    assert(linkat(outside, "file", repo, "hard", 0) == 0);
    assert(sim_tree_write(repo, "hard", "new4", (const unsigned char *)"changed", 7, 0644) == 0);
    assert(symlinkat("../outside/file", repo, "leaf") == 0);
    assert(sim_tree_read(repo, "leaf", &mode) < 0);
    assert(sim_tree_write(repo, "leaf", "new5", original, 8, 0644) == 0);
    fd = sim_tree_read(outside, "file", &mode);
    memset(bytes, 0, sizeof bytes);
    assert(fd >= 0 && read(fd, bytes, 8) == 8 && !strcmp(bytes, "original"));
    close(fd);
    assert(sim_tree_remove(repo, "new/file") == 0);
    assert(sim_tree_remove(repo, "missing/file") == 0);
    assert(unlinkat(repo, "new", AT_REMOVEDIR) == 0);
    assert(unlinkat(repo, "link", 0) == 0);
    assert(unlinkat(repo, "hard", 0) == 0);
    assert(unlinkat(repo, "leaf", 0) == 0);
    assert(unlinkat(outside, "file", 0) == 0);
    close(repo); close(outside);
    assert(unlinkat(root, "repo", AT_REMOVEDIR) == 0);
    assert(unlinkat(root, "outside", AT_REMOVEDIR) == 0);
    close(root); assert(rmdir(name) == 0);
    puts("PASS: anchored file operations reject intermediate links and preserve outside targets");
}
