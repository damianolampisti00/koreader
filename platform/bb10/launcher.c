/*
 * KOReader launcher: the BlackBerry 10 BAR's entry point.
 *
 * Runs in the app sandbox (cwd), with KOReader installed (read-only) in
 * app/native/koreader: keep settings & caches in data/koreader (KO_HOME),
 * log to logs/koreader.log, then exec LuaJIT on reader.lua.
 */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    char sandbox[PATH_MAX], app[PATH_MAX], home[PATH_MAX], libs[PATH_MAX], tess[PATH_MAX];

    (void)argc;
    (void)argv;
    if (!getcwd(sandbox, sizeof sandbox)) {
        perror("getcwd");
        return 1;
    }
    freopen("logs/koreader.log", "w", stdout);
    freopen("logs/koreader.log", "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    snprintf(app, sizeof app, "%s/app/native/koreader", sandbox);
    snprintf(home, sizeof home, "%s/data/koreader", sandbox);
    snprintf(libs, sizeof libs, "%s/libs", app);
    snprintf(tess, sizeof tess, "%s/data", app);
    mkdir(home, 0755);
    setenv("KO_HOME", home, 1);
    setenv("LD_LIBRARY_PATH", libs, 1);
    setenv("TESSDATA_PREFIX", tess, 1);

    if (chdir(app) != 0) {
        perror(app);
        return 1;
    }
    char *args[] = { "luajit", "reader.lua", NULL };
    execv("./luajit", args);
    perror("execv ./luajit");
    return 1;
}
