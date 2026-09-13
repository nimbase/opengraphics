<p align="center">
  Open parsers and writers for popular graphics file formats<br>
</p>

<p align="center">
  <code>nimble install opengraphics</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/opengraphics/">API reference</a><br>
  <img src="https://github.com/nimbase/opengraphics/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/opengraphics/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
- Read Adobe Photoshop `.psd` files with pure Nim stdlib, no dependencies: headers, layers and group trees, Raw and RLE pixels, thumbnails, ICC profiles
- Shared pixel model (`ImageBuf`) designed for conversion from one format to another
- Unknown blocks preserved as raw bytes so future writers can round-trip files

## Roadmap
- Read support for `.ai`, `.eps`, `.aep`, and more
- Writers for each supported format
- Format-to-format conversion helpers
- Building blocks for high-level libraries and apps compatible with popular graphics formats

## Examples
```nim
import opengraphics/psd

let doc = openPsd("poster.psd")
echo doc.width, "x", doc.height, " layers: ", doc.layerCount
for node in doc.layerTree():
  echo node.layer.displayName()
doc.composite.saveBmp("preview.bmp") # BMP opens in macOS Preview
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/opengraphics/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/opengraphics/fork)

### 🎩 License
MIT license | Nim Community.
