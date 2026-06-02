# Documentation

Documentation for **postgres-backup-telegram** — automated PostgreSQL backups in
Docker with rotating retention, Telegram delivery, GPG encryption, webhooks, and
built-in restore tooling.

New here? Start with **[Getting Started](GETTING_STARTED.md)**.

## Guides

| Doc | What's in it |
|---|---|
| [Getting Started](GETTING_STARTED.md) | Zero-to-restorable-backup walkthrough, troubleshooting |
| [Configuration Reference](CONFIGURATION.md) | Every environment variable, Docker secrets, retention math |
| [CLI Commands](CLI.md) | `backup`, `restore`, `list`, `status`, `help` with example output |
| [Architecture](ARCHITECTURE.md) | Runtime chain, backup cycle, rotation model, format branches, Telegram delivery (C4 + mermaid) |
| [Large Files](LARGE_FILES.md) | MTProto upload for backups over 50 MB (up to 2 GB) |
| [Build](BUILD.md) | Multi-arch image builds with QEMU + buildx |

## Project files

| File | Purpose |
|---|---|
| [../README.md](../README.md) | Project overview and quick start |
| [../CHANGELOG.md](../CHANGELOG.md) | Notable changes (Keep a Changelog) |
| [../CLAUDE.md](../CLAUDE.md) | Contributor guide: runtime architecture, build system, testing, conventions |
| [../llms.txt](../llms.txt) | Machine-readable project map for AI agents |
