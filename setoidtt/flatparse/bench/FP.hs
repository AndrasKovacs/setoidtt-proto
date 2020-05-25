
module FP where

import FlatParse

ws      = manyTok_ ($(char ' ') <!> $(char '\n'))
open    = $(char '(') >> ws
close   = $(char ')') >> ws
ident   = someTok_ (satisfyA isLatinLetter) >> ws
sexp    = br open (some_ sexp >> close) ident
src     = sexp >> eof
runSexp = runParser src

longw     = $(string "thisisalongkeyword")
longws    = someTok_ (longw >> ws) >> eof
runLongws = runParser longws

numeral   = someTok_ (satisfyA \c -> '0' <= c && c <= '9') >> ws
comma     = $(char ',') >> ws
numcsv    = numeral >> manyBr_ comma numeral >> eof
runNumcsv = runParser numcsv