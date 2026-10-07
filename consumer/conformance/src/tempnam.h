/* Conformance-only use of Lua's lua_tmpnam configuration hook.
 * run.sh first enters fresh approved scratch. Relative leaf names preserve
 * official CLI module-name tests; keep the POSIX operation byte-for-byte. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define LUA_TMPNAMBUFSIZE sizeof(LUA_TMPNAMTEMPLATE)
#define lua_tmpnam(b,e) { \
        strcpy(b, LUA_TMPNAMTEMPLATE); \
        e = mkstemp(b); \
        if (e != -1) close(e); \
        e = (e == -1); }

/* liolib.c calls libc tmpfile() directly (there is no l_tmpfile hook).
 * libc may ignore TMPDIR and use forbidden /tmp storage. Only this instrumented
 * build redirects that call to an anonymous regular stream in fresh workdir. */
static inline FILE *zlua_conformance_tmpfile(void) {
    char path[] = LUA_TMPNAMTEMPLATE;
    int fd = mkstemp(path);
    if (fd == -1)
        return NULL;
    if (unlink(path) != 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return NULL;
    }
    FILE *stream = fdopen(fd, "w+b");
    if (stream == NULL) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
    }
    return stream;
}

/* Define after stdio.h so its actual libc declaration remains untouched. */
#define tmpfile() zlua_conformance_tmpfile()
