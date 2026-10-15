CC      = clang
CFLAGS  = -O2 -Wall -Wextra
LDFLAGS = -framework IOKit -framework CoreFoundation

all: app

# 单独编译命令行版后台服务（调试用）
batteryd: main.c smc.c smc.h
	$(CC) $(CFLAGS) -o $@ main.c smc.c $(LDFLAGS)

# 生成 app/build/BatteryCycle.app（已包含后台服务）
app:
	./app/build-app.sh

# 复制到“应用程序”并打开，在菜单栏面板里点“安装后台服务”
install: app
	rm -rf /Applications/BatteryCycle.app
	cp -R app/build/BatteryCycle.app /Applications/
	open /Applications/BatteryCycle.app

uninstall:
	-osascript -e 'quit app "BatteryCycle"'
	sudo ./uninstall.sh
	rm -rf /Applications/BatteryCycle.app

icon:
	python3 scripts/make_icon.py

clean:
	rm -rf batteryd app/build app/.build

.PHONY: all app install uninstall icon clean
