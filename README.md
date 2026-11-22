# Godot Live Wallpaper

<img width="1920" height="1080" alt="glw" src="https://github.com/user-attachments/assets/8371bf0f-de82-48da-9f43-66eed0ffa720" />


![Godot 4.7](https://img.shields.io/badge/Godot-4.7-478cbf)
![Version 0.5](https://img.shields.io/badge/version-0.5-orange)
![MIT License](https://img.shields.io/badge/license-MIT-green)

A cozy little editor plugin that puts a wallpaper behind the Godot editor (a still image, a sprite sheet, or a shader) and makes the panels see-through so you can actually look at it while you work.

Everything stays inside the editor. Zero runtime code, zero autoloads, and nothing gets shipped with your game.

<img width="3427" height="1340" alt="Screenshot 2026-11-20 144952" src="https://github.com/user-attachments/assets/51721e28-bedd-4d92-846b-e1a94dbf3f06" />


## What It Does

- **Any image as your wallpaper**: Point it at a picture anywhere on your drive (`res://` not required).
- **See-through panels**: Make Scene Tree, FileSystem, Inspector, Output, the top bar, and the Game view see-through, each one optional, with one slider to control how solid they feel.
- **Script editor backdrop**: Use your wallpaper behind your code, pick a solid color, or stick to the default theme. The script list and its filter box have their own see-through slider too.
- **Motion & shaders**: Run still images, sprite sheets, or bundled shader presets (including a Hollow Knight–inspired cavern) at 6–60 FPS, pausing automatically when you tab out of the editor.
- **Custom `.gdshader` files**: Load your own shader and edit it live. Changes show up without restarting anything.
- **Update checker**: Lets you know when a newer version is out and can pull it in for you.

## Requirements

- Godot **4.7** (tested against 4.7.2 stable). On Godot 4.6+ editors with `EditorDock`, you get a **📃 Wallpaper** tab right next to 2D/3D/Script; older versions fall back to a right-hand dock.
- No third-party dependencies or build steps.

## Getting Started

1. Drop `addons/godotLiveWallpaper/` into your project so you have `res://addons/godotLiveWallpaper/plugin.cfg`.
2. Head to **Project → Project Settings → Plugins** and flip **Godot Live Wallpaper** on.
3. Click the **📃 Wallpaper** tab at the top of the editor (or look under **Editor → Editor Docks → 📃 Wallpaper**).

This repo is also the plugin's own project folder, so feel free to open it up directly and tinker.

## Using It

The tab is laid out as a stack of cards from top to bottom.

### Wallpaper

Hit **Browse...** to pick a file, or type a path and press Enter. Both full disk paths (`C:/Pictures/forest.jpg`) and `res://` paths work. Supports PNG, JPG, WebP, BMP, TGA, SVG, EXR, and HDR. **Use the bundled wallpaper** brings back the default image that ships with the plugin.

### Movement

| Mode | What it does |
| --- | --- |
| **Auto detect** | Checks the file: sprite sheets and shaders animate, while still images stay put. |
| **Still image** | Locks to a single frame, even if the source could animate. |
| **Sprite sheet** | Steps through a grid of frames. Set **Columns** and **Rows** to match your sheet. |
| **Shader** | Runs a shader, either a built-in preset or your own `.gdshader`. |

**Speed** sets the frame rate (6–60 FPS, default 24). **Pause while I am not using the editor** freezes animation as soon as the editor loses focus so your machine isn't burning cycles in the background.

Built-in shader presets: **Aurora**, **Flowing gradient**, **Starfield**, and **Synthwave**. To use your own, pick **Shader**, browse to a `.gdshader` file, or copy one of the presets in `addons/godotLiveWallpaper/live/presets/` as a starting point.

### See-through panels

**Make editor panels see-through** is the main toggle. When active, **Solidity** controls how much wallpaper peeks through (0% is completely clear, 100% is solid), and checkboxes let you pick which areas get faded:

- Scene Tree
- FileSystem
- Inspector
- Output
- Top bar and Game view (also covers scene tabs and the top menu row)

Uncheck anything you want to keep solid. Flipping the main switch off brings back the editor's normal panels right away without wiping your wallpaper choice.

### Code editor

**Background** picks what sits behind your scripts: *Use the wallpaper*, *Solid color* (via the color picker), or *Editor default*. **Script list** adjusts how solid the script list and filter box are on their own.

### Updates

**Check now** queries GitHub for the latest release; **Install update** drops the new files in and prompts you to reload (**Project → Reload Current Project**). It also checks quietly shortly after startup and drops a yellow note in **Output** if you're behind.

### When something looks weird

**Developer mode** turns on extra diagnostics: verbose logs in **Output** (what got faded, which container paints the top strip, wallpaper swaps) plus **Inspect panel backgrounds** to dump each dock's styleboxes. Keep it off when you just want a quiet **Output**.

## Settings Reference

Everything lives under `godotLiveWallpaper/` in **Editor → Editor Settings**, so your setup carries across every project you open.

| Key | Default | What it controls |
| --- | --- | --- |
| `wallpaper` | bundled `wallpaper.png` | Path to the active wallpaper file |
| `enabled` | `true` | Master toggle for panel transparency |
| `opacity` | `65` | Panel solidity (0–100) |
| `scene_tree`, `filesystem`, `inspector`, `output`, `main_editor` | `true` | Which editor areas get faded |
| `script_background` | `0` | `0` wallpaper, `1` solid color, `2` editor default |
| `script_color` | dark gray | Color used when `script_background` is `1` |
| `script_list_opacity` | `65` | Solidity of the script list column (0–100) |
| `live_type` | `auto` | `auto`, `image`, `sheet`, `shader` |
| `live_fps` | `24` | Frame rate, 6–60 FPS |
| `live_hframes`, `live_vframes` | `1` | Sprite sheet columns and rows |
| `live_pause_on_blur` | `true` | Pause animation when the editor isn't focused |
| `live_shader_preset` | `aurora` | Last selected shader preset |
| `developer_mode` | `false` | Extra logs and stylebox inspector |

## Troubleshooting

**A panel is still solid.** Make sure its checkbox is ticked and **Solidity** is under 100. Custom editor themes sometimes use bespoke styles, so turn on **Developer mode** and click **Inspect panel backgrounds** to see what each dock is actually using.

**The top bar or scene tabs stay opaque.** Those are drawn by internal editor containers that shift between Godot versions. The plugin matches them by layout geometry rather than node names; with **Developer mode** on, the first fade logs which node it grabbed.

**Nothing is moving.** Double-check **Wallpaper type** (*Auto detect* only animates sprite sheets and shaders). If you're using a sprite sheet, make sure **Columns** and **Rows** match your frame grid.

**Shader compile error.** Check **Output**. Errors print there along with the line number in your `.gdshader` file.

**Easing up on GPU/CPU.** Lower **Speed** to 12–24 FPS, keep *Pause while I am not using the editor* checked, and lean toward still images over shaders on integrated graphics.

### Known Quirks & Limits

- **Video wallpapers (`.ogv`) aren't in yet**: Godot's built-in video playback is limited to Ogg Theora, and files would need to live inside `res://`.
- **Shaders and sprite sheets cost frame time**: big wallpapers or heavy shaders on integrated/older GPUs can eat a noticeable slice of a frame budget.
- **Stylebox re-application every 0.4s**: Godot's editor reapplies its own panel styles periodically, so re-fading every 0.4s can cause a tiny flicker when a dock rebuilds on slower hardware.

## Roadmap

- `.ogv` video wallpaper support with import handling.
- A built-in browser/gallery for wallpapers and presets.
- Tools to create and share wallpapers straight from the editor.

## Uninstalling

Turn the plugin off in **Project Settings → Plugins**, then delete `addons/godotLiveWallpaper/`. Your settings remain under `godotLiveWallpaper/` in **Editor Settings** if you ever reinstall. Delete those keys if you want a clean slate.

## Tip Jar & Support

Godot Live Wallpaper is free, MIT-licensed, and made on nights/weekends. If it brightens up your day in Godot, a tip is always appreciated, never expected.

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-ea4aaa?logo=github&logoColor=white)](https://github.com/sponsors/MAZTN)

**PayPal**: https://paypal.me/dmpoke

<!-- Add or remove the options you actually use, then delete this comment.
- **Ko-fi**: https://ko-fi.com/your-handle
- **Patreon**: https://patreon.com/your-page
- **Bitcoin**: `your-btc-address`
- **Ethereum**: `your-eth-address`
-->

### Other ways to help

- ⭐ Star the repo so other devs stumble across it.
- 🐛 File bug reports with your Godot version and what you were doing when it broke.
- 🎨 Share custom wallpapers, sprite sheets, or `.gdshader` presets.
- 📣 Pass it along to friends staring into a plain gray editor.
- 🎮 Wishlist/support my game [DATACORE HAYWIRE](https://store.steampowered.com/app/4590140/DATACORE_HAYWIRE/) from my team **Rainbow Dye Games**. We have a release coming soon on Steam and wishlists mean a ton.
- 🕹️ Check out my [itch.io](https://maztn.itch.io/) page.

## Credits

- Made by [MAZTN](https://github.com/MAZTN).
- Shoutout to the [Godot](https://godotengine.org/) contributors whose editor theme internals this plugin constantly negotiates with.

## License

[MIT](LICENSE) © 2026 MAZTN

<img width="3427" height="1340" alt="Screenshot 2026-11-20 144952" src="https://github.com/user-attachments/assets/79283d54-8715-4603-b9b9-5070621a8fde" />
