# Biscuit
#
# Use these targets rather than calling swift directly: on a machine with only
# the Command Line Tools installed, SwiftUI needs an SDK override that
# Scripts/select-sdk.sh works out. `make build` therefore succeeds where a bare
# `swift build` would fail with "plugin for module 'SwiftUIMacros' not found".
#
# Run `make help` for the full list.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Evaluated once, lazily: empty string when the default SDK is usable.
SDKROOT_OVERRIDE := $(shell Scripts/select-sdk.sh 2>/dev/null)
ifneq ($(SDKROOT_OVERRIDE),)
export SDKROOT := $(SDKROOT_OVERRIDE)
endif

# Der Fallback muss den *leeren* Fall abfangen, nicht nur den Fehlerfall: der
# Exit-Status einer Pipeline ist der des letzten Glieds, und `sed` ist mit
# leerer Eingabe erfolgreich. Ein `|| echo` hinter der Pipe feuert daher nie,
# und VERSION wurde leer an bundle.sh übergeben — was `make app` auf jedem Baum
# ohne Git-Tags abbrechen ließ (Tarball, frischer Klon vor dem ersten Tag).
VERSION ?= $(shell v=$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'); echo "$${v:-0.0.0-dev}")
BUILD   ?= $(shell b=$$(git rev-list --count HEAD 2>/dev/null); echo "$${b:-1}")

.PHONY: help
help: ## Diese Übersicht anzeigen
	@printf '\nBiscuit — verfügbare Ziele:\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;34m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n'
ifneq ($(SDKROOT_OVERRIDE),)
	@printf '  SDK-Override aktiv: \033[1;33m%s\033[0m\n' '$(SDKROOT_OVERRIDE)'
	@printf '  (nur Command Line Tools installiert — siehe Scripts/select-sdk.sh)\n\n'
endif

.PHONY: build
build: ## Beide Binaries bauen (debug)
	swift build

.PHONY: release
release: ## Beide Binaries bauen (release)
	swift build -c release

.PHONY: test
test: ## Testsuite ausführen
	swift test --parallel

.PHONY: app
app: ## dist/Biscuit.app erzeugen
	Scripts/bundle.sh --release --version $(VERSION) --build $(BUILD)

.PHONY: app-wimlib
app-wimlib: ## dist/Biscuit.app mit eingebettetem wimlib erzeugen
	Scripts/bundle.sh --release --version $(VERSION) --build $(BUILD) --vendor-wimlib

.PHONY: install
install: ## Bauen und nach /Programme installieren
	Scripts/install.sh

.PHONY: run
run: app ## App bauen und starten
	open dist/Biscuit.app

.PHONY: icon
icon: ## App-Icon neu erzeugen
	swift Scripts/make-icon.swift Resources

.PHONY: lint
lint: ## Shell- und Python-Skripte prüfen
	@command -v shellcheck >/dev/null 2>&1 \
		|| { echo "shellcheck fehlt. Abhilfe: brew install shellcheck"; exit 1; }
# `style` statt `warning`: die Skripte sind sauber genug dafür, und die einzige
# Ausnahme (SC2012 in package-release.sh) ist dort mit Begründung abgeschaltet.
# Eine Schranke, die nichts mehr findet, ist eine, die auch nichts verhindert.
	shellcheck --severity=style Scripts/*.sh
# Der Katalog-Generator läuft in der CI gegen echte Server; ein Syntaxfehler
# darin fiel bisher erst dort auf.
	@python3 -m py_compile Scripts/*.py && echo "python: ok"

.PHONY: keygen
keygen: ## Ed25519-Release-Schlüssel erzeugen (einmalig)
	Scripts/keygen.sh

.PHONY: package
package: app-wimlib ## Release-Archiv packen und signieren
	Scripts/package-release.sh --version $(VERSION)

.PHONY: clean
clean: ## Build-Artefakte entfernen
	rm -rf .build dist

.PHONY: doctor
doctor: ## Umgebung prüfen
	@printf '\n'
	@printf 'macOS          %s\n' "$$(sw_vers -productVersion)"
	@printf 'Architektur    %s\n' "$$(uname -m)"
	@printf 'Swift          %s\n' "$$(swift --version 2>&1 | head -1)"
	@printf 'Developer-Dir  %s\n' "$$(xcode-select -p)"
	@printf 'Standard-SDK   %s\n' "$$(xcrun --show-sdk-version)"
	@if [ -n '$(SDKROOT_OVERRIDE)' ]; then \
		printf 'SDK-Override   %s\n' '$(SDKROOT_OVERRIDE)'; \
	else \
		printf 'SDK-Override   nicht nötig\n'; \
	fi
	@printf 'wimlib         %s\n' "$$(command -v wimlib-imagex || echo 'nicht gefunden — brew install wimlib')"
	@printf 'openssl (ed25519) '
	@for o in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl; do \
		if [ -x "$$o" ] && "$$o" genpkey -algorithm ED25519 -out /dev/null 2>/dev/null; then \
			printf '%s\n' "$$o"; break; \
		fi; \
	done || printf 'nicht gefunden — brew install openssl@3\n'
	@printf 'shellcheck     %s\n' "$$(command -v shellcheck || echo 'nicht gefunden')"
	@printf '\n'
