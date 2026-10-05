TARGET := iphone:clang:latest:15.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := CamHook

CamHook_FILES := Tweak.x
CamHook_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo UIKit
CamHook_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk