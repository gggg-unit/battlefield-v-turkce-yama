#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static HINSTANCE instance;
static volatile LONG started = 0;
static volatile LONG displayCount = 0;

static BOOL CALLBACK FindGame(HWND window, LPARAM context) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(window) || GetWindow(window, GW_OWNER)) return TRUE;
    RECT rect = {};
    GetClientRect(window, &rect);
    if (rect.right >= 640 && rect.bottom >= 360) {
        *(HWND*)context = window;
        return FALSE;
    }
    return TRUE;
}

static LRESULT CALLBACK NoticeProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_NCHITTEST) return HTTRANSPARENT;
    if (message == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(window, &ps);
        RECT rect;
        GetClientRect(window, &rect);
        FillRect(dc, &rect, (HBRUSH)GetStockObject(BLACK_BRUSH));
        SetBkMode(dc, TRANSPARENT);
        HFONT font = CreateFontW(-48, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        HGDIOBJ old = SelectObject(dc, font);
        SetTextColor(dc, RGB(235, 245, 255));
        DrawTextW(dc, L"gggg-unit", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(dc, old);
        DeleteObject(font);
        EndPaint(window, &ps);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

static DWORD WINAPI Worker(void*) {
    HWND game = NULL;
    int stable = 0;
    ULONGLONG deadline = GetTickCount64() + 180000;
    while (GetTickCount64() < deadline) {
        game = NULL;
        EnumWindows(FindGame, (LPARAM)&game);
        if (game && GetForegroundWindow() == game && !IsIconic(game)) {
            if (++stable >= 5) break;
        } else stable = 0;
        Sleep(100);
    }
    if (stable < 5) return 0;

    WNDCLASSW wc = {};
    wc.hInstance = instance;
    wc.lpfnWndProc = NoticeProc;
    wc.lpszClassName = L"BFVUnitOpeningNotice";
    RegisterClassW(&wc);
    HWND notice = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        wc.lpszClassName, L"", WS_POPUP, 0, 0, 480, 90, game, NULL, instance, NULL);
    if (!notice) return 0;
    SetLayeredWindowAttributes(notice, RGB(0, 0, 0), 255, LWA_COLORKEY | LWA_ALPHA);
    ULONGLONG first = GetTickCount64();
    InterlockedIncrement(&displayCount);
    MSG message;
    while (IsWindow(game) && GetTickCount64() - first < 3000) {
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        RECT rect;
        POINT origin = {};
        GetClientRect(game, &rect);
        ClientToScreen(game, &origin);
        int x = origin.x + (rect.right - 480) / 2;
        int y = origin.y + rect.bottom / 6;
        ULONGLONG elapsed = GetTickCount64() - first;
        BYTE alpha = elapsed < 2600 ? 255 : (BYTE)((3000 - elapsed) * 255 / 400);
        SetLayeredWindowAttributes(notice, RGB(0, 0, 0), alpha, LWA_COLORKEY | LWA_ALPHA);
        if (GetForegroundWindow() == game && !IsIconic(game))
            SetWindowPos(notice, HWND_TOPMOST, x, y, 480, 90, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        else ShowWindow(notice, SW_HIDE);
        Sleep(15);
    }
    DestroyWindow(notice);
    UnregisterClassW(wc.lpszClassName, instance);
    return 0;
}

extern "C" __declspec(dllexport) const char* BFVPrepare() {
    if (InterlockedCompareExchange(&started, 1, 0) == 0) {
        HANDLE thread = CreateThread(NULL, 0, Worker, NULL, 0, NULL);
        if (thread) CloseHandle(thread);
    }
    return "PlayCeviri_Secure_Key_2026_V19!!";
}
extern "C" __declspec(dllexport) LONG BFVNoticeCount() { return displayCount; }

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        instance = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}
