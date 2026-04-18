# These and other macros are documented in ../droid-configs-device/droid-configs.inc
# Feel free to cleanup this file by removing comments, once you have memorised them ;)

%define device perseus
%define vendor xiaomi

%define vendor_pretty Xiaomi
%define device_pretty Mix 3

# Community HW adaptations need this
%define community_adaptation 1

# Pixel ratio 1.0 was originally jolla phone with 245ppi, and the devices
# should roughly have their ppi compared to that. Large displays can use
# bigger ratio if seen fit. Values are with 0.25 increments.
# Mi Mix 3: 403 PPI / 245 PPI ≈ 1.64 → nearest 0.25 increment = 1.5
%define pixel_ratio 1.5

%include droid-configs-device/droid-configs.inc
%include patterns/patterns-sailfish-device-adaptation-perseus.inc
%include patterns/patterns-sailfish-device-configuration-perseus.inc

# IMPORTANT if you want to comment out any macros in your .spec, delete the %
# sign, otherwise they will remain defined! E.g.:
#define some_macro "I'll not be defined because I don't have % in front"

