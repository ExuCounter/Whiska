// Proof-of-concept: the whole v0.0.1 decision, natively.
// stdin = PreToolUse JSON. Deny if file_path escapes the worktree root.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

int main(void) {
    static char buf[1 << 16];
    ssize_t n = read(0, buf, sizeof buf - 1);
    if (n <= 0) return 0;
    buf[n] = 0;

    // Worktree root: cwd up to and including .../worktrees/<branch>
    char cwd[4096];
    if (!getcwd(cwd, sizeof cwd)) return 0;
    char *wt = strstr(cwd, "/worktrees/");
    if (!wt) return 0;                       // not in a worktree, nothing to enforce
    char *slash = strchr(wt + 11, '/');
    if (slash) *slash = 0;                   // trim to the worktree root

    const char *k = "\"file_path\"";
    char *p = strstr(buf, k);
    if (!p) return 0;                        // no path-bearing tool -> allow
    p = strchr(p + strlen(k), '"');
    if (!p) return 0;
    char *end = strchr(++p, '"');
    if (!end) return 0;
    *end = 0;

    if (strncmp(p, cwd, strlen(cwd)) == 0) return 0;   // inside the worktree -> allow

    printf("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
           "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":"
           "\"whiska: %s is outside this mouse's worktree\"}}\n", p);
    return 0;
}
