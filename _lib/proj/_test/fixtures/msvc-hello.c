#include <stdio.h>
#include <windows.h>

int main(void) {
    puts("swawkit-msvc-ok");
    return GetCurrentProcessId() == 0;
}
