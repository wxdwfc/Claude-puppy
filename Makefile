.PHONY: app run stop list watch build clean

APP := .build/Puppy.app

build:
	swift build

## 组装并签名 .app bundle
app:
	@./scripts/build-app.sh

## 重新构建并启动(先杀掉已在跑的实例)
run: stop app
	@open $(APP)
	@echo "小狗已上桌。右键它可以退出。"

stop:
	@pkill -x Puppy 2>/dev/null || true

## 打印当前 session 表后退出
list: build
	@./.build/debug/Puppy --list

## 持续打印 session 变化
watch: build
	@./.build/debug/Puppy --watch

clean:
	rm -rf .build
