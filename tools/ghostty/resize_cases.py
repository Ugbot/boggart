"""Curated resize inputs. History stays below the differing pruning policies."""
from __future__ import annotations

ESC = '\x1b'

def case(name, columns, rows, *operations):
    ops = []
    for op in operations:
        if isinstance(op, str):
            ops.append({'feed_hex': op.encode('utf-8').hex()})
        elif isinstance(op, bytes):
            ops.append({'feed_hex': op.hex()})
        else:
            ops.append({'resize': list(op)})
    return {'name': name, 'columns': columns, 'rows': rows, 'operations': ops}

CASES = [
    case('wrapped_plain', 6, 3, 'abcdefghij', (4, 3), (9, 4), 'Z'),
    case('pending_wrap_shrink', 6, 3, 'abcdef', (4, 3), 'Z'),
    case('pending_wrap_grow', 6, 3, 'abcdef', (9, 3), 'Z'),
    case('wrapped_history', 6, 3, 'abcdefghij\r\nklmnopqrst\r\nuvwxyz0123\r\n456789abc', (4, 3), (10, 4)),
    case('height_shrink_trailing_blanks', 6, 5, 'top\r\nnext', (6, 2), 'Z'),
    case('height_shrink_text_and_pull_back', 6, 4, 'a\r\nb\r\nc\r\nd', (6, 2), (6, 4)),
    case('height_grow_cursor_top', 6, 2, 'a\r\nb\r\nc\r\nd'+ESC+'[H', (6, 4)),
    case('height_grow_cursor_bottom', 6, 2, 'a\r\nb\r\nc\r\nd', (6, 4)),
    case('cursor_right_of_text', 6, 3, ESC+'[1;6H', (3, 3), 'Z'),
    case('cursor_on_lower_blank_row', 6, 4, ESC+'[4;6H', (3, 2), 'Z'),
    case('saved_cursor', 6, 3, 'abcdefghij'+ESC+'7'+ESC+'[H', (4, 3), ESC+'8Z'),
    case('wide_head_reflow', 6, 3, 'abcde日', (4, 3), (8, 3), 'Z'),
    case('wide_boundary', 5, 3, 'abc日xyz日', (4, 3), (7, 3)),
    case('one_column_wide', 4, 4, '日A日', (1, 4), (4, 4)),
    case('cursor_on_wide_tail', 6, 3, 'abcd日'+ESC+'[6G', (5, 3), 'Z'),
    case('owned_clusters', 6, 3, 'é👩‍💻🇬🇧❤️', (4, 4), (10, 3)),
    case('cluster_at_pending_wrap', 3, 3, 'é❤️', (4, 3), (1, 3)),
    case('nowrap_crops', 6, 3, 'abcdefghij'+ESC+'[?7l', (4, 3), 'Z', (8, 3)),
    case('nowrap_cached_width', 6, 3, 'abcdefghij'+ESC+'[?7l', (4, 3), (6, 3)),
    case('nowrap_cached_cycles', 6, 3, 'abcdefghij'+ESC+'[?7l', (4, 3), (5, 3), (3, 3), (6, 3), (8, 3), (4, 3), (8, 3)),
    case('nowrap_cached_head_slow_path', 6, 3, 'abcdefghij'+ESC+'[?7l', (4, 3), ESC+'[?7h'+ESC+'[1;4H日'+ESC+'[?7l', (5, 3)),
    case('nowrap_cached_owned_history', 6, 3, ESC+'[31;1m'+ESC+']8;id=cache;https://example.com/cache\a'+'é👩‍💻abcdefghij\r\nklmnopqrst\r\nuvwxyz0123'+ESC+']8;;\a'+ESC+'[?7l', (4, 3), (6, 5), (3, 2), (6, 4), (8, 3)),
    case('alternate_cached_width', 6, 3, ESC+'[?1049h'+'abcdefghij', (4, 3), (6, 3), (5, 2), (6, 4), ESC+'[?1049l'),
    case('inactive_alternate_cached_width', 6, 3, ESC+'[?47habcdefghij'+ESC+'[?47l'+ESC+'[?7lprimary', (4, 3), (6, 3), ESC+'[?47h'),
    case('cached_then_reflow', 6, 3, 'abcdefghij'+ESC+'[?7l', (4, 3), (6, 3), ESC+'[?7h', (5, 3), (8, 4), (4, 2), (6, 3)),
    case('cached_page_head_spill', 6, 20, ('abcdefghij\r\n'*12)+ESC+'[?7l', (4, 20), ESC+'[?7h'+ESC+'[18;4H日'+ESC+'[?7l', (6, 20)),
    case('cached_mixed_page_widths', 6, 20, ('abcdef\r\n'*24)+ESC+'[?7l', (4, 20), ESC+'[H'+('xyz\r\n'*18), (6, 20), (8, 20), (4, 20), (8, 22)),
    case('nowrap_wide_cut', 6, 3, 'abc日'+ESC+'[?7l', (4, 3), (8, 3)),
    case('alternate_crops_primary_reflows', 6, 3, 'primary'+ESC+'[?1049h'+'abcdefghij日', (4, 2), (8, 4), ESC+'[?1049lZ'),
    case('inactive_alternate', 6, 3, ESC+'[?47hALT-WRAPPED'+ESC+'[?47lprimary', (4, 3), ESC+'[?47h'),
    case('reset_margins', 6, 4, ESC+'[2;3r'+ESC+'[?6h'+ESC+'[Habc', (4, 3), ESC+'[H\r\nZ'),
    case('reset_column_tabs', 12, 3, ESC+'[1;4H'+ESC+'H'+ESC+'[H', (14, 3), '\tZ'),
    case('background_blanks', 6, 3, ESC+'[44m'+ESC+'[2J'+ESC+'[Hab', (3, 3), (8, 3)),
    case('rgb_background_blanks', 6, 3, ESC+'[48;2;1;2;3m'+ESC+'[2J'+ESC+'[Hab', (3, 3), (8, 3)),
    case('styles_and_links', 6, 3, ESC+'[31;1mABCDEF'+ESC+'[0m'+ESC+']8;id=resize;https://example.com\aabcde'+ESC+']8;;\a', (4, 4), (10, 3)),
    case('clear_active_preserves_position', 6, 3, 'a\r\nb\r\nc\r\nd\r\ne'+ESC+'[2J'+ESC+'[H', (4, 4)),
    case('partial_utf8_across_resize', 6, 3, b'\xf0\x9f', (4, 3), b'\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb', (8, 2)),
    case('partial_csi_across_resize', 6, 3, ESC+'[38;2;', (4, 3), '1;2;3mX', (8, 2)),
    case('same_size_is_noop', 6, 3, ESC+'[2;3rabc'+ESC+'[38;5;9m', (6, 3), '\r\nZ'),
]
