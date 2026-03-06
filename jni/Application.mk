# Target both 64-bit and 32-bit ARM
# arm64-v8a: all modern Android devices (2015+)
# armeabi-v7a: older 32-bit devices and fallback
APP_ABI := arm64-v8a armeabi-v7a

# Android 9 (API 28) minimum — supports pidfd via syscall on kernel 5.3+
# inotify works on all kernels back to 4.4
# signalfd available since API 21
APP_PLATFORM := android-28

# No STL needed — pure C
APP_STL := none

# Optimize for size
APP_OPTIM := release

# Enable PIE
APP_PIE := true
