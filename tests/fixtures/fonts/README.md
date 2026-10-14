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
