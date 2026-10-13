-- BMUX-20 cached-capacity crop/grow regression, also in the full SDK vectors.
local t <close> = require('terminal').new(6, 3, 2000)
t:feed('abcdefghij\27[?7l')
t:resize(4, 3)
assert(t:row(1).wrapped, 'nowrap shrink retains the original soft wrap')
t:resize(6, 3)
assert(t:row(1).wrapped, 'nowrap regrow to cached width must preserve Ghostty soft-wrap metadata')
print('cached-width nowrap crop/regrow parity passed')
