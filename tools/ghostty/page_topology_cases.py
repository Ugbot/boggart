"""Page boundary probes, kept separate from the immutable resize fixture gate."""
from resize_cases import CASES as RESIZE_CASES, ESC, case

CASES = [c for c in RESIZE_CASES if c['name'] in (
    'cached_page_head_spill', 'cached_mixed_page_widths',
    'nowrap_cached_owned_history', 'height_cached_capacity_then_grow')]
for row in (20, 250):
    text = ('A' * 216 + '\r\n') * 160 + ESC + '[?7l'
    head = ESC + '[?7h' + ESC + f'[{row};213H日' + ESC + '[?7l'
    CASES.append(case(f'sdk_boundary_head_{row}', 215, 300, text, (213, 300), head, (215, 300)))
    CASES.append(case(f'sdk_boundary_height_head_{row}', 215, 300, text,
                      (215, 280), (215, 300), (213, 300), head, (215, 300)))

styles = ''.join(ESC + f'[38;2;{i // 256};{i % 256};1mX' for i in range(768))
CASES.append(case('sdk_style_capacity_growth', 215, 300, styles + ESC + '[0m' + ESC + '[?7l',
                  (213, 300), ESC + '[?7h' + ESC + '[1;213H日' + ESC + '[?7l', (215, 300)))
clusters = ''.join(chr(0x400 + i) + '\u0301' * 16 for i in range(768))
CASES.append(case('sdk_grapheme_capacity_growth', 215, 300, clusters + ESC + '[?7l',
                  (213, 300), ESC + '[?7h' + ESC + '[1;213H日' + ESC + '[?7l', (215, 300)))
