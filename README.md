A tool for generating store assets for a steam store page, also works for itch, GOG, the Epic Games Store, Google Play and the App Store.

Originally forked from https://github.com/Miziziziz/SteamStoreAssetsCreator with appreciation! I just wanted to tweak some things and it seemed right to keep my version public since I benefited from his.

### How to use:
* Put your artwork inside each asset node under `Screens` — one folder of nodes per storefront
* Delete any storefront you aren't shipping to
* Run the scene

Every image lands in `store_assets/<storefront>/<asset>.png`.

## The tree is the config

`Screens` holds one `StoreFront` per shop, and each `StoreFront` holds the `StoreAsset` nodes it exports:

```
Screens
├── Steam          (StoreFront, store = Steam)     -> store_assets/steam/
│   ├── header_capsule   (StoreAsset, 920x430)     -> header_capsule.png
│   ├── library_hero     (StoreAsset, 3840x1240)   -> library_hero.png
│   └── ...
├── Itch           (StoreFront, store = itch.io)   -> store_assets/itch/
└── ...
```

That structure is the whole configuration — nothing refers to these nodes by name.
Delete a storefront and it simply stops being generated; add one, point it at a
store, and it starts. The same goes for individual assets.

**`StoreAsset`** picks its size from a dropdown of that storefront's assets, so you
never type a number you got from a forum post. Choose `Custom` to set the size by
hand for anything the preset table doesn't cover. In the editor each asset draws a
labelled box showing its extents and pixel size, and the assets auto-arrange side
by side so you can see the whole set at once. None of that drawing exists at
runtime, so it can't leak into an exported image.

**`StoreFront`** names the output folder and tells you, via the usual node warning
triangle, which of that store's required assets you're still missing.

## Sizes

Every size lives in one table, [`store_presets.gd`](store_presets.gd), quoted from
each store's own documentation with the source URL alongside it. Add a store or an
asset there and the dropdowns, folders and generator all pick it up — there is
nothing else to edit.

| Store | Source |
| --- | --- |
| Steam | [store assets](https://partner.steamgames.com/doc/store/assets/standard) and [library assets](https://partner.steamgames.com/doc/store/assets/libraryassets) |
| itch.io | [Your first itch.io page](https://itch.io/docs/creators/getting-started) |
| Epic Games Store | [Storefront Media Guide](https://dev.epicgames.com/docs/epic-games-store/sales-and-marketing/marketing/storefront-media-guide) |
| GOG | [Essentials Checklist](https://docs.gog.com/basic-game-assets/) + [Galaxy artwork sizes](https://support.gog.com/hc/en-us/articles/360003936057) |
| Google Play | [Add preview assets](https://support.google.com/googleplay/android-developer/answer/9866151) |
| App Store | [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/) |

Store requirements drift, so check the link before an actual submission.

Two caveats worth knowing:

* **GOG** doesn't publish its store capsule sizes — partners get templates and an
  Asset Rendering Tool from behind the developer portal. Only the key art minimum
  and the public Galaxy artwork sizes are in the table, so treat GOG as a starting
  point rather than a complete set.
* **itch's page banner** has no official size either. The table uses 960x400, the
  widely used community template size.

Transparency is handled per asset. Where a store forbids an alpha channel (the App
Store icon, Google Play's feature graphic) the generator writes a 24-bit PNG and
warns if anything was actually transparent. Where a store wants a transparent
background (Steam's library logo, Epic's product logo) it warns if the image came
out fully opaque.

## Screenshotter

[`screenshotter.gd`](screenshotter.gd) is a separate, self-contained node for
gathering gameplay screenshots. Add a `Node` anywhere in any scene, attach the
script, play the game, and it writes a PNG every `interval` seconds into
`store_assets/screenshots/`. It captures whichever viewport it sits under, so at the
scene root it grabs the whole window. Set `capture_action` to an input action if you
also want to grab frames on a keypress.

`editor_builds_only` is on by default, so a node left in by accident can't make a
shipped build write files to a player's disk.

## Running it from a script

`godot --path . -- --no-open` generates everything without opening the output
folder afterwards. The process exits non-zero if any asset was skipped or produced
a warning.

## TODO
- GIFs? (Godot has no built-in GIF encoder, so this means a PNG frame sequence plus an external ffmpeg step, or writing an encoder)
- Fill in GOG's real store capsule sizes once someone with developer portal access can read them off the templates
- Per-storefront export toggles for partial runs

https://github.com/user-attachments/assets/0ce44ebb-e61f-493f-a5c7-a12ff15fd9c9
