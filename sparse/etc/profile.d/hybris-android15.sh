#!/bin/sh
# System-wide hybris library paths for Android 15
# Bootstrap bionic must come before /system/lib64 (broken APEX symlinks)
export HYBRIS_LD_LIBRARY_PATH=/system/lib64/bootstrap:/usr/libexec/droid-hybris/system/lib64:/system/lib64:/vendor/lib64:/system/lib64/vndk-sp:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64
