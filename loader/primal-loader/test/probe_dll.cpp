// A DLL standing in for LegacyMod.dll / commban.dll: DllMain appends "probe loaded pid N" beside itself.
#include <windows.h>
#include <cstdio>
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID) {
    if (r == DLL_PROCESS_ATTACH) {
        wchar_t p[MAX_PATH]; GetModuleFileNameW(h, p, MAX_PATH); wcscat_s(p, L".loaded.txt");
        FILE* f = nullptr; if (_wfopen_s(&f, p, L"ab") == 0 && f) { fprintf(f, "probe loaded pid %lu\r\n", GetCurrentProcessId()); fclose(f); }
    }
    return TRUE;
}
