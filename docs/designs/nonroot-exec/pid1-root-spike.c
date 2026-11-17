/* Disposable proof only: not production elevation code. */
#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <grp.h>
int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1 || getpid() != 1 || getuid() != 1000 || geteuid() != 0) {
        fprintf(stderr, "refused: argc=%d pid=%ld uid=%ld euid=%ld\n", argc, (long)getpid(), (long)getuid(), (long)geteuid());
        return 77;
    }
    if (setgroups(0, NULL) || setresgid(0,0,0) || setresuid(0,0,0)) { perror("set ids"); return 78; }
    if (chdir("/")) return 79;
    /* Fixed image-owned entrypoint, fixed argv; no caller-supplied command. */
    execl("/usr/local/sbin/openclaw-systemd-entrypoint", "openclaw-systemd-entrypoint", (char *)NULL);
    perror("exec entrypoint"); return 80;
}
