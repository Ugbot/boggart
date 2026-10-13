-- Pending BMUX-20 acceptance regression. The pinned SDK preserves this wrap
-- through its cached-capacity crop/grow path; Boggart currently clears it.
-- Run directly until the compatibility fix joins the main resize vectors.
local t <close> = require('terminal').new(6, 3, 2000)
t:feed('abcdefghij\27[?7l')
t:resize(4, 3)
assert(t:row(1).wrapped, 'nowrap shrink retains the original soft wrap')
t:resize(6, 3)
assert(t:row(1).wrapped, 'nowrap regrow to cached width must preserve Ghostty soft-wrap metadata')
print('cached-width nowrap crop/regrow parity passed')
