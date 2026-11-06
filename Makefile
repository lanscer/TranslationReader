# 全局翻译自动朗读 — 构建入口（文档 §8）
SWIFT ?= swift
APP := $(HOME)/Applications/TranslationReader.app
SCRATCH ?= .build

# 本机只有 CommandLineTools（无 Xcode）。跑测试必须做三件事，实测原因：
#  1) swift package purge-cache：多个 teammate 并发构建会污染 ~/Library/Caches 里的 plugin 解析缓存，
#     症状是随机报 `macro 'Test'/'Suite'/'expect' … plugin for module 'TestingMacros' not found`，
#     purge 之后立刻恢复，不是代码问题。
#  2) 显式 -plugin-path 指向 <工具链>/usr/lib/swift/host/plugins/testing，
#     避免 SwiftPM 生成的编译命令里漏掉 Testing 宏插件。
#  3) 拆成 build --build-tests + test --skip-build：`swift test` 会自己重新生成一套编译命令。
# 插件目录从 xcode-select -p 推导：CLT 下指向 CommandLineTools，装了 Xcode 则自动指向 Xcode。
TOOLCHAIN_DIR := $(shell xcode-select -p)
TEST_PLUGIN_DIR := $(TOOLCHAIN_DIR)/usr/lib/swift/host/plugins/testing
ifeq ($(wildcard $(TEST_PLUGIN_DIR)),)
TEST_PLUGIN_FLAGS :=
else
TEST_PLUGIN_FLAGS := -Xswiftc -plugin-path -Xswiftc $(TEST_PLUGIN_DIR)
endif

.PHONY: build app test clean

build:
	$(SWIFT) build -c release --arch arm64

app:
	./scripts/build-app.sh

test:
	$(SWIFT) package purge-cache
	$(SWIFT) build --build-tests --scratch-path $(SCRATCH) $(TEST_PLUGIN_FLAGS)
	$(SWIFT) test --skip-build --scratch-path $(SCRATCH)

clean:
	rm -rf .build
	rm -rf "$(APP)"
	echo "已清理 .build 与 $(APP)"
