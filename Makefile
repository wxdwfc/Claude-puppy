.PHONY: app run stop list watch build clean skin

APP := .build/Puppy.app

build:
	swift build

## 组装并签名 .app bundle
app:
	@./scripts/build-app.sh

## 重新构建并启动(先杀掉已在跑的实例;顺手重新生成默认的卡通皮肤)
run: stop skin app
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

## 生成卡通侦探皮卡丘皮肤到 ~/.puppy/skins/cartoon(没手动选过形象时的默认)
## 生成失败(比如没装 Pillow)不拦着启动 —— 会自动退回内置像素版
skin:
	@python3 scripts/gen-cartoon.py || echo "卡通皮肤生成失败(需要 Pillow),将退回内置像素版"

clean:
	rm -rf .build
