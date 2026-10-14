.PHONY: dmg app screenshots clean

# Собрать YTLoader.app и dist/YTLoader-<версия>.dmg (только на macOS)
dmg:
	./scripts/build-dmg.sh

# Только .app, без образа
app:
	./scripts/build-dmg.sh --app-only

# Перерисовать скриншоты для docs/ (нужны python3 и playwright)
screenshots:
	python3 tools/screenshots.py app/Resources/ui.html docs/screenshots

clean:
	rm -rf build dist
