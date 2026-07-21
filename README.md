# Lernstick Debian Live -- Build Environment: Getting Started

> Buildscripts for school-centric Debian Live distributions  
> Repository: https://github.com/Lernstick/lernstickAdvanced  
> Active branch: `debian13` (Debian Trixie)

---

## Prerequisites

### Host system

A Debian or Ubuntu host is required. Install the build dependencies:

```bash
sudo apt install \
  dialog \
  gfxboot \
  libhtml-parser-perl \
  live-build \
  rsync \
  zsync \
  systemd-container
```

### Required by mse_branding.hook.chroot
```bash
sudo apt install \
  imagemagick \
  librsvg2-bin
```

### Required by setup_users.hook.chroot for yescrypt password hashing
```bash
sudo apt install \
   whois
```

Sufficient disk space (or RAM for tmpfs builds):

| Build method | Space required |
|---|---|
| Disk build | ~30–40 GB free on disk |
| tmpfs build | ~50–55 GB free RAM |

---

## 1. Clone the Repository

```bash
git clone --branch debian13 https://github.com/Lernstick/lernstickAdvanced.git
cd lernstickAdvanced
```

To inspect available branches:

```bash
git branch -a
```

