LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE        := adreno_ged
LOCAL_SRC_FILES     := src/ged.c

# -O2: optimize for size and speed
# -fPIE: position-independent executable (required on Android 5+)
# -DANDROID: Android-specific code paths
LOCAL_CFLAGS        := -O2 -Wall -Wextra -fPIE -fstack-protector-strong \
                       -D_FORTIFY_SOURCE=2 -DANDROID

# -fPIE -pie: required for Android 5+ executables
# -static-libgcc: no libgcc.so dependency
LOCAL_LDFLAGS       := -fPIE -pie

# No C++ STL needed - pure C
LOCAL_STATIC_LIBRARIES :=
LOCAL_SHARED_LIBRARIES :=

include $(BUILD_EXECUTABLE)
