// ntmwm.dll - replaces the Explorer CLSID_ExplorerHostCreator in-process COM server so the "Test Mode"
// watermark Windows shows while test signing (test mode) is on can be hidden. It is purely cosmetic and fully
// reversible: NoTestModeWM.ps1 points the registry at this DLL and restores the original when you restore the
// watermark.
//
// Every COM request is forwarded unchanged to the real ExplorerFrame.dll, so Explorer behaves normally. The
// only change: inside explorer.exe we redirect the DrawTextW slot that uxtheme.dll (the watermark renderer)
// uses, and when uxtheme asks to draw one of the three exact watermark strings we skip the paint and report a
// plausible height. Any other text, any other caller, and every other process are left untouched.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#include <intrin.h>
#include <string.h>
#include <wctype.h>

#pragma intrinsic(_ReturnAddress)

namespace {

using DllGetClassObjectFn = HRESULT(__stdcall*)(REFCLSID, REFIID, LPVOID*);
using DrawTextWFn = int(WINAPI*)(HDC, LPCWSTR, int, LPRECT, UINT);
using BrandingFormatStringFn = PWSTR(WINAPI*)(PCWSTR);

HMODULE g_self = nullptr;

// Real ExplorerFrame.dll class-object entry point (this DLL only forwards to it).
DllGetClassObjectFn g_realGetClassObject = nullptr;

DrawTextWFn g_realDrawTextW = nullptr;

// uxtheme.dll address range: the watermark is the only text we suppress, so we act only on its draws.
uintptr_t g_uxThemeBegin = 0;
uintptr_t g_uxThemeEnd = 0;

// The three exact watermark lines, read from the running system so they match the user's language and build:
//   [0] shell32.dll string 33088 ("Test Mode", localized)
//   [1] BrandingFormatString("%WINDOWS_LONG%") (the edition, e.g. "Windows 11 Pro")
//   [2] the BuildLab string (e.g. "26100.ge_release.240331-1435"), which is the specific part of " Build ..."
constexpr int kMaxFragment = 128;
constexpr int kMinFragment = 5; // below this a fragment is too generic to match safely
wchar_t g_fragment[3][kMaxFragment];
int g_fragmentLength[3];
int g_fragmentCount = 0;

INIT_ONCE g_initOnce = INIT_ONCE_STATIC_INIT;

void AddFragment(const wchar_t* text) {
    if (!text) {
        return;
    }
    int length = lstrlenW(text);
    if (length < kMinFragment || length >= kMaxFragment || g_fragmentCount >= 3) {
        return;
    }
    memcpy(g_fragment[g_fragmentCount], text, static_cast<size_t>(length) * sizeof(wchar_t));
    g_fragment[g_fragmentCount][length] = L'\0';
    g_fragmentLength[g_fragmentCount] = length;
    ++g_fragmentCount;
}

void HarvestStrings() {
    // shell32 string 33088. Load the module (ref-counted) so the localized MUI resource is used.
    HMODULE shell32 = LoadLibraryExW(L"shell32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (shell32) {
        wchar_t buffer[kMaxFragment];
        int n = LoadStringW(shell32, 33088, buffer, ARRAYSIZE(buffer));
        if (n > 0) {
            buffer[n] = L'\0';
            AddFragment(buffer);
        }
    }

    // Edition line via winbrand.dll. The returned buffer is freed with GlobalFree.
    HMODULE winbrand = LoadLibraryExW(L"winbrand.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (winbrand) {
        auto branding = reinterpret_cast<BrandingFormatStringFn>(GetProcAddress(winbrand, "BrandingFormatString"));
        if (branding) {
            PWSTR edition = branding(L"%WINDOWS_LONG%");
            if (edition) {
                AddFragment(edition);
                GlobalFree(edition);
            }
        }
    }

    // Build lab string: the specific, non-generic part of the third line.
    wchar_t buildLab[kMaxFragment];
    DWORD size = sizeof(buildLab);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
                     L"BuildLab", RRF_RT_REG_SZ, nullptr, buildLab, &size) == ERROR_SUCCESS) {
        AddFragment(buildLab);
    }
}

bool ContainsI(const wchar_t* hay, int hayLength, const wchar_t* needle, int needleLength) {
    if (needleLength <= 0 || hayLength < needleLength) {
        return false;
    }
    for (int i = 0; i <= hayLength - needleLength; ++i) {
        int j = 0;
        for (; j < needleLength; ++j) {
            if (towlower(hay[i + j]) != towlower(needle[j])) {
                break;
            }
        }
        if (j == needleLength) {
            return true;
        }
    }
    return false;
}

bool IsWatermarkText(const wchar_t* text, int length) {
    for (int i = 0; i < g_fragmentCount; ++i) {
        if (ContainsI(text, length, g_fragment[i], g_fragmentLength[i])) {
            return true;
        }
    }
    return false;
}

bool CallerIsUxTheme(const void* returnAddress) {
    auto address = reinterpret_cast<uintptr_t>(returnAddress);
    return g_uxThemeBegin != 0 && address >= g_uxThemeBegin && address < g_uxThemeEnd;
}

int WINAPI DrawTextWProxy(HDC hdc, LPCWSTR text, int count, LPRECT rect, UINT format) {
    if (!(format & DT_CALCRECT) && text && count != 0) {
        int length = count < 0 ? lstrlenW(text) : count;
        if (length > 0 && CallerIsUxTheme(_ReturnAddress()) && IsWatermarkText(text, length)) {
            // Skip the paint but hand back the height the caller's layout expects.
            if (rect) {
                RECT scratch = *rect;
                int height = g_realDrawTextW(hdc, text, count, &scratch,
                                             (format | DT_CALCRECT) & ~DT_MODIFYSTRING);
                return height > 0 ? height : 1;
            }
            return 1;
        }
    }
    return g_realDrawTextW(hdc, text, count, rect, format);
}

// Redirect the DrawTextW import slot of one module from the real function to our proxy.
void PatchModule(HMODULE module, void* target, void* replacement) {
    auto base = reinterpret_cast<BYTE*>(module);
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
        return;
    }
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) {
        return;
    }
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir.VirtualAddress == 0) {
        return;
    }
    auto import = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress);
    for (; import->Name != 0; ++import) {
        if (import->FirstThunk == 0) {
            continue;
        }
        auto thunk = reinterpret_cast<IMAGE_THUNK_DATA*>(base + import->FirstThunk);
        for (; thunk->u1.Function != 0; ++thunk) {
            auto slot = reinterpret_cast<void**>(&thunk->u1.Function);
            if (*slot != target) {
                continue;
            }
            DWORD previous = 0;
            if (VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &previous)) {
                *slot = replacement;
                VirtualProtect(slot, sizeof(void*), previous, &previous);
            }
        }
    }
}

// Patch the DrawTextW slot across every loaded module. uxtheme imports it (directly or through an API-set
// stub), and matching by resolved address rather than by name catches it either way.
void PatchAllModules(void* target, void* replacement) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return;
    }
    MODULEENTRY32W entry;
    entry.dwSize = sizeof(entry);
    if (Module32FirstW(snapshot, &entry)) {
        do {
            if (entry.hModule != g_self) {
                PatchModule(entry.hModule, target, replacement);
            }
        } while (Module32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
}

bool RunningInExplorer() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
    if (n == 0 || n >= ARRAYSIZE(path)) {
        return false;
    }
    const wchar_t* name = path;
    for (DWORD i = 0; i < n; ++i) {
        if (path[i] == L'\\') {
            name = &path[i + 1];
        }
    }
    return _wcsicmp(name, L"explorer.exe") == 0;
}

void RecordUxThemeRange() {
    HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) {
        return;
    }
    auto base = reinterpret_cast<BYTE*>(uxtheme);
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
        return;
    }
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) {
        return;
    }
    g_uxThemeBegin = reinterpret_cast<uintptr_t>(base);
    g_uxThemeEnd = g_uxThemeBegin + nt->OptionalHeader.SizeOfImage;
}

// Load the real ExplorerFrame.dll and install the watermark hook. Runs once, outside the loader lock.
BOOL CALLBACK InitOnce(PINIT_ONCE, PVOID, PVOID*) {
    // Build "<system32>\ExplorerFrame.dll", then load the real server.
    wchar_t realPath[MAX_PATH];
    UINT n = GetSystemDirectoryW(realPath, ARRAYSIZE(realPath));
    if (n > 0 && n < ARRAYSIZE(realPath)) {
        const wchar_t* suffix = L"\\ExplorerFrame.dll";
        if (n + lstrlenW(suffix) < ARRAYSIZE(realPath)) {
            lstrcatW(realPath, suffix);
            HMODULE real = LoadLibraryW(realPath);
            if (real) {
                g_realGetClassObject = reinterpret_cast<DllGetClassObjectFn>(GetProcAddress(real, "DllGetClassObject"));
            }
        }
    }

    if (RunningInExplorer()) {
        HMODULE user32 = GetModuleHandleW(L"user32.dll");
        if (user32) {
            g_realDrawTextW = reinterpret_cast<DrawTextWFn>(GetProcAddress(user32, "DrawTextW"));
        }
        if (g_realDrawTextW) {
            HarvestStrings();
            RecordUxThemeRange();
            if (g_fragmentCount > 0 && g_uxThemeBegin != 0) {
                PatchAllModules(reinterpret_cast<void*>(g_realDrawTextW),
                                reinterpret_cast<void*>(&DrawTextWProxy));
            }
        }
    }
    return TRUE;
}

void EnsureInit() {
    InitOnceExecuteOnce(&g_initOnce, InitOnce, nullptr, nullptr);
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID* ppv) {
    EnsureInit();
    if (!g_realGetClassObject) {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    return g_realGetClassObject(rclsid, riid, ppv);
}

extern "C" HRESULT __stdcall DllCanUnloadNow(void) {
    // Keep this DLL resident: the installed hook must outlive COM's unload checks.
    return S_FALSE;
}
