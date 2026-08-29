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

After syncing, it also checks whether any of your *other* mods (things you installed
yourself, like audio/visual enhancers) have a hard dependency on one of the mods it just
updated - e.g. a mod that requires a specific version of a shared library we changed. It
only acts if that dependency is now genuinely unmet (the kind of thing that stops
Minecraft from booting at all, not just a suggestion or a soft warning). If it finds one,
it looks for an updated build of *your* mod that's actually compatible - verified by
reading that build's own declared dependencies, not just assumed - and swaps it in. If it
can't find a compatible build automatically, it tells you exactly which mod is affected
and links you to check manually.

**Known limitations of this check:**
- It matches your mod to a Modrinth project using its Fabric mod ID as the project slug.
  This works for most mods but isn't guaranteed - some mods use a different slug than
  their mod ID, in which case you'll just get the "check manually" message instead of an
  automatic fix.
- It only checks hard `depends` relationships (the ones that actually prevent booting),
  not `recommends`/`suggests`/`conflicts` (soft) or `breaks` (a different, rarer
  mechanism this doesn't currently check).
- It only checks dependencies on mods *this script* manages - it doesn't try to resolve
  conflicts between two of your own unrelated mods, since we have no control over those
  either way.

### Finding your Minecraft folder

The script checks the vanilla/official launcher's folder plus Prism Launcher, MultiMC,
the CurseForge app, and the Modrinth App - whichever of those you have installed.

- If it finds exactly one, it uses that automatically.
- If it finds more than one (e.g. you have both the vanilla launcher and Prism
  installed), it lists them and asks you to pick.
- If you use a launcher it doesn't recognize, or want to point it at a specific
  instance directly, pass it explicitly - this also works through the one-liner:

```powershell
& ([ScriptBlock]::Create((irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.ps1))) -MinecraftDir "C:\path\to\your\.minecraft"
```

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

### Why the manifest doesn't include every mod in the server's `mods/` folder

Not everything running on the server needs to be installed on a client to connect and
play - a lot of it is server-only tooling (world generation, chunk pregeneration,
dimension/claim management) that never touches anything the client renders or syncs.

This list was trimmed down to exactly what a verified, already-working client actually
has installed - confirmed by comparing a real client's mods folder against the
server's. The following are deliberately left out because that working client doesn't
have them and connects fine:

`Chunky`, `Explorify`, `ForgeConfigAPIPort`, `MoreBeeInfo`, `Structory`, `Anvian's Lib`,
`Collective`, `Cristel Lib`, `CustomDimensions`, `Neo Bee Fix`,
`Open Parties and Claims`, `Realistic Bees`, `Towns and Towers`

If the server ever starts requiring one of these client-side too (e.g. a future update
changes that), add it back into `mods-manifest.json` the same way as any other mod.
