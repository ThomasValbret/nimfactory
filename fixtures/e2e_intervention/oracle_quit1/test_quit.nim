## Runtime functional failure: compiles, then exits 1.
import labels

doAssert formatUserLabel("") == "guest"
quit(1)
