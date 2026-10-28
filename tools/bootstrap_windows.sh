#!/usr/bin/env bash
# Создаёт папку windows/ (Flutter runner) и настраивает имя, размер окна и иконку.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f windows/CMakeLists.txt ]; then
  flutter create --platforms=windows --project-name relayfast --org app.relayfast .
fi

# Тест-пример от flutter create не подходит нашему приложению.
rm -f test/widget_test.dart

python3 - <<'PY'
import re, pathlib, sys

def patch(path, fn, must=True):
    p = pathlib.Path(path)
    s = p.read_text(encoding="utf-8")
    n = fn(s)
    if must and n == s:
        print(f"ВНИМАНИЕ: {path} не изменён", file=sys.stderr)
        sys.exit(1)
    p.write_text(n, encoding="utf-8")

# имя исполняемого файла
patch("windows/CMakeLists.txt",
      lambda s: re.sub(r'set\(BINARY_NAME\s+"[^"]*"\)', 'set(BINARY_NAME "RelayFastVPN")', s))

# заголовок и размер окна
def main_cpp(s):
    s = re.sub(r'window\.Create\(L"[^"]*"', 'window.Create(L"RelayFastVPN"', s)
    s = re.sub(r'Win32Window::Size size\(\s*\d+\s*,\s*\d+\s*\)', 'Win32Window::Size size(460, 740)', s)
    # один экземпляр приложения: второй запуск показывает уже открытое окно
    snippet = '''
  // --- RelayFastVPN: только один экземпляр ---
  {
    HANDLE rf_mutex = ::CreateMutexW(nullptr, FALSE, L"RelayFastVPN_SingleInstance");
    DWORD rf_err = ::GetLastError();
    bool rf_relaunch = wcsstr(::GetCommandLineW(), L"--relaunch") != nullptr;
    bool rf_running = (rf_mutex == nullptr) || rf_err == ERROR_ALREADY_EXISTS;
    if (rf_running) {
      bool rf_got = false;
      if (rf_relaunch && rf_mutex != nullptr) {
        // перезапуск с правами администратора: ждём, пока закроется прежнее окно
        DWORD w = ::WaitForSingleObject(rf_mutex, 10000);
        rf_got = (w == WAIT_OBJECT_0 || w == WAIT_ABANDONED);
      }
      if (!rf_got) {
        HWND hwnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"RelayFastVPN");
        if (hwnd) {
          ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
          ::SetForegroundWindow(hwnd);
        }
        return 0;
      }
    } else {
      ::WaitForSingleObject(rf_mutex, 0);
    }
  }
'''
    s = re.sub(r'(int APIENTRY wWinMain\([^)]*\)\s*\{)', lambda m: m.group(1) + snippet, s, count=1)
    return s
patch("windows/runner/main.cpp", main_cpp)

# строки версии файла (видны в свойствах .exe)
def rc(s):
    s = re.sub(r'(VALUE "(?:FileDescription|InternalName|ProductName)",\s*")[^"]*(")', r'\1RelayFastVPN\2', s)
    s = re.sub(r'(VALUE "OriginalFilename",\s*")[^"]*(")', r'\1RelayFastVPN.exe\2', s)
    s = re.sub(r'(VALUE "CompanyName",\s*")[^"]*(")', r'\1RelayFastVPN\2', s)
    return s
patch("windows/runner/Runner.rc", rc, must=False)

# иконка приложения из логотипа
try:
    from PIL import Image
    img = Image.open("assets/logo.jpg").convert("RGBA")
    side = min(img.size)
    left = (img.width - side) // 2
    top = (img.height - side) // 2
    img = img.crop((left, top, left + side, top + side))
    img.save("windows/runner/resources/app_icon.ico",
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("иконка создана")
except Exception as e:
    print("иконка не создана:", e, file=sys.stderr)
PY
