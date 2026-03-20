LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE     := adreno_ged
LOCAL_SRC_FILES  := src/ged.c

# Compiler flags:
#   -O2                    size + speed optimisation
#   -fPIE                  position-independent executable (required Android 5+)
#   -fstack-protector-strong  stack smashing protection
#   -D_FORTIFY_SOURCE=2    glibc/bionic buffer-overflow detection
#   -DANDROID              enable Android-specific code paths in ged.c
LOCAL_CFLAGS := \
    -O2 \
    -Wall \
    -Wextra \
    -Wno-unused-parameter \
    -fPIE \
    -fstack-protector-strong \
    -D_FORTIFY_SOURCE=2 \
    -DANDROID

# Linker flags:
#   -fPIE -pie   position-independent executable
LOCAL_LDFLAGS := -fPIE -pie

# Pure C daemon — no C++ STL, no extra shared libs.
# __system_property_get lives in libc which is always linked.
LOCAL_STATIC_LIBRARIES :=
LOCAL_SHARED_LIBRARIES :=

include $(BUILD_EXECUTABLE)
