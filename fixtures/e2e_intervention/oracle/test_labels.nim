import labels

doAssert formatUserLabel("") == "guest"
doAssert formatUserLabel("   ") == "guest"
doAssert formatUserLabel(" hi ") == "hi"
doAssert formatUserLabel("x") == "x"
echo "oracle_labels: ok"
