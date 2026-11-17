ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1
DEBUG = 0
include $(THEOS)/makefiles/common.mk
AXS_CACHEKEEPER_PACKAGE_VERSION := $(shell python3 scripts/package_version.py)
ifeq ($(strip $(AXS_CACHEKEEPER_PACKAGE_VERSION)),)
$(error Unable to read a valid package version from control)
endif
BUNDLE_NAME = CacheKeeperPrefs
CacheKeeperPrefs_FILES = Prefs/Settings.m Prefs/SearchInput.m Prefs/ScanPage.m Prefs/InspectionPage.m Prefs/DiagnosticsPage.m AxsCacheKeeperDiagnostics.m AxsCacheKeeperAppList.m AxsCacheKeeperInstallation.m AxsCacheKeeperDiagnosticChannel.m
CacheKeeperPrefs_FILES += Prefs/SearchDiagnostics.m
CacheKeeperPrefs_FILES += AxsCacheKeeperStorageInventory.m AxsCacheKeeperHostEvidence.m
CacheKeeperPrefs_FILES += AxsCacheKeeperOperationInfo.m
CacheKeeperPrefs_FILES += Prefs/SearchHitRouting.m
CacheKeeperPrefs_FILES += AxsCacheKeeperPDFSession.m AxsCacheKeeperPDFInspection.m
CacheKeeperPrefs_INSTALL_PATH = /Library/PreferenceBundles
CacheKeeperPrefs_CFLAGS = -fobjc-arc -DAXS_CACHEKEEPER_PDF_CLIENT=1 -DAXS_CACHEKEEPER_HOST_CLIENT_ONLY=1
CacheKeeperPrefs_FRAMEWORKS = UIKit Foundation
CacheKeeperPrefs_PRIVATE_FRAMEWORKS = Preferences
CacheKeeperPrefs_LIBRARIES = roothide
CacheKeeperPrefs_RESOURCE_FILES = Prefs/Info.plist
CacheKeeperPrefs_CODESIGN_FLAGS = -S -Idev.local.cachekeeper.preferences
include $(THEOS_MAKE_PATH)/bundle.mk
TWEAK_NAME = CacheKeeper
CacheKeeper_FILES = Cleaner.m Desktop.xm Permissions.m Scanner.m Baseline.m AxsCacheKeeperNetworkCache.m AxsCacheKeeperDirectories.m AxsCacheKeeperInspection.m AxsCacheKeeperProcessObservation.m AxsCacheKeeperCleanupJob.m AxsCacheKeeperCleanupRules.m AxsCacheKeeperReceipts.m AxsCacheKeeperCleanupSchedule.m
CacheKeeper_CFLAGS = -fobjc-arc -IVendor -DAXS_CACHEKEEPER_PDF_SERVER=1 -DAXS_CACHEKEEPER_HOST_SERVER_ONLY=1
CacheKeeper_CFLAGS += -DAXS_CACHEKEEPER_PACKAGE_VERSION=\"$(AXS_CACHEKEEPER_PACKAGE_VERSION)\"
CacheKeeper_FILES += AxsCacheKeeperPDFInspection.m AxsCacheKeeperPDFSession.m
CacheKeeper_FILES += AxsCacheKeeperDependencySnapshot.m AxsCacheKeeperInstallation.m AxsCacheKeeperDiagnosticChannel.m
CacheKeeper_FILES += AxsCacheKeeperWebKitCache.m AxsCacheKeeperWebKitObservation.m AxsCacheKeeperWebKitRuntime.xm
CacheKeeper_FILES += AxsCacheKeeperImageCache.m AxsCacheKeeperImageCacheRuntime.m
CacheKeeper_FILES += AxsCacheKeeperOperationInfo.m AxsCacheKeeperHostEvidence.m
CacheKeeper_FILES += AxsCacheKeeperScanTask.m
CacheKeeper_FRAMEWORKS = UIKit Foundation WebKit
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
