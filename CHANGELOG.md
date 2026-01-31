# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Feature ideas for future releases

## [3.1.1] - 2026-01-31

### Fixed
- Correct latest version detection when GitHub tags are returned on a single JSON line
- Reduce stale responses from GitHub API by adding cache-busting headers and query params
- Fallback to latest tag when releases/latest appears out of date

## [3.0.0] - 2025-12-30

### Added
- Initial release
- Fresh installation support
- Update functionality
- Migration from community scripts
- Automatic backup and rollback
- Health checks
- System diagnostics (`doctor` command)
- Installation type auto-detection

### Changed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- Improved file permissions (755 instead of 777)
- Proper ownership settings

## [3.1.0] - 2025-12-31

### Added
- Backup metadata file: `/opt/npm-backups/previous/.metadata.json` storing:
  - NPM version, Node.js version, Yarn version
  - OpenResty and Certbot versions
  - OS info, timestamp, installation type
- Web server takeover protection to prevent accidental overwriting of existing nginx/apache setups
- `--takeover-nginx` flag to explicitly allow replacing existing web server configs on dedicated NPM hosts
- Interactive rollback prompt on dependency mismatch:
  - Manual (continue with guidance)
  - Automatic (attempt dependency rollback)
  - Cancel (abort safely)

### Changed
- Rollback now checks backed dependency versions and surfaces mismatches clearly
- Deployment is safer by default when a web server is detected

### Fixed
- Reduced cases where rollback appears successful but dependency drift remains unnoticed

### Security
- Safer-by-default behavior to avoid destructive nginx/apache overwrites without explicit consent


[Unreleased]: https://github.com/BrunoAFK/proxmox-helper-nginx-manager/compare/v3.1.1...HEAD
[3.1.1]: https://github.com/BrunoAFK/proxmox-helper-nginx-manager/compare/v3.1.0...v3.1.1
[3.1.0]: https://github.com/BrunoAFK/proxmox-helper-nginx-manager/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/BrunoAFK/proxmox-helper-nginx-manager/releases/tag/v3.0.0
