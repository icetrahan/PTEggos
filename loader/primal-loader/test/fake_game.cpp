// Stand-in for TheIsleServer-Win64-Shipping.exe in the loader harness: it statically imports
// DSOUND.dll (as both real server exes do), so Ultimate ASI Loader's dsound.dll proxy is loaded at
// process start exactly as on a node. It writes a UE-style log and prints the world line after
// <world_after_s> (-1 = never), stays up <run_s>, then reports whether <probe dll> is in its module list.
//   fake_game.exe <log> <world_after_s> <run_s> <probe_dll_path> [open_log_after_s]
// open_log_after_s > 0 leaves the PREVIOUS boot's log in place for that long (the stale-log case).
#include <windows.h>
#include <dsound.h>
#include <cstdio>
#include <cstdlib>
#include <share.h>
#pragma comment(lib, "dsound.lib")
volatile void* g_keep = (void*)&DirectSoundCreate8;
int wmain(int argc, wchar_t** argv) {
    if (argc < 5) return 2;
    const wchar_t* log = argv[1]; int world = _wtoi(argv[2]); int run = _wtoi(argv[3]); const wchar_t* probe = argv[4];
    int openAfter = argc > 5 ? _wtoi(argv[5]) : 0;
    Sleep(openAfter * 1000);
    // Shareable like UE's own log (FILE_SHARE_READ) - _wfopen_s would deny every reader.
    FILE* f = _wfsopen(log, L"wb", _SH_DENYNO);
    if (!f) return 3;
    fputs("\xEF\xBB\xBFLog file open\r\n", f); fflush(f);
    for (int s = openAfter; s < run; ++s) {
        if (s == world) { fputs("[x][  0]LogWorld: Bringing World /Game/Fake/Fake.Fake up for play (max tick rate 30)\r\n", f); fflush(f); }
        else { fprintf(f, "[x][  0]LogFake: tick %d\r\n", s); fflush(f); }
        Sleep(1000);
    }
    fclose(f);
    HMODULE m = GetModuleHandleW(probe);
    printf("fake_game pid=%lu probe_loaded=%s\n", GetCurrentProcessId(), m ? "yes" : "no");
    return m ? 0 : 1;
}
