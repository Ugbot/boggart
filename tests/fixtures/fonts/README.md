# Indic shaping fixture

`NotoSansDevanagari.ttf` is the variable Noto Sans Devanagari font from
[Google Fonts](https://github.com/google/fonts/tree/main/ofl/notosansdevanagari),
retrieved 2026-10-14. Tests use the default axis coordinates. Its checked-in bytes
are pinned by SHA-256:

`14ec4af41f27482216d1c2229f417ff9b1425e1babb014e57d1d40d03229853e`

The accompanying original SIL Open Font License is
`NotoSansDevanagari-OFL.txt`, SHA-256
`a216f6f8d85c7228093e0ee5e258d9d377e6671f68acb4db1930b29583d0f331`.
This is a test fixture; Studio's bundled fonts are unchanged.

`renderer_clusters` verifies a Devanagari conjunct substitutes to one glyph and
an i-vowel reorders before its consonant, with the fixture as the primary face.
`studio_terminal_clusters` renders it through native retained rows in both modes,
with fragmented input, styles, history/reflow and queued source closure.

## Color emoji fixture

`NotoColorEmoji-subset.ttf` retains the CBDT/CBLC bitmap strikes and GSUB
sequence substitutions from [Google's Noto Emoji](https://github.com/googlefonts/noto-emoji/tree/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/2D/fonts).
The original `NotoColorEmoji.ttf` SHA-256 is
`15671215ab769fdc7162a045d56fd7d7e477c51b04e6b3c761d914d8fdd6cc44`.
The checked-in subset SHA-256 is
`60ee72317793302d26af119f3b49c0035303627c7ff9136bbf4edb9c4bced8a7`.
It was generated with the native HarfBuzz 14.4.0 tool:

```sh
hb-subset NotoColorEmoji.ttf \
  --text='😀👩‍💻🇬🇧❤️👍🏽1️⃣👨‍👩‍👧‍👦©︎' \
  --output-file=NotoColorEmoji-subset.ttf
```

The original `NotoColorEmoji-OFL.txt` SHA-256 is
`6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2`.
This small fixture is for deterministic tests, not an installed/bundled fallback.
The renderer uses the installed native emoji font at runtime.
