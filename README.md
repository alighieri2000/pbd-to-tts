# ti4bridge — AsyncTI4 → TTS Loader for Twilight's Fall

Loads a live [AsyncTI4](https://asyncti4.com) game state into the
[Twilight Imperium IV TTS mod](https://steamcommunity.com/sharedfiles/filedetails/?id=1288687076)
running the **Twilight's Fall (WIP)** faction pack.

It places units, builds the hex map, sets up player cards, and handles
command tokens — all in one click.

---

## Requirements

| Requirement | Notes |
|---|---|
| Tabletop Simulator | Steam |
| TI4 TTS Mod (Darrell / Milty) | Subscribe on Steam Workshop |
| Twilight's Fall WIP faction pack | Bundled with the mod |
| An active AsyncTI4 PbD game | The loader reads live state from the API |

---

## Installation

1. **Download** `AsyncTI4 Loader (offline pbd24975).json` from this repo.

2. **Copy** it to your TTS Saved Objects folder:
   ```
   C:\Users\<you>\Documents\My Games\Tabletop Simulator\Saves\Saved Objects\
   ```

3. **Done.** The object will appear in TTS under *Objects → Saved Objects*.

---

## Usage — step by step

### 1. Start a Twilight's Fall game

Open the **TI4 TTS Mod** as a custom game in **single player**.

In the mod's built-in setup panel:
- Set the correct **player count**
- Check **"Twilight's Fall WIP"**
- Click **Setup Game**

### 2. Place the loader on the table

If the AsyncTI4 Loader object is not already on the board, drag it out
from *Objects → Saved Objects → AsyncTI4 Loader (offline pbd24975)*.

### 3. Build the hex map

1. Open [asyncti4.com](https://asyncti4.com) and navigate to your game.
2. Find the **map string** (the sequence of tile numbers describing the board layout).
3. Paste the map string into the **Map String** field on the loader.
4. Click **Build Map** — the loader will place tiles using the TI4 Map Tool.

### 4. Remove home system placeholders

Click **Clear Home Slots** on the loader.

This removes the generic home-system tiles the setup tool places, making
room for the Twilight's Fall faction home systems.

### 5. Load the full game state

Click **Setup TF Game**.

The loader will:
- Fetch the current game state from AsyncTI4
- Place units on the correct tiles from the faction supply bags
- Set up player cards, command tokens, and scored objectives

---

## Configuration

To load a different game, edit the game ID on the loader object:

- The **text field at the top** of the loader accepts any AsyncTI4 game name (e.g. `pbd24975`).
- Changing the field takes effect on the next button click.

To hardcode a different default, edit line 43 of `asyncti4_loader_offline.lua`:
```lua
local _gameName = 'pbd24975'
```

---

## Project structure

| File | Purpose |
|---|---|
| `asyncti4_loader_offline.lua` | Main TTS Lua script |
| `AsyncTI4 Loader (offline pbd24975).json` | TTS saved object (drag onto table) |
| `cloudflare-worker.js` | Cloudflare Worker that proxies API requests (deployed) |
| `asyncti4-proxy.ps1` | Legacy local PowerShell proxy (no longer needed) |
| `asyncti4_loader.lua` | Earlier live-fetch prototype (reference only) |

---

## How it works

```
AsyncTI4 API
    │
    ▼
Cloudflare Worker  ←  TTS fetches this (HTTPS, no proxy needed)
    │
    ▼
asyncti4_loader_offline.lua  (runs inside TTS)
    ├── buildMap()        hex tile placement via TI4 Map Tool
    ├── onClearHomeSlots() removes placeholder home systems
    └── handleWebData()
            ├── places unit models from faction supply bags
            ├── places command tokens
            ├── sets up player cards and sheets
            └── handles scored/unscored objectives
```

The Cloudflare Worker (in `cloudflare-worker.js`) re-exports the AsyncTI4
API at a URL TTS can reach directly. TTS cannot negotiate TLS 1.3 with the
real AsyncTI4 endpoint, so all requests go through the Worker.

---

## Troubleshooting

**Units not placed / "nobag" in description**
Unit supply bags may be named differently. Check that the Twilight's Fall
faction colour names match (`Blue Carrier`, `Green Fighter`, etc.) by
hovering over the unit supply row in the player area.

**"tileNumToObject: 0 tiles found" in description**
The hex map hasn't been built yet. Run **Build Map** first, then **Setup TF Game**.

**Map string not copying from asyncti4.com**
Copy the tile-number sequence from the game's info panel. It looks like
`18 25 64 30 ...` — a space-separated list starting from the tile above
Mecatol Rex going clockwise.
