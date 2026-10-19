#ifndef SIM_SCOPED_FILES_H
#define SIM_SCOPED_FILES_H
#include <stddef.h>
/* Open functions return an fd or negative errno. Others return zero or errno. */
int sim_tree_root(const char *path);
int sim_tree_read(int root, const char *path, int *mode);
int sim_tree_write(int root, const char *path, const char *temporary,
                   const unsigned char *bytes, size_t size, int mode);
int sim_tree_remove(int root, const char *path);
#endif
