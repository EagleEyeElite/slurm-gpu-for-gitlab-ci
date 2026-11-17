/*
 * buildah-wrap.c — tiny wrapper around patched buildah inside the build chroot.
 *
 * Patched buildah re-execs /proc/self/exe with Env=[]string{"LOGLEVEL=5"} for
 * the "buildah-chroot-runtime" subprocess. That child calls
 * containers/common/pkg/config.Default(), which needs $HOME; without it the
 * build fails with "cannot determine user's homedir".
 *
 * Shell wrappers don't work because a shebang-invoked script loses argv[0]
 * (the "buildah-chroot-runtime"/"buildah-copier" signature). A static C wrapper
 * preserves argv[0] via execv().
 */
#include <unistd.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    setenv("HOME", "/root", 1);
    execv("/usr/bin/buildah.real", argv);
    return 127;
}
