# macOS session island

The native panel, notch geometry, session routing, local hook protocol and WebKit interface are adapted from [asafofer/perch at 47ce905](https://github.com/asafofer/perch/tree/47ce905fd63848e8be2d0a356f479a9734e13766). The original MIT notice is in [LICENSE](LICENSE). Inter's OFL notice lives alongside the font under ui/dist/fonts. The UI source contains its icon attribution.

Perch builds the two Swift modules locally. IslandHost connects the island to the existing application delegate and menu. This integration uses the Claude Code and Codex providers and keeps its socket, preferences and hook entries separate from the upstream application.

The bundled custom element in ui/blob-avatar.js comes from [c0le0ni/blob-avatar at 14abf51](https://github.com/c0le0ni/blob-avatar/tree/14abf5127f6182fe1bb636de2d3947c8ca839e21). Its MIT notice is in [blob-avatar.LICENSE](blob-avatar.LICENSE). To rebuild it from the pinned checkout, run the following from this directory with esbuild installed.

```sh
esbuild /path/to/blob-avatar/packages/blob-avatar/src/element.ts --bundle --format=iife --target=safari16 --outfile=ui/blob-avatar.js
```
