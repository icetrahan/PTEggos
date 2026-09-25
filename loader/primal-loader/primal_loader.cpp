// primal-loader.asi - the game loads its own Primal DLLs. No injector, no pid, no owner check.
//
// WHY (A230, BUGS #2700 + #2724): a Windows Isle server got its mod from a PowerShell job that had
// to FIND the game's process from outside and CreateRemoteThread into it. That outside step failed
// two different ways in two days: 09-24 it picked ANOTHER server's pid (same second, same exe name),
// 09-25 it refused the RIGHT pid (feathers runs each game as pt_<volume>, not the wrapper's user).
// Each time it tried once (or one burst) and the server ran for hours without the mod.
//
// THIS FILE removes the outside step. Ultimate ASI Loader (dsound.dll beside the exe - the same
// sha-pinned binary the Evrima sigbypass lane has shipped since 2026-08) loads every *.asi in the
// exe's directory at process start. This .asi therefore runs INSIDE every process of THIS server's
// exe, on every start, including a crash-restart - it cannot be in the wrong process, and it needs
// no rights over anyone.
//
// What it does, on its own thread (never in DllMain - loader lock):
//   1. reads primal-loader.ini beside itself (the wrapper writes it every boot);
//   2. waits for THIS boot's world: the game log, last written after this process started, carries a
//      `world_match` line (both games print "LogWorld: Bringing World ... up for play"). The mods
//      resolve GObjects once and refuse/FATAL if loaded before the world exists - the old injector's
//      "+10 s" timing is what they were proven under, so this reproduces it from the inside;
//   3. waits `settle_s`, then LoadLibraryW's each `load=` path, VERIFIES it by module handle, and retries
//      a failed load every `retry_s` for `retries` times;
//   4. writes one line per decision to `log=` (the wrapper's _primal dir, so it is readable over the
//      Ptero files API). Every exit names itself - "nothing to load", "world never came up", "LOADED",
//      "FAILED" - a skip is never silent (hard rule 13).
// It does no networking. Off-box truth stays the mod's own telemetry + the wrapper's watchdog report.
#define NOMINMAX
#include <windows.h>
#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#define PRIMAL_LOADER_VERSION "1.0.0"

static HMODULE g_self = nullptr;
static std::wstring g_log;

static std::wstring self_dir() {
    wchar_t p[MAX_PATH * 2] = {0};
    GetModuleFileNameW(g_self, p, (DWORD)(sizeof(p) / sizeof(p[0])));
    std::wstring s(p);
    size_t k = s.find_last_of(L"\\/");
    return k == std::wstring::npos ? L"." : s.substr(0, k);
}

static std::string narrow(const std::wstring& w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

static std::wstring widen(const std::string& s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

static void logline(const std::string& m) {
    SYSTEMTIME t; GetSystemTime(&t);
    char head[96];
    sprintf_s(head, "%04d-%02d-%02dT%02d:%02d:%02dZ pid %lu ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, GetCurrentProcessId());
    FILE* f = nullptr;
    if (_wfopen_s(&f, g_log.c_str(), L"ab") == 0 && f) {
        fputs(head, f); fputs(m.c_str(), f); fputs("\r\n", f); fclose(f);
    }
}

struct Config {
    std::wstring world_log;
    std::vector<std::string> world_match;
    int world_timeout_s = 600;
    int settle_s = 10;
    int retry_s = 30;
    int retries = 20;
    std::vector<std::wstring> load;
    bool found = false;
};

static std::string trim(std::string s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ' || s.back() == '\t')) s.pop_back();
    size_t i = 0; while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) ++i;
    return s.substr(i);
}

static Config read_config(const std::wstring& path) {
    Config c;
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return c;
    c.found = true;
    char buf[4096];
    bool first = true;
    while (fgets(buf, sizeof(buf), f)) {
        std::string l(buf);
        if (first && l.size() >= 3 && (unsigned char)l[0] == 0xEF && (unsigned char)l[1] == 0xBB && (unsigned char)l[2] == 0xBF) l = l.substr(3);
        first = false;
        l = trim(l);
        if (l.empty() || l[0] == '#' || l[0] == ';' || l[0] == '[') continue;
        size_t eq = l.find('=');
        if (eq == std::string::npos) continue;
        std::string k = trim(l.substr(0, eq)), v = trim(l.substr(eq + 1));
        if (k == "log") g_log = widen(v);
        else if (k == "world_log") c.world_log = widen(v);
        else if (k == "world_match") { if (!v.empty()) c.world_match.push_back(v); }
        else if (k == "world_timeout_s") c.world_timeout_s = atoi(v.c_str());
        else if (k == "settle_s") c.settle_s = atoi(v.c_str());
        else if (k == "retry_s") c.retry_s = atoi(v.c_str());
        else if (k == "retries") c.retries = atoi(v.c_str());
        else if (k == "load") { if (!v.empty()) c.load.push_back(widen(v)); }
    }
    fclose(f);
    return c;
}

static ULONGLONG ft64(const FILETIME& ft) { return ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime; }

static bool contains_any(const std::string& hay, const std::vector<std::string>& needles) {
    for (auto& n : needles) {
        if (hay.find(n) != std::string::npos) return true;
        // UTF-16LE logs: the same ASCII needle, byte-interleaved with zeros.
        std::string w; for (char ch : n) { w.push_back(ch); w.push_back('\0'); }
        if (hay.find(w) != std::string::npos) return true;
    }
    return false;
}

// Waits for THIS boot's world. Returns the seconds waited, or -1 on timeout.
static int wait_for_world(const Config& c) {
    FILETIME cr, ex, ke, us;
    GetProcessTimes(GetCurrentProcess(), &cr, &ex, &ke, &us);
    const ULONGLONG started = ft64(cr);
    const ULONGLONG slack = 5ULL * 10000000ULL;   // 5 s, in 100 ns units
    size_t maxNeedle = 0; for (auto& n : c.world_match) maxNeedle = std::max(maxNeedle, n.size() * 2);
    ULONGLONG offset = 0; DWORD volSerial = 0, idHi = 0, idLo = 0;
    std::string carry;
    const DWORD t0 = GetTickCount();
    for (;;) {
        int waited = (int)((GetTickCount() - t0) / 1000);
        if (waited >= c.world_timeout_s) return -1;
        HANDLE h = CreateFileW(c.world_log.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            BY_HANDLE_FILE_INFORMATION fi;
            BOOL gi = GetFileInformationByHandle(h, &fi);
#ifdef LOADER_MUTANT_NO_STALE_GUARD
            if (gi) {   // harness mutant: the previous boot's log is trusted
#else
            if (gi && ft64(fi.ftLastWriteTime) + slack >= started) {
#endif
                // A rotated/recreated log (UE renames the old one to *-backup-*) starts over.
                if (fi.dwVolumeSerialNumber != volSerial || fi.nFileIndexHigh != idHi || fi.nFileIndexLow != idLo) {
                    volSerial = fi.dwVolumeSerialNumber; idHi = fi.nFileIndexHigh; idLo = fi.nFileIndexLow;
                    offset = 0; carry.clear();
                }
                ULONGLONG size = ((ULONGLONG)fi.nFileSizeHigh << 32) | fi.nFileSizeLow;
                if (size < offset) { offset = 0; carry.clear(); }
                if (size > offset) {
                    LARGE_INTEGER li; li.QuadPart = (LONGLONG)offset;
                    SetFilePointerEx(h, li, nullptr, FILE_BEGIN);
                    std::string chunk((size_t)std::min<ULONGLONG>(size - offset, 8ULL << 20), '\0');
                    DWORD got = 0;
                    if (ReadFile(h, &chunk[0], (DWORD)chunk.size(), &got, nullptr) && got) {
                        chunk.resize(got);
                        offset += got;
                        std::string hay = carry + chunk;
                        if (contains_any(hay, c.world_match)) { CloseHandle(h); return waited; }
                        carry = hay.size() > maxNeedle ? hay.substr(hay.size() - maxNeedle) : hay;
                    }
                }
            }
            CloseHandle(h);
        }
        Sleep(1000);
    }
}

static bool is_loaded(const std::wstring& path) {
    HMODULE m = nullptr;
    return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, path.c_str(), &m) && m;
}

static DWORD WINAPI loader_thread(LPVOID) {
    const std::wstring dir = self_dir();
    const std::wstring ini = dir + L"\\primal-loader.ini";
    g_log = dir + L"\\primal-loader.log";   // until the ini names the real one
    Config c = read_config(ini);
    wchar_t exe[MAX_PATH * 2] = {0};
    GetModuleFileNameW(nullptr, exe, (DWORD)(sizeof(exe) / sizeof(exe[0])));
    logline("===== primal-loader " PRIMAL_LOADER_VERSION " in " + narrow(exe) + " =====");
    if (!c.found) { logline("NOTHING TO LOAD: no primal-loader.ini beside " + narrow(dir) + " - the wrapper writes it every boot"); return 0; }
    if (c.load.empty()) { logline("NOTHING TO LOAD: primal-loader.ini lists no load= line (the mod is off for this server)"); return 0; }
    if (c.world_log.empty() || c.world_match.empty()) { logline("REFUSING: primal-loader.ini has no world_log/world_match - loading before the world exists makes the mods refuse"); return 0; }
    std::string list; for (auto& p : c.load) list += " " + narrow(p);
    logline("waiting for this boot's world in " + narrow(c.world_log) + " (<= " + std::to_string(c.world_timeout_s) + " s), then +" +
            std::to_string(c.settle_s) + " s; will load:" + list);
    int w = wait_for_world(c);
    if (w < 0) { logline("NOT LOADED: the world never came up within " + std::to_string(c.world_timeout_s) + " s - the wrapper's watchdog is the fallback"); return 0; }
    logline("world up after " + std::to_string(w) + " s");
    Sleep((DWORD)std::max(0, c.settle_s) * 1000);
    for (auto& p : c.load) {
        const std::string np = narrow(p);
        if (is_loaded(p)) { logline("LOADED (already present): " + np); continue; }
        bool ok = false;
        for (int n = 1; n <= std::max(1, c.retries) && !ok; ++n) {
            if (GetFileAttributesW(p.c_str()) == INVALID_FILE_ATTRIBUTES) {
                logline("attempt " + std::to_string(n) + ": file missing: " + np);
            } else {
                HMODULE m = LoadLibraryW(p.c_str());
                DWORD err = m ? 0 : GetLastError();
                ok = m && is_loaded(p);
                char hx[32]; sprintf_s(hx, "0x%p", (void*)m);
                logline(std::string(ok ? "LOADED: " : "attempt " + std::to_string(n) + " FAILED: ") + np + " handle=" + hx + (err ? " error=" + std::to_string(err) : ""));
            }
            if (!ok && n < c.retries) Sleep((DWORD)std::max(1, c.retry_s) * 1000);
        }
        if (!ok) logline("FAILED: " + np + " is NOT loaded after " + std::to_string(std::max(1, c.retries)) + " attempt(s) - the wrapper's watchdog is the fallback");
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = h;
        DisableThreadLibraryCalls(h);
        HANDLE t = CreateThread(nullptr, 0, loader_thread, nullptr, 0, nullptr);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
