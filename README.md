# xModelGen (Flutter)

Generate [xLights](https://xlights.org/) custom models from a drawing of hole/LED
positions. Open a **DXF** or **SVG**, detect the holes of a given diameter, wire
them into a pixel order, and export an `.xmodel` file.

This is the cross-platform (web + Windows desktop) Flutter port of the Qt/C++ app
[**xModelGenQT**](https://github.com/computergeek1507/xModelGenQT).

## 🌐 Live demo

**https://computergeek1507.github.io/xmodelgen_flutter/** — runs entirely in the
browser; nothing is uploaded.

## Features

- **Import DXF or SVG** — circles (and DXF arcs / polyline loops) matching the
  target *Hole Ø* become nodes. Block/group `transform`s are expanded, and units
  are converted to millimetres (DXF `$INSUNITS`; SVG `width` + `viewBox`).
- **Open an image** (PNG/JPEG) as a backdrop, then place nodes on it by hand in
  *Add node* mode (click to drop a node, click a node to remove it), or
  **Detect bright** / **Detect dark** to auto-place a node on each light/dark spot.
- **Auto-wire** with a selectable method:
  - **Nearest-first** — tidiest, shortest-hop wiring.
  - **Warnsdorff** — completes reliably from almost any start node.
- **Manual wire** — click or drag across nodes to wire them by hand.
- **Unwire** — hover a node and press **Delete**/**Backspace**, or **Ctrl-click**
  / **Ctrl-drag** across nodes, to remove them from the wire run (the remaining
  numbers close up so the run stays continuous).
- **Select section** — rubber-band a box (or click nodes) to pick a group, then
  **Wire Section** auto-wires just that group. Numbering continues from the
  highest existing wire number, so manual picks and wired sections chain into one
  continuous run.
- **Export** an xLights `.xmodel` file.

## Usage

1. **Open DXF**/**Open SVG** and set the **Hole Ø** (mm) to detect holes, or
   **Open Image** and place nodes yourself (*Add node* mode / **Detect bright** /
   **Detect dark**).
2. Pick a **Mode**:
   - *Pick start* → click a node, set the **Wire gap**, choose a **Method**, and
     hit **Auto Wire**.
   - *Manual wire* → click/drag nodes in the order you want them wired.
   - *Select section* → select a group and hit **Wire Section**.
   - *Add node* → click on the image to place nodes; click a node to remove it.
   - *Lasso erase* → draw a freeform loop around nodes to delete them.
   - To unwire: hover + **Delete**/**Backspace**, or **Ctrl-click**/**Ctrl-drag**.
3. **Export xModel** and import the file into xLights.

## Run / build locally

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(Dart `^3.12`).

```bash
flutter pub get

# Web (in a browser)
flutter run -d chrome

# Windows desktop
flutter run -d windows

# Production web build (as deployed to GitHub Pages)
flutter build web --release --base-href /xmodelgen_flutter/
```

## Deployment

Every push to `main` builds the web app and publishes it to GitHub Pages via
[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml).

## License

See [LICENSE](LICENSE).
