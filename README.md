# Harbor Local Ops Toolkit

This repository keeps your Harbor operational scripts/version-management workflow, while preserving official Harbor offline installer files.

## Entry

Use Makefile as the only user entry:

```bash
make help
```

## Repo Layout

- `Makefile`: unified entry for install/runtime/certs/trust/update/preflight
- `scripts/`: all custom automation scripts (your code)
- Harbor official files in root: `install.sh`, `prepare`, `common.sh`, `harbor.yml.tmpl`, etc.

## Core Commands

Preflight (one-click health check):

```bash
make preflight PREFLIGHT_ARGS="--mode auto --hostname 10.0.0.16"
```

Install/reconfigure (HTTPS self-signed example):

```bash
make install ARGS="--mode self-signed --hostname 10.0.0.16 --https-port 8443 --alt-names DNS:localhost,IP:127.0.0.1" TRUST_CA=1
```

Runtime:

```bash
make up
make down
make status
make logs SERVICE=core
```

Certificate/Trust:

```bash
make cert-status
make cert-renew CERT_ARGS="--hostname 10.0.0.16 --alt-names DNS:localhost,IP:127.0.0.1"
make trust-install
make trust-status
```

## Official Harbor Update Flow

Check update:

```bash
make bundle-check
```

Upgrade to latest (default behavior):

```bash
make bundle-upgrade BUNDLE_ARGS="--version latest"
```

Behavior:
- archive download path: `./artifacts/harbor-bundles/`
- `bundle-upgrade` auto-downloads archive if missing
- `bundle-upgrade` auto-extracts and syncs official bundle files
- temp extract dir is auto-cleaned by default
- archive is kept by default (can add `--clean-archive`)

Examples:

```bash
make bundle-download BUNDLE_ARGS="--version v2.14.2"
make bundle-upgrade BUNDLE_ARGS="--version latest --clean-archive"
make bundle-cleanup
```

## HTTPS Redirect Behavior

When Harbor runs with HTTPS enabled, HTTP port (`8080`) responds with `308` redirect to HTTPS (`8443`).

Validation:

```bash
make redirect-check
```

## Platform Support

- Install/runtime/cert/bundle management scripts: macOS + Linux + Windows (Git-Bash/WSL + Docker Desktop)
- CA trust script (`make trust-*`): macOS, Linux, Windows PowerShell stores

Notes:
- Linux trust install/remove usually needs root/sudo.
- Windows trust uses PowerShell certificate store (default: `CurrentUser\Root`).

## Git Strategy

Track in Git:
- `Makefile`
- `scripts/`
- official static installer files from Harbor package

Do NOT track in Git:
- runtime data: `harbor-data/`
- local certs: `certs/`
- generated runtime config: `harbor.yml`, `docker-compose.yml`, `common/config/`
- offline bundles/download artifacts: `harbor.v*.tar.gz`, `artifacts/`

These are already excluded in `.gitignore`.

## License

Licensed under the AGPLv3. See LICENSE for details.
