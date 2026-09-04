# Poke Server - Mod Sync

Fabric installer (needed to play on the server at all): https://fabricmc.net/use/installer/

**Windows** - PowerShell:
```powershell
irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.ps1 | iex
```

**macOS / Linux** - Terminal:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.sh)"
```

## Connecting to the server (Windows)

The server is only reachable over Tailscale. Run this to install Tailscale and sign in:

```powershell
irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/setup-tailscale.ps1 | iex
```

You'll need an invite to the Tailscale network first - ask whoever's hosting the server. Once connected, they'll give you the server address to add in Minecraft.
