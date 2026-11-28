ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide
FINALPACKAGE = 1
DEBUG = 0
include $(THEOS)/makefiles/common.mk

TOOL_NAME = ckdiagnose
CK_DIAGNOSE_VERSION ?= 1
CK_DIAGNOSE_SOURCE ?= unrecorded
ckdiagnose_FILES = main.m AxsCacheKeeperStandaloneDiagnostics.m ../../AxsCacheKeeperCapacityService.m ../../AxsCacheKeeperCapacity.m ../../AxsCacheKeeperScanTask.m ../../AxsCacheKeeperDirectories.m ../../AxsCacheKeeperInstallation.m ../../AxsCacheKeeperHostEvidence.m ../../AxsCacheKeeperOperationInfo.m
ckdiagnose_CFLAGS = -fobjc-arc -fblocks -I../.. -DAXS_CACHEKEEPER_HOST_CLIENT_ONLY=1 -DAXS_CACHEKEEPER_HOST_SERVER_ONLY=1
ckdiagnose_CFLAGS += -DAXS_CACHEKEEPER_DIAGNOSE_VERSION=\"$(CK_DIAGNOSE_VERSION)\"
ckdiagnose_CFLAGS += -DAXS_CACHEKEEPER_DIAGNOSE_SOURCE=\"$(CK_DIAGNOSE_SOURCE)\"
ckdiagnose_FRAMEWORKS = Foundation
ckdiagnose_LIBRARIES = roothide
ckdiagnose_CODESIGN_FLAGS = -Sentitlements.plist -Idev.local.cachekeeper.diagnose
ckdiagnose_INSTALL_PATH = /usr/bin
include $(THEOS_MAKE_PATH)/tool.mk
