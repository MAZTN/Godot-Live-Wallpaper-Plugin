# Godot Live Wallpaper

![Godot 4.7](https://img.shields.io/badge/Godot-4.7-478cbf)
![Version 4.7.2](https://img.shields.io/badge/version-4.7.2-orange)
![MIT License](https://img.shields.io/badge/license-MIT-green)

An editor plugin that puts a wallpaper behind the Godot editor — a picture, a sprite sheet or a full shader — and makes the panels see-through so you can actually look at it.

Everything runs inside the editor. There is no runtime code, no autoload, and nothing is added to your game.

<!-- Screenshot: drop a picture in the repo and uncomment this.
![The Wallpaper tab](docs/screenshot.png)
-->

## Features

- **Wallpaper behind the editor**, from any image file on your computer — `res://` not required.
- **See-through panels**: Scene Tree, FileSystem, Inspector, Output, the top bar and the Game view, each one optional, with one opacity slider for all of them.
- **Script editor background**: use the wallpaper, pick a solid color, or keep the editor default. The script list and its filter box can be see-through on their own.
- **Live wallpapers**: still images, animated sprite sheets, and shader presets (including a Hollow Knight–inspired cavern), at 6–60 FPS, pausing when the editor is unfocused.
- **Your own shaders**: point it at any `.gdshader` and it runs it. Edit the file and the wallpaper follows.
- **Update check**: tells you when a newer version exists, and can install it.

## Requirements

- Godot **4.7** (developed against 4.7.2 stable). On editors with the Godot 4.6+ `EditorDock` system the settings live in a **📃 Wallpaper** tab next to 2D/3D/Script; older editors fall back to a right-hand dock.
- No dependencies, no build step.

## Installation

1. Copy the `addons/godotLiveWallpaper/` folder into your project, so you end up with `res://addons/godotLiveWallpaper/plugin.cfg`.
2. Open **Project → Project Settings → Plugins** and enable **Godot Live Wallpaper**.
3. Click the **📃 Wallpaper** tab at the top of the editor. (Or go to Editor → Editor Docks → 📃Wallpaper)

This repository is also the plugin's own Godot project, so you can open it directly and enable the plugin to try changes.

## Using it

The tab is a few cards, top to bottom.

### Wallpaper

Pick your picture with **Browse...**, or type a path and press Enter. Absolute paths work (`C:/Pictures/forest.jpg`), as do `res://` paths. Formats: PNG, JPG, WebP, BMP, TGA, SVG, EXR, HDR. **Use the bundled wallpaper** goes back to the picture that ships with the plugin.

### Movement

| Wallpaper type | What it does |
| --- | --- |
| **Auto detect** | Looks at the file: sprite sheets and shaders animate, everything else stays still. |
| **Still image** | Always one frame, even if the file could animate. |
| **Sprite sheet** | Plays a grid of frames. Set **Columns** and **Rows**. |
| **Shader** | Runs a shader — a bundled preset or your own `.gdshader`. |

**Speed** is the animation rate in frames per second (6–60, default 24). **Pause while I am not using the editor** stops all animation as soon as the editor loses focus, so an idle editor costs nothing.

Bundled shader presets: **Aurora**, **Flowing gradient**, **Starfield**, **Hollow Knight**. For your own, choose the shader type and browse to a `.gdshader` file — the presets under `addons/godotLiveWallpaper/live/presets/` are good starting points to copy.

### See-through panels

**Make editor panels see-through** is the master switch. While it is on, **Solidity** sets how much wallpaper shows through (0% is fully transparent, 100% hides the wallpaper), and you tick which parts of the editor take part:

- Scene Tree
- FileSystem
- Inspector
- Output
- Top bar and Game view (also covers the scene tabs and menu row)

Untick anything you would rather keep solid. Turning the master switch off restores the editor's own panels immediately; it does not remove your wallpaper.

### Code editor

**Background** sets what sits behind your scripts: *Use the wallpaper*, *Solid color* (pick it with the color button), or *Editor default*. **Script list** separately controls how solid the script list column and its filter box look.

### Updates

**Check now** asks GitHub for the newest version; **Install update** downloads it into the project and then asks you to reload (**Project → Reload Current Project**). The check also runs once shortly after the editor starts, and prints a yellow notice in **Output** when you are behind.

### Something looks off?

**Developer mode** reveals the diagnostics: it enables the plugin's log lines in **Output** (what got faded, which control paints the top strip, wallpaper changes) and the **Inspect panel backgrounds** button, which dumps the styleboxes of every dock. Leave it off for a quiet Output.

## Settings reference

All settings live in **Editor → Editor Settings**, under `godotLiveWallpaper/`, so they are shared by every project you open.

| Key | Default | Meaning |
| --- | --- | --- |
| `wallpaper` | bundled `wallpaper.png` | Path to the current wallpaper file |
| `enabled` | `true` | Master switch for panel transparency |
| `opacity` | `65` | Panel solidity, 0–100 |
| `scene_tree`, `filesystem`, `inspector`, `output`, `main_editor` | `true` | Which areas are faded |
| `script_background` | `0` | `0` wallpaper, `1` solid color, `2` editor default |
| `script_color` | dark gray | Color used by mode `1` |
| `script_list_opacity` | `65` | Solidity of the script list column |
| `live_type` | `auto` | `auto`, `image`, `sheet`, `shader` |
| `live_fps` | `24` | Animation rate, 6–60 |
| `live_hframes`, `live_vframes` | `1` | Sprite sheet columns and rows |
| `live_pause_on_blur` | `true` | Pause animation when the editor is unfocused |
| `live_shader_preset` | `aurora` | Last chosen preset |
| `developer_mode` | `false` | Diagnostics and log output |

## Troubleshooting

**A panel is still solid.** Tick it under *Parts of the editor* and make sure **Solidity** is below 100. Some editor themes paint their backgrounds with custom styles; run **Inspect panel backgrounds** with Developer mode on and the Output will show what each dock is using.

**The top bar or scene tabs stay opaque.** Their background is painted by the editor's own containers, which move between Godot versions. The plugin finds them by shape rather than by name; with Developer mode on, the first fade prints which control it found.

**The wallpaper is not animated.** Check **Wallpaper type** — *Auto detect* only animates sprite sheets and shaders. For a sprite sheet, the **Columns**/**Rows** values must match the grid in the image.

**A shader shows an error.** The message appears in **Output** with the line number in the `.gdshader` file.

**Animate at a lower cost.** Drop **Speed** to 12–24 FPS, keep *Pause while I am not using the editor* on, and prefer a still image over a shader on integrated graphics.

### Known limits

- Video wallpapers (`.ogv`) are **not supported yet** — core Godot only decodes Ogg Theora, and files would have to live in `res://`.
- Shaders and sprite sheets draw on the GPU every frame; a very large wallpaper on a weak GPU can cost a few percent of a frame budget.
- The plugin restores its styleboxes every 0.4 s because the editor re-applies its own panels; a very slow machine may show a brief flicker when the editor rebuilds a panel.

## Roadmap

- Video wallpapers (`.ogv`), with import handling.
- A wallpaper browser/store.
- A way to build and share your own wallpapers from inside the editor.

## Uninstalling

Disable the plugin in **Project Settings → Plugins**, then delete `addons/godotLiveWallpaper/`. Your preferences stay behind under `godotLiveWallpaper/` in Editor Settings; remove those keys if you want a clean slate.

## DONATE

Godot Live Wallpaper is free, MIT-licensed, and built in my spare time. If it made your editor a nicer place to work, a tip is genuinely appreciated — and never required.

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-ea4aaa?logo=github&logoColor=white)](https://github.com/sponsors/MAZTN)

**PayPal** — https://paypal.me/dmpoke

<!-- Add or remove the options you actually use, then delete this comment.
- **Ko-fi** — https://ko-fi.com/your-handle
- **Patreon** — https://patreon.com/your-page
- **Bitcoin** — `your-btc-address`
- **Ethereum** — `your-eth-address`
-->

### Free ways to help, if money is not an option

- ⭐ Star the repository — it is how other people find the plugin.
- 🐛 Report bugs with the editor version and what you were doing when it happened.
- 🎨 Share wallpapers, sprite sheets or shader presets you made.
- 📣 Tell someone who spends too much time staring at a gray editor.
- 🎮 Support my [game](https://store.steampowered.com/app/4590140/DATACORE_HAYWIRE/)(s) with my team Rainbow Dye Games, we currently have a game coming soon on Steam and any wishlists are greatly appreciated.

## Credits

- Built by [MAZTN](https://github.com/MAZTN).
- Thanks to the [Godot](https://godotengine.org/) contributors whose editor theme internals this plugin has to live with.

## License

[MIT](LICENSE) © 2026 MAZTN
