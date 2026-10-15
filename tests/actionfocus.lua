local Focus=require 'actionfocus'
local focus=Focus.new();local a,b={key='a'},{key='b'}
local disabled={key='disabled',disabled=true}
assert(not focus:current{a,b})
assert(focus:move({a,disabled,b},1)==a)
assert(focus:current{b,a}==a,'reordering preserves logical focus')
assert(focus:move({a,disabled,b},1)==b,'disabled actions are skipped')
assert(focus:move({a,b},1)==a and focus:move({a,b},-1)==b,'both directions wrap')
assert(not focus:current{a,{key='new-b'}} and not focus.key,'replacement cannot inherit old action focus')
assert(not focus:current{a,b},'activation does not auto-select a replacement')
assert(focus:move({a,b},-1)==b)
assert(not focus:current{a,{key='b',disabled=true}},'revoked action loses focus')
assert(not focus:move({},1));focus:move({a},1);focus:clear();assert(not focus.key)
print('actionfocus: stable keys, reorder, revocation, cyclic traversal and disabled actions pass')
return 0
