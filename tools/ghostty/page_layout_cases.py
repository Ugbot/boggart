"""Arithmetic-only SDK cases: no page allocations, including maximum fields."""
def capacity(cols=215, rows=215, styles=128, hyperlink_bytes=192,
             grapheme_bytes=8192, string_bytes=2048):
    return dict(cols=cols, rows=rows, styles=styles, hyperlink_bytes=hyperlink_bytes,
                grapheme_bytes=grapheme_bytes, string_bytes=string_bytes)

WIDTHS = [1, 2, 3, 4, 5, 6, 15, 16, 31, 32, 63, 64, 79, 80, 81,
          127, 128, 129, 213, 214, 215, 216, 217, 511, 512, 513, 1024, 2048, 4096, 65535]
CASES = [dict(name=f'initial_{w}', cap=capacity(), adjust=w, initial=True) for w in WIDTHS]
for col in (0, 1, 6, 80, 215, 4096, 65535):
    for row in (0, 1, 2, 7, 8, 15, 16, 17, 215, 65535):
        CASES.append(dict(name=f'grid_{col}_{row}', cap=capacity(col, row), adjust=0, initial=False))
for field, values in (
    ('styles', [0, 1, 2, 3, 15, 16, 17, 127, 128, 129, 255, 256, 257, 1024, 65535]),
    ('grapheme_bytes', [0, 1, 15, 16, 17, 511, 512, 513, 8191, 8192, 8193, 65535, 65536, 4294967295]),
    ('string_bytes', [0, 1, 31, 32, 33, 2047, 2048, 2049, 65535, 65536, 4294967295]),
    ('hyperlink_bytes', [0, 1, 47, 48, 49, 191, 192, 193, 255, 256, 65535]),
):
    for value in values:
        c = capacity(rows=221); c[field] = value
        CASES.append(dict(name=f'{field}_{value}', cap=c, adjust=215, initial=False))
CASES += [dict(name='zero', cap=capacity(0, 0, 0, 0, 0, 0), adjust=1, initial=False),
          dict(name='all_maximum', cap=capacity(65535, 65535, 65535, 65535, 4294967295, 4294967295), adjust=0, initial=False)]
