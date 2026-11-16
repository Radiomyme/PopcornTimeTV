// Test-rig shim (never in the app): injected with DYLD_INSERT_LIBRARIES into the simulator app that an XCUITest
// launches, it sends the app's stdout / stderr to the file PT_STDOUT_FILE (line-buffered), so the rig keeps the
// app's console log as `simctl launch --console-pty` would give it.
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void pt_stdout_redirect(void) {
    const char *file = getenv("PT_STDOUT_FILE");
    if (!file || !*file) return;
    if (freopen(file, "a", stdout)) setvbuf(stdout, NULL, _IOLBF, 0);
    if (freopen(file, "a", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
}
