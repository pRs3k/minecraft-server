#!/usr/bin/env bash
# Poke Server - client mod sync script (macOS/Linux)
# Same behavior as install-mods.ps1 (the Windows version) - see that file's header
# comment for the full explanation of what this does and why.
#
# Run it with:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.sh)"
#
# To point at a specific Minecraft folder instead of auto-detecting:
#   MC_DIR="/path/to/.minecraft" bash -c "$(curl -fsSL https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.sh)"

set -uo pipefail

MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/pRs3k/minecraft-server/main/mods-manifest.json}"
GAME_VERSION="${GAME_VERSION:-1.21.1}"
MC_DIR="${MC_DIR:-}"

# ---------------------------- small helpers ----------------------------

sha1_of() {
    shasum -a 1 "$1" 2>/dev/null | awk '{print $1}'
}

fabric_mod_json() {
    unzip -p "$1" fabric.mod.json 2>/dev/null
}

have_python3() {
    command -v python3 >/dev/null 2>&1
}

# ------------------------- Minecraft folder detection -------------------------
# Same launchers as the Windows version: the vanilla/official launcher, Prism
# Launcher, MultiMC, and the Modrinth App. There's no official CurseForge app for
# macOS, so that one isn't checked here.

find_minecraft_candidates() {
    local candidates=()

    local vanilla="$HOME/Library/Application Support/minecraft"
    [ -d "$vanilla" ] && candidates+=("$vanilla")

    local roots=(
        "$HOME/Library/Application Support/PrismLauncher/instances"
        "$HOME/Library/Application Support/MultiMC/instances"
        "$HOME/Library/Application Support/ModrinthApp/profiles"
    )
    # Also check the common Linux locations, in case this is run there instead.
    roots+=(
        "$HOME/.local/share/PrismLauncher/instances"
        "$HOME/.local/share/multimc/instances"
        "$HOME/.local/share/ModrinthApp/profiles"
    )
    local linux_vanilla="$HOME/.minecraft"
    [ -d "$linux_vanilla" ] && candidates+=("$linux_vanilla")

    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        for instance in "$root"/*/; do
            [ -d "$instance" ] || continue
            if [ -d "${instance}.minecraft/mods" ]; then
                candidates+=("${instance}.minecraft")
            elif [ -d "${instance}minecraft/mods" ]; then
                candidates+=("${instance}minecraft")
            fi
        done
    done

    # De-duplicate while preserving order.
    local seen=()
    local unique=()
    for c in "${candidates[@]}"; do
        local dup=0
        for s in "${seen[@]:-}"; do
            [ "$s" = "$c" ] && dup=1 && break
        done
        if [ "$dup" -eq 0 ]; then
            seen+=("$c")
            unique+=("$c")
        fi
    done
    printf '%s\n' "${unique[@]}"
}

if [ -z "$MC_DIR" ]; then
    mapfile -t candidates < <(find_minecraft_candidates)
    if [ "${#candidates[@]}" -eq 0 ]; then
        MC_DIR="$HOME/Library/Application Support/minecraft"
        echo "No existing Minecraft installs found - defaulting to $MC_DIR"
    elif [ "${#candidates[@]}" -eq 1 ]; then
        MC_DIR="${candidates[0]}"
    else
        echo "Found more than one Minecraft install on this computer:"
        for i in "${!candidates[@]}"; do
            echo "  [$((i + 1))] ${candidates[$i]}"
        done
        read -r -p "Which one is for the Poke Server? Enter a number: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
            MC_DIR="${candidates[$((choice - 1))]}"
        else
            echo "Didn't recognize that choice. Re-run and try again, or set MC_DIR explicitly." >&2
            exit 1
        fi
    fi
fi

echo "=== Poke Server mod sync ==="
echo "Minecraft folder: $MC_DIR"

MODS_DIR="$MC_DIR/mods"
mkdir -p "$MODS_DIR"
STATE_FILE="$MODS_DIR/.server-mod-sync-state.txt"

echo "Fetching mod list from $MANIFEST_URL ..."
MANIFEST_TMP="$(mktemp)"
if ! curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_TMP"; then
    echo "Could not download the mod manifest. Check your internet connection and try again." >&2
    rm -f "$MANIFEST_TMP"
    exit 1
fi

# ============================= Phase 1: sync =============================
# Our manifest is entirely self-authored (always pretty-printed, one key per
# line), so it's safe to parse with a small state-machine in POSIX awk - no need
# for jq or python here. (This is NOT used for arbitrary third-party fabric.mod.json
# files later in Phase 2, since those aren't guaranteed to be formatted this way.)
parse_manifest() {
    awk '
    /^[[:space:]]*\{/ { infile=1; fname=""; sha1=""; url=""; next }
    /^[[:space:]]*\}/ {
        if (infile) { print fname "\t" sha1 "\t" url }
        infile=0; next
    }
    infile && /"filename"/ {
        line=$0
        sub(/^[[:space:]]*"filename"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/",?[[:space:]]*$/, "", line)
        fname=line
    }
    infile && /"sha1"/ {
        line=$0
        sub(/^[[:space:]]*"sha1"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/",?[[:space:]]*$/, "", line)
        sha1=line
    }
    infile && /"url"/ {
        line=$0
        sub(/^[[:space:]]*"url"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/",?[[:space:]]*$/, "", line)
        if (line != "null") url=line
    }
    ' "$1"
}

declare -A current_filenames
declare -A previously_managed
if [ -f "$STATE_FILE" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && previously_managed["$f"]=1
    done < "$STATE_FILE"
fi

downloaded=0
up_to_date=0
failed=()

while IFS=$'\t' read -r filename sha1 url; do
    [ -z "$filename" ] && continue
    current_filenames["$filename"]=1
    dest="$MODS_DIR/$filename"

    needs_download=1
    if [ -f "$dest" ]; then
        local_hash="$(sha1_of "$dest")"
        if [ "$local_hash" = "$(echo "$sha1" | tr '[:upper:]' '[:lower:]')" ]; then
            needs_download=0
        fi
    fi

    if [ "$needs_download" -eq 0 ]; then
        up_to_date=$((up_to_date + 1))
        continue
    fi

    if [ -z "$url" ]; then
        echo "  [SKIP] $filename - no download URL available, get this one manually."
        failed+=("$filename")
        continue
    fi

    echo "  Downloading $filename ..."
    if curl -fsSL "$url" -o "$dest"; then
        new_hash="$(sha1_of "$dest")"
        if [ "$new_hash" != "$(echo "$sha1" | tr '[:upper:]' '[:lower:]')" ]; then
            echo "  [WARN] $filename downloaded but its hash doesn't match what the server expects."
            failed+=("$filename")
        else
            downloaded=$((downloaded + 1))
        fi
    else
        echo "  [FAIL] Could not download $filename"
        failed+=("$filename")
    fi
done < <(parse_manifest "$MANIFEST_TMP")

removed=0
for f in "${!previously_managed[@]}"; do
    if [ -z "${current_filenames[$f]:-}" ]; then
        old_path="$MODS_DIR/$f"
        if [ -f "$old_path" ]; then
            echo "  Removing outdated mod: $f"
            rm -f "$old_path"
            removed=$((removed + 1))
        fi
    fi
done

: > "$STATE_FILE"
for f in "${!current_filenames[@]}"; do
    echo "$f" >> "$STATE_FILE"
done

echo ""
echo "=== Sync done ==="
echo "Up to date: $up_to_date"
echo "Downloaded: $downloaded"
echo "Removed:    $removed"
if [ "${#failed[@]}" -gt 0 ]; then
    echo "Needs attention: ${failed[*]}"
fi

rm -f "$MANIFEST_TMP"

# =================== Phase 2: dependency conflict check ===================
# This part reads arbitrary third-party mods' fabric.mod.json files, which aren't
# guaranteed to be nicely formatted the way our own manifest is - so this phase
# needs python3's real JSON parser rather than the simple awk approach above.
if ! have_python3; then
    echo ""
    echo "python3 not found - skipping the dependency-conflict check."
    echo "(The mod sync above still completed normally.)"
    exit 0
fi

echo ""
echo "=== Checking for mods broken by this update ==="

python3 - "$MODS_DIR" "$MC_DIR" "$GAME_VERSION" "${!current_filenames[@]}" <<'PYEOF'
import json, os, re, subprocess, sys, tempfile, urllib.request, zipfile

mods_dir = sys.argv[1]
mc_dir = sys.argv[2]
game_version = sys.argv[3]
managed_filenames = set(sys.argv[4:])

def get_fabric_mod_info(path):
    try:
        with zipfile.ZipFile(path) as z:
            with z.open("fabric.mod.json") as f:
                return json.loads(f.read().decode("utf-8"))
    except Exception:
        return None

def to_parts(v):
    core = re.sub(r"\+.*$", "", v)
    prerelease = None
    m = re.match(r"^(.*?)-(.*)$", core)
    if m:
        core, prerelease = m.group(1), m.group(2)
    parts = []
    for p in core.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(p)
    return parts, prerelease

def compare_versions(v1, v2):
    p1, pre1 = to_parts(v1)
    p2, pre2 = to_parts(v2)
    for i in range(max(len(p1), len(p2))):
        a = p1[i] if i < len(p1) else 0
        b = p2[i] if i < len(p2) else 0
        if isinstance(a, int) and isinstance(b, int):
            if a != b:
                return -1 if a < b else 1
        else:
            a, b = str(a), str(b)
            if a != b:
                return -1 if a < b else 1
    if not pre1 and pre2:
        return 1
    if pre1 and not pre2:
        return -1
    if pre1 and pre2:
        return -1 if pre1 < pre2 else (1 if pre1 > pre2 else 0)
    return 0

def test_single_predicate(version, predicate):
    predicate = predicate.strip()
    if predicate in ("*", ""):
        return True
    m = re.match(r"^\^(.+)$", predicate)
    if m:
        base = m.group(1)
        base_parts, _ = to_parts(base)
        major = base_parts[0] if base_parts and isinstance(base_parts[0], int) else 0
        next_major = f"{major + 1}.0.0"
        return compare_versions(version, base) >= 0 and compare_versions(version, next_major) < 0
    m = re.match(r"^~(.+)$", predicate)
    if m:
        base = m.group(1)
        base_parts, _ = to_parts(base)
        major = base_parts[0] if len(base_parts) > 0 and isinstance(base_parts[0], int) else 0
        minor = base_parts[1] if len(base_parts) > 1 and isinstance(base_parts[1], int) else 0
        next_minor = f"{major}.{minor + 1}.0"
        return compare_versions(version, base) >= 0 and compare_versions(version, next_minor) < 0
    m = re.match(r"^(>=|<=|>|<|=)(.+)$", predicate)
    if m:
        op, target = m.group(1), m.group(2).strip()
        cmp = compare_versions(version, target)
        return {">=": cmp >= 0, "<=": cmp <= 0, ">": cmp > 0, "<": cmp < 0, "=": cmp == 0}[op]
    m = re.match(r"^([\d.]*?)\.?[xX*]$", predicate)
    if m:
        prefix = m.group(1).rstrip(".")
        if not prefix:
            return True
        return version == prefix or version.startswith(prefix + ".")
    return compare_versions(version, predicate) == 0

def satisfies(version, range_value):
    if range_value is None:
        return True
    if isinstance(range_value, list):
        return any(satisfies(version, alt) for alt in range_value)
    return all(test_single_predicate(version, p) for p in range_value.split() if p)

# Read every installed jar's fabric.mod.json.
installed_by_id = {}
jar_info_by_file = {}
for name in os.listdir(mods_dir):
    if not name.endswith(".jar"):
        continue
    path = os.path.join(mods_dir, name)
    info = get_fabric_mod_info(path)
    if info and info.get("id") and info.get("version"):
        installed_by_id[info["id"]] = {"version": info["version"], "filename": name}
        jar_info_by_file[name] = info

# --- Fabric Loader version check (can't auto-fix, but we can warn loudly) ---
loader_requirements = []
for name, info in jar_info_by_file.items():
    depends = info.get("depends") or {}
    if "fabricloader" in depends:
        loader_requirements.append((info["id"], depends["fabricloader"]))

def find_installed_loader_version(mc_dir):
    versions_dir = os.path.join(mc_dir, "versions")
    if os.path.isdir(versions_dir):
        for entry in os.listdir(versions_dir):
            m = re.match(r"^fabric-loader-([\d.]+)-", entry)
            if m:
                return m.group(1)
    pack_path = os.path.join(os.path.dirname(mc_dir.rstrip("/")), "mmc-pack.json")
    if os.path.isfile(pack_path):
        try:
            with open(pack_path, encoding="utf-8") as f:
                pack = json.load(f)
            for comp in pack.get("components", []):
                if comp.get("uid") == "net.fabricmc.fabric-loader":
                    return comp.get("version")
        except Exception:
            pass
    return None

if loader_requirements:
    print("")
    detected = find_installed_loader_version(mc_dir)
    unsatisfied = [f"{mod_id} needs Fabric Loader {rng}" for mod_id, rng in loader_requirements
                   if detected and not satisfies(detected, rng)]
    if detected and not unsatisfied:
        print(f"Fabric Loader {detected} detected - satisfies everything installed.")
    elif detected and unsatisfied:
        print(f"[WARNING] Your Fabric Loader ({detected}) is too old for what's installed:")
        for u in unsatisfied:
            print(f"  - {u}")
        print("  Update Fabric Loader through your launcher - e.g. re-run the Fabric installer")
        print("  (https://fabricmc.net/use/installer/) for the vanilla launcher, or change the")
        print("  Fabric Loader component version in your instance's edit screen for Prism/MultiMC.")
    else:
        print("Note: some installed mods require a minimum Fabric Loader version:")
        for mod_id, rng in loader_requirements:
            print(f"  - {mod_id} needs {rng}")
        print("  Couldn't automatically detect your installed Fabric Loader version - if the")
        print("  game fails to launch with a Fabric Loader error, update it through your launcher.")

# --- Cross-mod dependency check (only against mods we manage) ---
managed_ids = {jar_info_by_file[f]["id"] for f in managed_filenames if f in jar_info_by_file}

broken = []
for filename, info in jar_info_by_file.items():
    if filename in managed_filenames:
        continue
    depends = info.get("depends") or {}
    for dep_id, dep_range in depends.items():
        if dep_id in ("minecraft", "fabricloader", "java"):
            continue
        if dep_id not in managed_ids:
            continue
        installed_version = installed_by_id[dep_id]["version"]
        if not satisfies(installed_version, dep_range):
            broken.append({
                "mod_id": info["id"], "filename": filename,
                "requires_id": dep_id, "requires_range": dep_range,
                "installed_dep_version": installed_version,
            })

if not broken:
    print("Nothing else on your system depends on the mods we just updated. All good.")
else:
    for b in broken:
        print("")
        print(f"  [BROKEN] {b['filename']} requires {b['requires_id']} {b['requires_range']}, "
              f"but {b['installed_dep_version']} is now installed.")
        print(f"  Looking for an updated build of {b['mod_id']} on Modrinth ...")

        fixed = False
        try:
            with urllib.request.urlopen(f"https://api.modrinth.com/v2/project/{b['mod_id']}") as r:
                project = json.load(r)
        except Exception:
            project = None

        if project:
            url = (f"https://api.modrinth.com/v2/project/{project['id']}/version"
                   f'?loaders=["fabric"]&game_versions=["{game_version}"]')
            try:
                with urllib.request.urlopen(url) as r:
                    candidates = json.load(r)
            except Exception:
                candidates = []

            for candidate in candidates:
                files = candidate.get("files", [])
                file = next((f for f in files if f.get("primary")), files[0] if files else None)
                if not file:
                    continue
                tmp_path = os.path.join(tempfile.gettempdir(), file["filename"])
                try:
                    urllib.request.urlretrieve(file["url"], tmp_path)
                    candidate_info = get_fabric_mod_info(tmp_path)
                    required_range = None
                    if candidate_info:
                        required_range = (candidate_info.get("depends") or {}).get(b["requires_id"])
                    now_installed_version = installed_by_id[b["requires_id"]]["version"]
                    if required_range is None or satisfies(now_installed_version, required_range):
                        old_path = os.path.join(mods_dir, b["filename"])
                        if os.path.exists(old_path):
                            os.remove(old_path)
                        os.replace(tmp_path, os.path.join(mods_dir, file["filename"]))
                        print(f"  [FIXED] Updated {b['mod_id']} to {candidate['version_number']}, "
                              f"which supports the new {b['requires_id']}.")
                        fixed = True
                        break
                    else:
                        os.remove(tmp_path)
                except Exception:
                    if os.path.exists(tmp_path):
                        os.remove(tmp_path)

        if not fixed:
            print("  Could not find a compatible update automatically. Check manually:")
            print(f"  https://modrinth.com/mod/{b['mod_id']}/versions")

print("")
print("=== Done ===")
PYEOF
