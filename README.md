# Nginx Proxy Manager - Universal Management Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub release](https://img.shields.io/github/release/BrunoAFK/proxmox-helper-nginx-manager.svg)](https://github.com/BrunoAFK/proxmox-helper-nginx-manager/releases)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/BrunoAFK/proxmox-helper-nginx-manager/graphs/commit-activity)

A powerful bash script for installing, updating, and managing Nginx Proxy Manager on Debian/Ubuntu systems. Supports migration from community script installations with automatic data preservation.

## ✨ Features

- 🚀 Fresh installation or update to any version
- 🔄 Automatic migration from old installations
- 💾 Smart backup and rollback system (with metadata tracking)
- 🔍 Installation type auto-detection
- 🛡️ Safe updates with health checks
- 🧰 Interactive rollback handling for dependency mismatches
- 🛑 Web server takeover protection (requires explicit override)
- 📊 Built-in diagnostics tool

## 🎯 Quick Start

### Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) install
```

### Update
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update
```

### Migrate from Community Script
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) migrate
```

### ⚠️ Dedicated Server Warning
By default, the script will abort if it detects an existing web server configuration to avoid destructive overwrites.
If you're installing NPM on a dedicated host and want the script to take over nginx/OpenResty configuration, use:

## 📋 Commands

| Command | Description |
|---------|-------------|
| `install` | Fresh installation of NPM |
| `update` | Update to latest or specific version |
| `migrate` | Migrate from old installation (preserves data) |
| `rollback` | Restore previous version from backup |
| `uninstall` | Remove NPM (keeps `/data` by default) |
| `status` | Show service status |
| `logs` | Follow NPM backend logs |
| `nginx-logs` | Follow OpenResty logs |
| `install-log` | Show installer log (last 200 lines) |
| `install-logs` | Follow installer log in real-time |
| `doctor` | System diagnostics and health check |

## ⚙️ Options

| Option | Description |
|--------|-------------|
| `--check-only` | Check for updates without installing |
| `--force` | Force reinstall even if up-to-date |
| `--no-backup` | Skip backup (faster, no rollback) |
| `--keep-data` | Keep current data on rollback |
| `--target <ver>` | Install specific version (e.g., `2.13.5` or `latest`) |
| `--node <major>` | Specify Node.js major version (default: 22) |
| `--takeover-nginx` | Allow replacing existing nginx/apache configuration (dedicated NPM hosts only) |
| `--debug` | Enable verbose logging |

## 📚 Usage Examples

### Check for updates
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update --check-only
```

### Install specific version
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update --target 2.13.5
```

### Force reinstall
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update --force
```

### Update without backup (faster)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update --no-backup
```

### Rollback to previous version
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) rollback
```

### System diagnostics
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) doctor
```

### View logs
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) logs
```

## 🔧 Configuration

The script uses configurable defaults at the top of the file:

```bash
NPM_VERSION_DEFAULT="2.13.5"      # Target NPM version (or "latest")
NODE_MAJOR_DEFAULT="22"            # Node.js major version
YARN_VERSION_DEFAULT="1.22.22"    # Yarn version
```

You can override these at runtime:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update --target latest --node 22
```

## 📁 Directory Structure

| Path | Description |
|------|-------------|
| `/app` | Application runtime (backend + frontend) |
| `/data` | Configuration, database & SSL certificates |
| `/opt/npm-backups/previous` | Rollback backup location |
| `/var/log/npm-manager.log` | Installation and update logs |

## 🌐 Access

After installation, access the admin panel at:

```
http://YOUR_SERVER_IP:81
```

**Default credentials:**
- Email: `admin@example.com`
- Password: `changeme`

⚠️ **Change these immediately after first login!**

## 📦 Requirements

- **OS:** Debian 12+ or Ubuntu 22.04+ (systemd required)
- **Privileges:** Root access
- **Network:** Internet connection for downloads

## 🔄 Migration Support

The script automatically detects and migrates from:
- Community script installations (old pnpm-based)
- Community script installations (new /opt/nginxproxymanager)
- Previous versions installed by this script

All data in `/data` is preserved during migration.

## 🛡️ Safety Features

- **Automatic backups** before updates (now includes dependency metadata)
- **Health checks** after deployment
- **Automatic rollback** on failures
- **Interactive rollback** when Node/Yarn mismatch is detected
- **Web server takeover protection** to prevent accidental nginx/apache replacement
- **Lock file** prevents concurrent runs
- **Full logging** to `/var/log/npm-manager.log`

## 🐛 Troubleshooting

### Check system status
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) doctor
```

### View installation logs
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) install-log
```

### Check service status
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) status
```

### Follow live logs
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) logs
```

### Services not starting?
```bash
# Check NPM service
systemctl status npm.service

# Check OpenResty service
systemctl status openresty.service

# View detailed logs
journalctl -u npm.service -n 50
```

### Update failed?
The script automatically rolls back on failure. If manual rollback is needed:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) rollback
```

## 🔐 GitHub API Rate Limits

To avoid GitHub API rate limits, set a personal access token:

```bash
export GITHUB_TOKEN="your_github_token_here"
bash <(curl -fsSL https://raw.githubusercontent.com/BrunoAFK/proxmox-helper-nginx-manager/main/helper.sh) update
```

## 📝 License

MIT License - See repository for details

## 👤 Author

**Bruno Pavelja**
- 🌐 Website: [pavelja.com](https://pavelja.com)
- 💼 LinkedIn: [brunopavelja](https://www.linkedin.com/in/brunopavelja/)
- 📧 Email: [hello@pavelja.me](mailto:hello@pavelja.me)
- 🐙 GitHub: [@BrunoAFK](https://github.com/BrunoAFK)

## 🙏 Credits

- Original NPM: [NginxProxyManager/nginx-proxy-manager](https://github.com/NginxProxyManager/nginx-proxy-manager)
- Inspired by: [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)

## 🆘 Support

For issues and questions:
- Check logs: `/var/log/npm-manager.log`
- Run diagnostics: `./helper.sh doctor`
- Open an issue on GitHub
