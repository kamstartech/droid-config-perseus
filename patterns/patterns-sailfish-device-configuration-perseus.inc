# Feel free to disable non-critical HA parts during devel by commenting lines out
# Generated in hadk by executing: rpm/dhd/helpers/add_new_device.sh

%package -n patterns-sailfish-device-configuration-perseus
Summary: Jolla Configuration perseus
Requires: patterns-sailfish-device-configuration-common-perseus
Requires: patterns-sailfish-device-adaptation-perseus

# For devices with cellular modem. Those without one, please comment out:
Requires: patterns-sailfish-cellular-apps

# Early stages of porting benefit from these:
Requires: patterns-sailfish-device-tools

Requires: sailfish-content-graphics-z%{icon_res}

# For multi-SIM devices
#Requires: jolla-settings-networking-multisim

# For devices which support NFC
#Requires: jolla-settings-system-nfc
#Requires: nfcd-dbuslog-plugin
#Requires: nfcd-mce-plugin

# Introduced starting Sailfish OS 2.0.4.x:
# 3rd party accounts like Twitter, VK, cloud services, etc
Requires: jolla-settings-accounts-extensions-3rd-party-all

# Introduced starting Sailfish OS 2.1.1.26
# Required for Jolla Store Access
Requires: patterns-sailfish-consumer-generic

# For Mozilla location services (online)
Requires: geoclue-provider-mlsdb

# Devices with 2G or more memory should also include this booster
# to improve camera startup times and the like
#Requires: mapplauncherd-booster-silica-qt5-media

# harbour-containers: LXC container manager (Kali/Debian + Xfce4/i3 via Xwayland).
# Sourced from the local adaptation-community-perseus repo, not SailfishOS:Chum
# (TRD-041): this project carries its own patched fork with extensive changes
# (see hybris/mw/harbour-containers commit history) that only exist in our
# local build, not upstream's Chum-published package. The ssu
# features.d/sailfishos-chum.ini feature that used to pull in Chum's repo for
# this dependency was removed entirely -- it was also the source of a
# recurring 404 (Chum has no literal "latest" directory, only versioned ones)
# that kept reappearing in generated kickstarts no matter how many times the
# top-level .ks was hand-patched, since ssuks regenerates it fresh from this
# feature on every droid-config-perseus rebuild.
Requires: harbour-containers

%description -n patterns-sailfish-device-configuration-perseus
Pattern with packages for perseus configurations

%files -n patterns-sailfish-device-configuration-perseus
