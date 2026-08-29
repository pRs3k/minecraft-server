# Poke Server - Mod Sync

Keeps your Minecraft mods folder in sync with whatever the server currently requires.

## For players

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.ps1 | iex
```

That's it. It checks your `%APPDATA%\.minecraft\mods` folder against the server's current
mod list, downloads anything missing or outdated, and removes old versions of mods it
previously installed (it never touches mods you added yourself that aren't part of the
server's list). Re-run it any time the server's mods change.

## For the admin (updating the mod list)

Whenever you add, remove, or update a mod on the server:

1. Compute the new file's info and update `mods-manifest.json`:
   - `filename` - exact jar filename
   - `sha1` - `(Get-FileHash -Algorithm SHA1 path\to\mod.jar).Hash` (lowercase it)
   - `size` - file size in bytes (informational only)
   - `source` - `"modrinth"` if the mod is on Modrinth (get the direct file URL from
     its Modrinth page), or `"direct"` if you're hosting the jar yourself
   - `url` - the direct download URL. For self-hosted jars, put the file in
     `extra-mods/` in this repo and use:
     `https://raw.githubusercontent.com/pRs3k/minecraft-server/main/extra-mods/<filename>`
2. Commit and push. Players just re-run the one-liner above to catch up - no need to
   send them a new script or a new command.

### Why some mods point to Modrinth and one is self-hosted

Most of these mods are published to both CurseForge and Modrinth as the literal same
file, so their exact server versions were resolved automatically via Modrinth using a
SHA1 hash match. `Beekeeper-1.21-1.0.5.jar` wasn't found on Modrinth (it appears to be
CurseForge-only), so its jar is committed directly into `extra-mods/` in this repo
instead.

Versions are always pinned to an exact hash - the script never grabs "whatever's
newest," since a player running a newer mod version than the server could break
compatibility just as easily as running an older one.
