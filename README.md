# Colab-Cloud-Gaming (Enhanced)

Run Steam and Play Games on Google Colab — with full desktop environment.

Based on [ymfuy2fuzxrlbxbyzxnhcmlhbg14-coder/testlab](https://github.com/ymfuy2fuzxrlbxbyzxnhcmlhbg14-coder/testlab).

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ymfuy2fuzxrlbxbyzxnhcmlhbg14-coder/testlab/blob/main/ColabSteam.ipynb)

## What's included

| Component | Details |
|-----------|---------|
| **Desktop** | XFCE4 (lightweight, stable for streaming) |
| **Browsers** | Google Chrome, Brave |
| **Streaming** | Sunshine + Moonlight via Tailscale |
| **Gaming** | Steam (via ColabSteam binary) |
| **Audio** | PulseAudio |
| **Tools** | htop, neofetch, nano, vim, curl, wget, unzip, 7z, net-tools |

## Quick start

The notebook handles everything. Just run the cells in order:

1. *(Optional)* Audio cell to prevent Colab idle disconnect
2. Region check
3. Main cell — toggles for Drive mount and desktop environment

Or manually:

```bash
wget -q https://github.com/ymfuy2fuzxrlbxbyzxnhcmlhbg14-coder/testlab/raw/refs/heads/main/setup-env.sh
chmod +x setup-env.sh && ./setup-env.sh

wget -q https://github.com/ymfuy2fuzxrlbxbyzxnhcmlhbg14-coder/testlab/raw/refs/heads/main/ColabSteam
chmod +x ColabSteam && ./ColabSteam
```

## setup-env.sh features

- Auto-detects Ubuntu version (`lsb_release` / `/etc/os-release`)
- Validates against known Colab versions (20.04 focal, 22.04 jammy, 24.04 noble)
- Installs XFCE4 desktop + panel + terminal + file manager
- Chrome via official `.deb`, Brave via official apt repo
- PulseAudio for audio streaming
- GPU detection via `nvidia-smi`
- Colored output with progress steps

## Requirements (client side)

- [Tailscale](https://tailscale.com/) — VPN mesh to reach the Colab instance
- [Moonlight](https://moonlight-stream.org/) — game streaming client
- Sunshine web UI: `https://<tailscale-ip>:47990`

## Notes

- Control support in Moonlight OK (virtual gamepad and gamepad not available)
- Drive mount is optional (toggle in notebook)
- Backup saves session files to Drive, reducing next setup time by 50–75%
- 4-hour play time resets every 24 hours; disconnect when not in use
- Keep the Colab tab visible to avoid disconnection
- If any error occurs, re-run the script
