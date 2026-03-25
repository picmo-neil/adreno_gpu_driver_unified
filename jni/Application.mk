# Target both 64-bit and 32-bit ARM
#   arm64-v8a  : all modern Android devices (2016+)
#   armeabi-v7a: older 32-bit devices and fallback
APP_ABI := arm64-v8a armeabi-v7a

# Android 9 (API 28) minimum:
#   - timerfd_create available since API 19 but stable from API 28
#   - signalfd stable from API 21
#   - pidfd_open is a Linux 5.3 kernel feature accessed via syscall;
#     the daemon falls back to /proc poll when pidfd is unavailable
#   - __system_property_get available since Android 2.2
#   - inotify_init1, eventfd available since API 21; stable from API 28
APP_PLATFORM := android-28

# Pure C — no C++ STL overhead
APP_STL := none

# Full optimisation for release
APP_OPTIM := release

# Position-independent executable (mandatory Android 5+)
APP_PIE := true
