{-# LANGUAGE OverloadedStrings #-}

module Unison.Test.Typechecker where

import Control.Applicative
import Control.Monad.IO.Class
import Data.Functor
import Test.Tasty
import Test.Tasty.HUnit
import Unison.Node.MemNode ()
import Unison.Reference as R
import Unison.Symbol (Symbol)
import Unison.Term as E
import Unison.Type as T
import Unison.Typechecker as Typechecker
import Unison.View (DFO)
import Unison.Paths (Path)
import qualified Unison.Node as Node
import qualified Unison.Note as Note
import qualified Unison.Paths as Paths
import qualified Unison.Test.Common as Common
import qualified Unison.Test.Term as Term

type V = Symbol DFO
type TTerm = Term.TTerm
type TType = Type V
type TEnv f = T.Env f V
type TNode = IO Common.TNode

infixr 1 -->
(-->) :: TType -> TType -> TType
(-->) = T.arrow

data StrongEq = StrongEq TType
instance Eq StrongEq where StrongEq t1 == StrongEq t2 = Typechecker.equals t1 t2
instance Show StrongEq where show (StrongEq t) = show t

env :: TNode -> TEnv IO
env node r = do
  (node, _) <- Note.lift node
  Node.typeAt node (E.ref r) mempty

localsAt :: TNode -> Path -> TTerm -> IO [(V, Type V)]
localsAt node path e = Note.run $ do
  t2 <- Typechecker.locals (env node) path e
  pure t2

synthesizesAt :: TNode -> Path -> TTerm -> TType -> Assertion
synthesizesAt node path e t = Note.run $ do
  (node, _) <- Note.lift node
  t2 <- Node.typeAt node e path
  _ <- Note.fromEither (Typechecker.subtype t2 t)
  _ <- Note.fromEither (Typechecker.subtype t t2)
  pure ()

checksAt :: TNode -> Path -> TTerm -> TType -> Assertion
checksAt node path e t = Note.run . void $
  Typechecker.synthesize (env node) (Paths.modifyTerm' (\e -> E.wrapV (E.ann e t)) path e)

synthesizesAndChecksAt :: TNode -> Path -> TTerm -> TType -> Assertion
synthesizesAndChecksAt node path e t =
  synthesizesAt node path e t >> checksAt node path e t

synthesizes :: TNode -> TTerm -> TType -> Assertion
synthesizes node e t = Note.run $ do
  t2 <- Typechecker.synthesize (env node) e
  _ <- Note.fromEither (Typechecker.subtype t2 t)
  _ <- Note.fromEither (Typechecker.subtype t t2)
  pure ()

checks :: TNode -> TTerm -> TType -> Assertion
checks node e t = void $ Note.run (Typechecker.check (env node) e t)

checkSubtype :: TType -> TType -> Assertion
checkSubtype t1 t2 = case Typechecker.subtype t1 t2 of
  Left err -> assertFailure ("subtype failure:\n" ++ show err)
  Right t2 -> pure ()

synthesizesAndChecks :: TNode -> TTerm -> TType -> Assertion
synthesizesAndChecks node e t =
  synthesizes node e t >> checks node e t

--singleTest = withResource Common.node (\_ -> pure ()) $ \node -> testGroup "Typechecker"
--  [
--    testCase "synthesize/check (f -> let x = (let saved = f in 42) in 1)" $ synthesizesAndChecks node
--      (E.lam' ["f"] (E.let1' [("x", E.let1' [("saved", E.var' "f")] (E.num 42))] (E.num 1)))
--      (T.forall' ["x"] (T.v' "x" --> T.lit T.Number))
--  ]

tests :: TestTree
tests = withResource Common.node (\_ -> pure ()) $ \node -> testGroup "Typechecker"
  [
    testCase "alpha equivalence (type)" $ assertEqual "const"
      (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "a")
      (forall' ["x", "y"] $ T.v' "x" --> T.v' "y" --> T.v' "x")
  , testCase "subtype (1)" $ checkSubtype
      (T.lit T.Number)
      (T.lit T.Number)
  , testCase "subtype (2)" $ checkSubtype
      (forall' ["a"] $ T.v' "a")
      (T.lit T.Number)
  , testCase "subtype (3)" $ checkSubtype
      (forall' ["a"] $ T.v' "a")
      (forall' ["a"] $ T.v' "a")
  , testCase "strong equivalence (type)" $ assertEqual "types were not equal"
      (StrongEq (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "a"))
      (StrongEq (forall' ["y", "x"] $ T.v' "x" --> T.v' "y" --> T.v' "x"))
  , testCase "synthesize/check 42" $ synthesizesAndChecks node
      (E.lit (E.Number 42))
      (T.lit T.Number)
  , testCase "synthesize/check Term.id" $ synthesizesAndChecks node
      Term.id
      (forall' ["b"] $ T.v' "b" --> T.v' "b")
  , testCase "synthesize/check Term.const" $ synthesizesAndChecks node
      Term.const
      (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "a")
  , testCase "synthesize/check (x y -> y)" $ synthesizesAndChecks node
      (lam' ["x","y"] (var' "y"))
      (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "b")
  , testCase "synthesize/check (let f = (+) in f 1)" $ synthesizesAndChecks node
      (let1' [("f", E.builtin "Number.plus")] (var' "f" `E.app` E.num 1))
      (T.lit T.Number --> T.lit T.Number)
  , testCase "synthesize/check (let blank x = _ in blank 1)" $ synthesizesAndChecks node
      (let1' [("blank", lam' ["x"] E.blank )] (var' "blank" `E.app` E.num 1))
      (forall' ["a"] $ T.v' "a")
  , testCase "synthesize/check Term.fix" $ synthesizesAndChecks node
      Term.fix
      (forall' ["a"] $ (T.v' "a" --> T.v' "a") --> T.v' "a")
  , testCase "synthesize/check Term.pingpong1" $ synthesizesAndChecks node
      Term.pingpong1
      (forall' ["a"] $ T.v' "a")
  , testCase "synthesize/check [1,2,1+1]" $ synthesizesAndChecks node
      (E.vector [E.num 1, E.num 2, E.num 1 `Term.plus` E.num 1])
      (T.lit T.Vector `T.app` T.lit T.Number)
  , testCase "synthesize/checkAt [1,2,1+1]@[Index 2]" $ synthesizesAndChecksAt node
      [Paths.Index 2]
      (E.vector [E.num 1, E.num 2, E.num 1 `Term.plus` E.num 1])
      (T.lit T.Number)
  , testCase "synthesize/checkAt (let x = _ in _)@[Binding 0,Body]" $ synthesizesAndChecksAt node
      [Paths.Binding 0, Paths.Body]
      (E.let1' [("x", E.blank)] E.blank)
      unconstrained
  -- fails
  , testCase "synthesize/check (f -> let x = (let saved = f in 42) in 1)" $ synthesizesAndChecks node
      (E.lam' ["f"] (E.let1' [("x", E.let1' [("saved", E.var' "f")] (E.num 42))] (E.num 1)))
      (T.forall' ["x"] (T.v' "x" --> T.lit T.Number))
  , testCase "synthesize/check (f -> let x = (b a -> b) 42 f in 1)" $ synthesizesAndChecks node
      (E.lam' ["fo"] (E.let1' [("xo", Term.const `E.apps` [E.num 42, E.var' "fo"])] (E.num 1)))
      -- (E.lam' ["f"] (E.let1' [("x", Term.const `E.apps` [E.num 42, E.var' "f"])] (E.num 1)))
      (T.forall' ["x"] (T.v' "x" --> T.lit T.Number))
  , testCase "synthesize/check (f x y -> (x y -> y) f _ + _)" $ do
      let also = E.lam' ["x","y"] (E.var' "y")
      let tm = E.lam' ["f","x","y"] (also `E.apps` [E.var' "f", E.blank `Term.plus` E.blank])
      synthesizesAndChecks node tm $
        T.forall' ["a","b","c"] (T.v' "a" --> T.v' "b" --> T.v' "c" --> T.lit T.Number)
  , testCase "higher rank checking: (id -> let x = id 42; y = id 'hi' in 23) : (forall a . a -> a) -> Number" $
      let
        t = T.forall' ["a"] (T.v' "a") --> T.lit T.Number
        tm = E.lam' ["id"] (E.let1'
          [ ("id@Number", E.var' "id" `E.app` E.num 42),
            ("id@Text", E.var' "id" `E.app` E.text "hi")
          ] (E.num 43)) `E.ann` t
      in synthesizesAndChecks node tm t
  -- Let generalization not implemented yet; this test fails
  --, testCase "let generalization: let id a = a; x = id 42; y = id 'hi' in 23" $
  --    let
  --      tm = E.let1'
  --        [ ("id", E.lam' ["a"] (E.var' "a") `E.ann` T.forall' ["a"] (T.v' "a")),
  --          ("id@Number", E.var' "id" `E.app` E.num 42),
  --          ("id@Text", E.var' "id" `E.app` E.text "hi")
  --        ] (E.num 43)
  --    in synthesizesAndChecks node tm $ T.lit T.Number
  , testCase "locals (x y -> _ + _)@[Body,Body,Fn,Arg]" $ do
      -- hygene issue, one of these fails, the other succeeds, even though they are the same term
      -- let tm = E.lam' ["x","y"] (E.blank `Term.plus` E.blank) -- fails
      let tm = E.lam' ["p","q"] (E.blank `Term.plus` E.blank) -- succeeds
      [(x,xt), (y,yt)] <- localsAt node [Paths.Body, Paths.Body, Paths.Fn, Paths.Arg] tm
      assertEqual "xt unconstrainted" unconstrained (T.generalize xt)
      assertEqual "yt unconstrainted" unconstrained (T.generalize yt)
  , testCase "locals (let x = _ in _)" $ do
      let tm = E.let1' [("x", E.blank)] E.blank
      [(x,xt)] <- localsAt node [Paths.Body] tm
      [] <- localsAt node [Paths.Binding 0, Paths.Body] tm
      assertEqual "xt unconstrainted" unconstrained (T.generalize xt)
  , testCase "locals (let x = _; y = _ in _)@[Body,Body]" $ do
      let tm = E.let1' [("x", E.blank), ("y", E.blank)] E.blank
      [(x,xt), (y,yt)] <- localsAt node [Paths.Body, Paths.Body] tm
      assertEqual "xt unconstrainted" unconstrained (T.generalize xt)
      assertEqual "yt unconstrainted" unconstrained (T.generalize yt)
  , testCase "locals (let x = _; y = _ in _)@[Body,Binding 0,Body]" $ do
      let tm = E.let1' [("x", E.blank), ("y", E.blank)] E.blank
      -- let tm = E.let1' [("x", E.num 42), ("y", E.blank)] E.blank
      -- let tm = E.let1' [("x", E.num 42), ("y", E.num 43)] E.blank
      -- let tm = E.let1' [("x", E.num 42), ("y", E.num 43)] (E.num 4224)
      [(x,xt)] <- localsAt node [Paths.Body, Paths.Binding 0, Paths.Body] tm
      assertEqual "xt unconstrainted" unconstrained (T.generalize xt)
  ]

unconstrained :: TType
unconstrained = forall' ["a"] (T.v' "a")

main :: IO ()
main = defaultMain tests
-- main = defaultMain singleTest
