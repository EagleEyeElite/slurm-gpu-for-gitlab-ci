/*
 * fakemount - seccomp filter that fakes mount propagation changes.
 *
 * Intercepts mount() syscalls with MS_PRIVATE|MS_REC or MS_SLAVE|MS_REC
 * flags (without MS_BIND) and returns success without executing them.
 * This allows buildah to run inside user namespaces where changing mount
 * propagation on the root filesystem is not permitted.
 *
 * Usage: fakemount <command> [args...]
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <sys/syscall.h>

/* Mount flags we care about */
#define MS_REC       0x4000
#define MS_PRIVATE   0x40000
#define MS_SLAVE     0x80000
#define MS_BIND      0x1000
#define MS_REMOUNT   0x20

/* Mask: propagation flags + MS_REC + flags that indicate NOT a propagation-only call */
#define PROP_MASK  (MS_PRIVATE | MS_SLAVE | MS_REC | MS_BIND | MS_REMOUNT)
/* Match 1: MS_PRIVATE | MS_REC without MS_BIND or MS_REMOUNT */
#define PROP_PRIV  (MS_PRIVATE | MS_REC)
/* Match 2: MS_SLAVE | MS_REC without MS_BIND or MS_REMOUNT */
#define PROP_SLAVE (MS_SLAVE | MS_REC)

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    struct sock_filter filter[] = {
        /* Load architecture */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch)),
        /* Verify x86_64 */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),

        /* Load syscall number */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
        /* Check if mount (syscall 165 on x86_64) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_mount, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),

        /* Load mountflags (arg3 = args[3], lower 32 bits) */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, args[3])),
        /* Mask to relevant bits */
        BPF_STMT(BPF_ALU | BPF_AND | BPF_K, PROP_MASK),
        /* Check MS_PRIVATE | MS_REC (0x44000) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PROP_PRIV, 1, 0),
        /* Check MS_SLAVE | MS_REC (0x84000) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PROP_SLAVE, 0, 1),

        /* Match: fake success (SECCOMP_RET_ERRNO with errno=0) */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | 0),

        /* No match: allow */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };

    struct sock_fprog prog = {
        .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])),
        .filter = filter,
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        perror("prctl(NO_NEW_PRIVS)");
        return 1;
    }

    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) != 0) {
        perror("prctl(SECCOMP_MODE_FILTER)");
        return 1;
    }

    execvp(argv[1], argv + 1);
    perror("execvp");
    return 1;
}
