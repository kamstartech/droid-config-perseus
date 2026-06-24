# Feel free to disable non-critical HA parts during devel by commenting lines out
# Generated in hadk by executing: rpm/dhd/helpers/add_new_device.sh

%package -n patterns-sailfish-device-adaptation-perseus
Summary: Jolla HW Adaptation perseus
Requires: droid-hal-perseus
Requires: droid-hal-perseus-img-boot
Requires: droid-hal-perseus-kernel-modules
Requires: droid-config-perseus-sailfish
Requires: droid-config-perseus-pulseaudio-settings
Requires: droid-config-perseus-policy-settings
Requires: droid-config-perseus-preinit-plugin
Requires: droid-config-perseus-flashing
Requires: droid-config-perseus-bluez5
Requires: droid-hal-version-perseus

# Hybris libraries (explicit subpackages per upstream template)
Requires: libhybris-libEGL
Requires: libhybris-libGLESv2
Requires: libhybris-libwayland-egl

# HWComposer display path + Qt scene graph adaptation
Requires: qt5-qpa-hwcomposer-plugin
Requires: qtscenegraph-adaptation

# This is needed for notification LEDs + DPMS
Requires: mce-plugin-libhybris

# Sensors
Requires: hybris-libsensorfw-qt5-binder

# Vibra
Requires: ngfd-plugin-native-vibrator
Requires: libngf-qt5-qtfeedback

# Needed for /dev/touchscreen symlink
Requires: qt5-plugin-generic-evdev

Requires: pulseaudio-modules-droid
Requires: pulseaudio-modules-droid-hidl

# Cellular/RIL: ofono binder plugin talks to qcrild via libgbinder
# ofono-ril-binder-plugin <= android 10, ofono-binder-plugin >= android 10
Requires: ofono-binder-plugin

# The -dummy-af is needed for newer devices that run the main
# audiosystem-passthrough in qti mode (e.g. >=Android 9 Qualcomm),
# to fix non-responding Camera app and/or voice during a phone call:
Requires: audiosystem-passthrough-dummy-af

# for audio recording to work:
Requires: qt5-qtmultimedia-plugin-mediaservice-gstmediacapture

# Qt platform plugins for hwcomposer display path
Requires: qt5-qtwayland-wayland_egl

# For hybris devices with droidmedia, see HADK pdf for more information
Requires: gstreamer1.0-droid
Requires: gmp-droid

# USB mode controller
Requires: usb-moded

# hammerhead, grouper, and maguro use this in scripts, so include for all
Requires: rfkill

# Bluetooth HIDL bridge for Android 8+ Qualcomm (SDM845)
Requires: bluebinder

# enable device lock and allow to select untrusted software
Requires: jolla-devicelock-daemon-encsfa

# Enable home encryption
#Requires: sailfish-device-encryption

# For GPS
Requires: geoclue-provider-hybris-binder

# For FM radio on some QCOM devices
#Requires: qt5-qtmultimedia-plugin-mediaservice-irisradio
#Requires: jolla-mediaplayer-radio

# NFC support
# 1. binder plugin requires Android 8 or a newer base
# 2. pn54x plugin talks directly to pn54x driver
# These plugins are mutually exclusive, you need to pick one:
#Requires: nfcd-binder-plugin
#Requires: nfcd-pn54x-plugin

%description -n patterns-sailfish-device-adaptation-perseus
Pattern with packages for perseus HW Adaptation

%files -n patterns-sailfish-device-adaptation-perseus
