## Independent reception oracle — never supplied to the model context.
import cart

doAssert lineTotal(Line(skuId: "bread", qty: 1)) == 120
doAssert lineTotal(Line(skuId: "bread", qty: 2)) == 240
doAssert cartTotal([
  Line(skuId: "bread", qty: 2),
  Line(skuId: "milk", qty: 1)
]) == 335
doAssert cartTotal([Line(skuId: "eggs", qty: 3)]) == 630
echo "oracle_cart_total: ok"
