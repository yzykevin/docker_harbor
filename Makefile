SHELL := /bin/bash
.DEFAULT_GOAL := help

SETUP_SCRIPT := ./scripts/setup_harbor_local.sh
CTL_SCRIPT := ./scripts/harbor_ctl.sh
CERT_SCRIPT := ./scripts/manage_harbor_certs.sh
TRUST_SCRIPT := ./scripts/trust_harbor_ca.sh
BUNDLE_SCRIPT := ./scripts/manage_harbor_bundle.sh
PREFLIGHT_SCRIPT := ./scripts/preflight_check.sh
PUSH_SCRIPT := ./scripts/push_harbor_image.sh
AUTOSTART_SCRIPT := ./scripts/manage_macos_autostart.sh

ARGS ?=
TRUST_CA ?= 0
SERVICE ?=
CERT_ARGS ?=
TRUST_ARGS ?=
BUNDLE_ARGS ?=
PREFLIGHT_ARGS ?=
IMAGE ?=
PROJECT ?=
REGISTRY ?=
REPO ?=
TAG ?=
LOGIN ?= 0
USERNAME ?=

.PHONY: help preflight install up down down-purge restart recover boot status logs cert-ensure cert-renew cert-status trust-install trust-remove trust-status bundle-latest bundle-check bundle-download bundle-extract bundle-upgrade bundle-cleanup redirect-check push autostart-install autostart-remove autostart-status

help:
	@echo "Harbor Project Make Entry"
	@echo
	@echo "Install / Reconfigure:"
	@echo "  make install ARGS=\"--mode self-signed --hostname 10.0.0.16 --https-port 8443\" [TRUST_CA=1]"
	@echo "  make preflight PREFLIGHT_ARGS=\"--mode auto --hostname 10.0.0.16\""
	@echo
	@echo "Runtime:"
	@echo "  make up"
	@echo "  make down"
	@echo "  make down-purge"
	@echo "  make restart"
	@echo "  make recover"
	@echo "  make boot"
	@echo "  make status"
	@echo "  make logs [SERVICE=core]"
	@echo
	@echo "Certificates:"
	@echo "  make cert-ensure CERT_ARGS=\"--hostname 10.0.0.16\""
	@echo "  make cert-renew CERT_ARGS=\"--hostname 10.0.0.16 --alt-names DNS:localhost,IP:127.0.0.1\""
	@echo "  make cert-status"
	@echo
	@echo "CA Trust (macOS/Linux/Windows):"
	@echo "  make trust-install"
	@echo "  make trust-remove"
	@echo "  make trust-status"
	@echo
	@echo "Official Bundle Update:"
	@echo "  make bundle-latest"
	@echo "  make bundle-check"
	@echo "  make bundle-download BUNDLE_ARGS=\"--version latest\""
	@echo "  make bundle-extract BUNDLE_ARGS=\"--version v2.14.2\""
	@echo "  make bundle-upgrade BUNDLE_ARGS=\"--version latest\""
	@echo "  make bundle-cleanup"
	@echo "  (default download dir: ./artifacts/harbor-bundles, upgrade auto-downloads if missing)"
	@echo
	@echo "Validation:"
	@echo "  make redirect-check"
	@echo
	@echo "Image Push:"
	@echo "  make push IMAGE=rocky8:dev PROJECT=ic [REGISTRY=harbor.sostrt.com[:8443]] [REPO=rocky8] [TAG=dev] [LOGIN=1] [USERNAME=<user>]"
	@echo
	@echo "macOS Autostart:"
	@echo "  make autostart-install"
	@echo "  make autostart-remove"
	@echo "  make autostart-status"

preflight:
	@bash $(PREFLIGHT_SCRIPT) $(PREFLIGHT_ARGS)

install:
	@bash $(SETUP_SCRIPT) $(ARGS)
	@if [[ "$(TRUST_CA)" == "1" ]]; then \
		bash $(TRUST_SCRIPT) install; \
	fi

up:
	@bash $(CTL_SCRIPT) up

down:
	@bash $(CTL_SCRIPT) down

down-purge:
	@bash $(CTL_SCRIPT) down --purge

restart:
	@bash $(CTL_SCRIPT) restart

recover:
	@bash $(CTL_SCRIPT) recover

boot:
	@bash $(CTL_SCRIPT) boot

status:
	@bash $(CTL_SCRIPT) status

logs:
	@if [[ -n "$(SERVICE)" ]]; then \
		bash $(CTL_SCRIPT) logs "$(SERVICE)"; \
	else \
		bash $(CTL_SCRIPT) logs; \
	fi

cert-ensure:
	@bash $(CERT_SCRIPT) ensure $(CERT_ARGS)

cert-renew:
	@bash $(CERT_SCRIPT) renew $(CERT_ARGS)

cert-status:
	@bash $(CERT_SCRIPT) status $(CERT_ARGS)

trust-install:
	@bash $(TRUST_SCRIPT) install $(TRUST_ARGS)

trust-remove:
	@bash $(TRUST_SCRIPT) remove $(TRUST_ARGS)

trust-status:
	@bash $(TRUST_SCRIPT) status $(TRUST_ARGS)

bundle-latest:
	@bash $(BUNDLE_SCRIPT) latest $(BUNDLE_ARGS)

bundle-check:
	@bash $(BUNDLE_SCRIPT) check $(BUNDLE_ARGS)

bundle-download:
	@bash $(BUNDLE_SCRIPT) download $(BUNDLE_ARGS)

bundle-extract:
	@bash $(BUNDLE_SCRIPT) extract $(BUNDLE_ARGS)

bundle-upgrade:
	@bash $(BUNDLE_SCRIPT) upgrade $(BUNDLE_ARGS)

bundle-cleanup:
	@bash $(BUNDLE_SCRIPT) cleanup $(BUNDLE_ARGS)

redirect-check:
	@curl -sSI http://127.0.0.1:8080/ | sed -n '1,8p'

push:
	@bash $(PUSH_SCRIPT) \
		--image "$(IMAGE)" \
		--project "$(PROJECT)" \
		$(if $(REGISTRY),--registry "$(REGISTRY)",) \
		$(if $(REPO),--repo "$(REPO)",) \
		$(if $(TAG),--tag "$(TAG)",) \
		$(if $(filter 1 true yes,$(LOGIN)),--login,) \
		$(if $(USERNAME),--username "$(USERNAME)",)

autostart-install:
	@bash $(AUTOSTART_SCRIPT) install

autostart-remove:
	@bash $(AUTOSTART_SCRIPT) remove

autostart-status:
	@bash $(AUTOSTART_SCRIPT) status
