"""Real SDK page boundaries and later operations consuming grown-page slack."""
from copy import deepcopy
from page_topology_cases import CASES as TOPOLOGY_CASES
from resize_cases import ESC, case

CASES = deepcopy(TOPOLOGY_CASES)
# Keep the mixed-script cluster case and add a printable-base case that isolates
# managed-page capacity from script-specific feed behavior.
clusters = ''.join('a' + ''.join('\u0301' if bit == '1' else '\u0300' for bit in f'{i:016b}') for i in range(768))
CASES.append(case('sdk_grapheme_ascii_capacity_growth', 215, 300, clusters + ESC + '[?7l',
                  (213, 300), ESC + '[?7h' + ESC + '[1;213H日' + ESC + '[?7l', (215, 300)))
for c in CASES:
    if c['name'] in ('sdk_style_capacity_growth', 'sdk_grapheme_capacity_growth', 'sdk_grapheme_ascii_capacity_growth'):
        extra = case('extra', 215, 300, (217, 300),
                     ESC + '[?7h' + ESC + '[1;1H' + 'A' * 218
                     + ESC + '[250;1H' + 'B' * 218 + ESC + '[?7l', (215, 300),
                     ESC + '[?7h' + ESC + '[220;215H日' + ESC + '[?7l', (217, 300))
        c['operations'].extend(extra['operations'])
