.PHONY: dmg dmg-intel dmg-all app test run screenshots clean

# Универсальный DMG: Apple Silicon + Intel (только на macOS)
dmg:
	./scripts/build-dmg.sh

# Отдельный DMG только для Intel
dmg-intel:
	./scripts/build-dmg.sh --arch x86_64

# Оба образа
dmg-all: dmg dmg-intel

# Только .app, без образа
app:
	./scripts/build-dmg.sh --app-only

# Тесты оболочки (на macOS)
test:
	cd host && swift test

# Запуск из исходников без сборки DMG (интерфейс берётся из app/Resources)
run:
	cd host && YTLOADER_UI=$(CURDIR)/app/Resources/ui.html swift run YTLoader

# Перерисовать скриншоты для docs/ (нужны python3 и playwright)
screenshots:
	python3 tools/screenshots.py app/Resources/ui.html docs/screenshots

clean:
	rm -rf build dist host/.build
