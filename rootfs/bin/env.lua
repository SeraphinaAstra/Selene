-- /bin/env.lua
print("SHELL=nyx")
print("PWD=" .. (_cwd or "/"))
print("ARCH=riscv64")
print("NYX_VERSION=" .. (nyx and nyx.version or "0.5-dev"))