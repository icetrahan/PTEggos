// Stand-in for TheIsleServer-Win64-Shipping.exe in test_launch_e2e.ps1 -Loader (A230).
// Like the real Legacy server it (1) statically imports DSOUND.dll, so a dsound.dll beside it
// (Ultimate ASI Loader) is loaded at process start and loads primal-loader.asi, and (2) re-spawns
// itself detached and exits, so the wrapper must find and supervise the child. The child writes
// ..\..\Saved\Logs\TheIsle.log (shareable, like UE) with THIS boot's world line after 2 s and lives
// FAKE_LIFE seconds.
//   test_fake_isle.exe                 -> spawns "--child", exits
//   test_fake_isle.exe --child <secs>
// Build: cl /nologo /EHsc /O2 /MT /DUNICODE /D_UNICODE test_fake_isle.cpp
#include <windows.h>
#include <dsound.h>
#include <cstdio>
#include <cstdlib>
#include <share.h>
#include <string>
#pragma comment(lib, "dsound.lib")
volatile void* g_keep = (void*)&DirectSoundCreate8;

int wmain(int argc, wchar_t** argv) {
    wchar_t exe[MAX_PATH]; GetModuleFileNameW(nullptr, exe, MAX_PATH);
    if (argc >= 3 && wcscmp(argv[1], L"--child") == 0) {
        int life = _wtoi(argv[2]);
        std::wstring dir(exe); dir = dir.substr(0, dir.find_last_of(L"\\"));
        std::wstring logs = dir + L"\\..\\..\\Saved\\Logs";
        CreateDirectoryW((dir + L"\\..\\..\\Saved").c_str(), nullptr);
        CreateDirectoryW(logs.c_str(), nullptr);
        FILE* f = _wfsopen((logs + L"\\TheIsle.log").c_str(), L"wb", _SH_DENYNO);
        if (!f) return 3;
        fputs("\xEF\xBB\xBFLog file open\r\n", f); fflush(f);
        for (int s = 0; s < life; ++s) {
            if (s == 2) fputs("[x][  0]LogWorld: Bringing World /Game/TheIsle/Maps/Fake/Fake.Fake up for play (max tick rate 30)\r\n", f);
            else fprintf(f, "[x][  0]LogFake: tick %d\r\n", s);
            fflush(f);
            Sleep(1000);
        }
        fclose(f);
        return 0;
    }
    const wchar_t* life = _wgetenv(L"FAKE_LIFE");
    std::wstring cmd = std::wstring(L"\"") + exe + L"\" --child " + (life && *life ? life : L"60");
    STARTUPINFOW si = { sizeof(si) }; PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr, &si, &pi)) return 4;
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return 0;
}
