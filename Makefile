ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1
DEBUG = 0
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = CacheKeeperPrefs
CacheKeeperPrefs_FILES = Prefs/Settings.m Prefs/ScanPage.m Prefs/InspectionPage.m
CacheKeeperPrefs_INSTALL_PATH = /Library/PreferenceBundles
CacheKeeperPrefs_CFLAGS = -fobjc-arc
CacheKeeperPrefs_FRAMEWORKS = UIKit Foundation
CacheKeeperPrefs_PRIVATE_FRAMEWORKS = Preferences
CacheKeeperPrefs_LIBRARIES = roothide
CacheKeeperPrefs_RESOURCE_FILES = Prefs/Info.plist
CacheKeeperPrefs_CODESIGN_FLAGS = -S -Idev.local.cachekeeper.preferences
include $(THEOS_MAKE_PATH)/bundle.mk
TWEAK_NAME = CacheKeeper
CacheKeeper_FILES = Cleaner.m Desktop.xm Permissions.m Scanner.m Baseline.m AxsCacheKeeperNetworkCache.m AxsCacheKeeperDirectories.m AxsCacheKeeperInspection.m
CacheKeeper_CFLAGS = -fobjc-arc -IVendor
CacheKeeper_FRAMEWORKS = UIKit Foundation
CacheKeeper_LIBRARIES = roothide sandy substrate
CacheKeeper_LDFLAGS = -LVendor
CacheKeeper_CODESIGN_FLAGS = -S -Idev.local.cachekeeper
include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = ckrestore
ckrestore_FILES = Restore.m Permissions.m
ckrestore_CFLAGS = -fobjc-arc -DCK_STANDALONE_RESTORE=1
ckrestore_FRAMEWORKS = Foundation
ckrestore_LIBRARIES =
ckrestore_INSTALL_PATH = /usr/bin
ckrestore_CODESIGN_FLAGS = -S -Idev.local.cachekeeper.restore
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	python3 scripts/sync_version.py "$(THEOS_STAGING_DIR)"
