{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE InstanceSigs       #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeFamilies       #-}

module RegistryExample.RegistryModel2 where

import           Control.Concurrent
import           Control.Exception            (ErrorCall, try)
import           Data.List
import           Test.QuickCheck
import           Test.QuickCheck.Monadic

import           RegistryExample.Registry
import           TypedStateModel
import           TypedStateModel.DynamicLogic


data RegState = RegState{
    tids :: [Var ThreadId],
    regs :: [(String,Var ThreadId)],
    dead :: [Var ThreadId]
  }
  deriving Show

deriving instance Show (Action RegState a)
deriving instance Eq (Action RegState a)

instance StateModel RegState where
  data Action RegState a where
    Spawn      ::                           Action RegState ThreadId
    WhereIs    :: String                 -> Action RegState (Maybe ThreadId)
    Register   :: String -> Var ThreadId -> Action RegState (Either ErrorCall ())
    Unregister :: String                 -> Action RegState (Either ErrorCall ())
    KillThread :: Var ThreadId           -> Action RegState ()
    -- not generated
    Successful :: Action RegState a      -> Action RegState a

  type ActionMonad RegState = IO

  arbitraryAction s =
    frequency
          [(max 1 $ 10-length (tids s),return $ Action Spawn),
           (max 1 $ 10-length (regs s),Action <$> (Register
             <$> probablyUnregistered s
             <*> elements (tids s))),
           (2*length (regs s),Action <$> (Unregister
             <$> probablyRegistered s)),
           (10,Action <$> (WhereIs
             <$> probablyRegistered s)),
           (max 1 $ 3-length (dead s),Action <$> (KillThread <$> elements (tids s)))
          ]

  shrinkAction s (Register name tid) =
    [Action (Unregister name)] ++
    [Action (Register name' tid) | name' <- shrinkName name] ++
    [Action (Register name tid') | tid'  <- shrinkTid s tid]
  shrinkAction s (Unregister name) =
    [Action (WhereIs name)] ++ [Action (Unregister name') | name' <- shrinkName name]
  shrinkAction s (WhereIs name) =
    [Action (WhereIs name') | name' <- shrinkName name]
  shrinkAction s Spawn = []
  shrinkAction s (KillThread tid) =
    [Action (KillThread tid') | tid' <- shrinkTid s tid]
  shrinkAction s (Successful act) =
    Action act : [Action (Successful act') | Action act' <- shrinkAction s act]


  initialState :: RegState
  initialState = RegState [] [] []

  nextState s Spawn step =
    s{tids = step:tids s}
  nextState s (Register name tid) _step
    | positive s (Register name tid) =
        s{regs = (name,tid):regs s}
    | otherwise = s
  nextState s (Unregister name) _step =
    s{regs = filter ((/=name) . fst) (regs s)}
  nextState s (KillThread tid) _ =
    s{dead = tid:dead s, regs = filter ((/=tid) . snd) (regs s)}
  nextState s (Successful act) step = nextState s act step
  nextState s _  _ = s

  precondition s (Register name step) = step `elem` tids s -- && positive s (Register name step)
  precondition s (KillThread tid)     = tid `elem` tids s
  precondition s (Successful act)     = precondition s act
  precondition _ _                    = True

  postcondition  s (WhereIs name)      env mtid =
    (env <$> lookup name (regs s)) == mtid
  postcondition _s Spawn                _         _   = True
  postcondition  s (Register name step) _         res =
    positive s (Register name step) == (res == Right ())
  postcondition _s (Unregister _name)   _         _   = True
  postcondition _s (KillThread _) _ _ = True
  postcondition s (Successful (Register _ _)) _ res = res==Right ()
  postcondition s (Successful act) env res = postcondition s act env res

  monitoring (_s, s') act _ res =
    counterexample ("\nState: "++show s'++"\n") .
    tabulate "Registry size" [show $ length (regs s')] .
    case act of
      Register _ t -> tabu "Register" [case res of Left _  -> "fails "++why _s act
                                                   Right() -> "succeeds"]
      Unregister _ -> tabu "Unregister" [case res of Left _ -> "fails"; Right() -> "succeeds"]
      WhereIs _    -> tabu "WhereIs" [case res of Nothing -> "fails"; Just _ -> "succeeds"]
      _            -> id

  perform Spawn _
    = forkIO (threadDelay 10000000)
  perform (Register name tid) env
    = try $ register name (env tid)
  perform (Unregister name) _
    = try $ unregister name
  perform (WhereIs name) _
    = whereis name
  perform (KillThread tid) env
    = do killThread (env tid)
         threadDelay 1000
  perform (Successful act) env =
    perform act env

positive :: RegState -> Action RegState a -> Bool
positive s (Register name tid) =
     name `notElem` map fst (regs s)
  && tid  `notElem` map snd (regs s)
  && tid  `notElem` dead s
positive s (Unregister name) =
     name `elem` map fst (regs s)
positive _s _ = True

instance DynLogicModel RegState where
  restricted (Successful _) = True
  restricted _              = False

why :: RegState -> Action RegState a -> String
why s (Register name tid) =
  unwords $ ["name already registered" | name `elem` map fst (regs s)] ++
            ["tid already registered"  | tid  `elem` map snd (regs s)] ++
            ["dead thread"             | tid  `elem` dead s]

arbitraryName :: Gen String
arbitraryName = elements allNames

probablyRegistered s = oneof $ map (return . fst) (regs s) ++ [arbitraryName]
probablyUnregistered s = elements $ allNames ++ (allNames \\ map fst (regs s))

shrinkName name = [n | n <- allNames, n < name]

allNames :: [String]
allNames = ["a", "b", "c", "d", "e"]

shrinkTid s tid = [ tid' | tid' <- tids s, tid' < tid ]

tabu tab xs = tabulate tab xs . foldr (.) id [classify True (tab++": "++x) | x <- xs]

prop_Registry :: Script RegState -> Property
prop_Registry s = monadicIO $ do
  _ <- run cleanUp
  monitor $ counterexample "\nExecution\n"
  _ <- runScript s
  assert True

cleanUp :: IO [Either ErrorCall ()]
cleanUp = sequence
  [try (unregister name) :: IO (Either ErrorCall ())
   | name <- allNames++["x"]]

{-
-- It's always possible to spawn a process.

canSpawn s = after Spawn (const passed)

canAlwaysRegister s = after Spawn car
  where car s = after (Register name tid) (const passed)
          .|||. weight 20 (afterAny car)
          where name = "a"
                tid = head (tids s)

anyScript s = passed .|||. afterAny anyScript

always p s = p s .|||. afterAny (always p)

propFollows :: DLProp RegState -> Script RegState -> Property
propFollows dl (Script s) =
  collect (head (dropWhile (<length s) $ iterate (*2) 1)) $
  (if null s then property else collect (showStepAction (last s))) $
  follows initialState (dl initialState) (Script s)

propWellFormed d = forAll (scriptFor d) $ propFollows d

propAccepts :: DLProp RegState -> Script RegState -> Bool
propAccepts p (Script s) =
  accepts initialState (p initialState) (Script s)

propAccepted d = forAll (scriptFor d) $ propAccepts d

propCanGenerate :: DLProp RegState -> Property
propCanGenerate d = forAll (scriptFor d) $ \(Script x) -> collect (length x) $ x==x

showStepAction (var := act) = show act
-}

propTest d = forAllScripts d prop_Registry

-- Generate normal test cases

normalTests s = passTest ||| afterAny normalTests

loopingTests s = afterAny loopingTests

canSpawn :: RegState -> DynLogic RegState
canSpawn s = after Spawn done

canRegisterA s
  | null (tids s) = after Spawn canRegisterA
  | otherwise     = after (Successful $ Register "a" (head (tids s))) done

-- test that the registry never contains more than k processes

regLimit k s | length (regs s) > k = ignore   -- fail? yes, gets stuck at this point
             | otherwise           = passTest ||| afterAny (regLimit k)

-- test that we can register a pid that is not dead, if we unregister the name first.

canRegisterUndead s
  | null alive = ignore
  | otherwise  = after (Successful (Register "x" (head alive))) done
  where alive = tids s \\ dead s

canRegister s
  | length (regs s) == 5 = ignore  -- all names are in use
  | null (tids s) = after Spawn canRegister
  | otherwise     = forAllQ (elementsQ (allNames \\ map fst (regs s)),
                             elementsQ (tids s)) $ \(name,tid) ->
                      after (Successful $ Register name tid)
                      done

canRegisterName name s = forAllQ (elementsQ availableTids) $ \tid ->
                           after (Successful $ Register name tid) done
  where availableTids = tids s \\ map snd (regs s)

canReregister s
  | null (regs s) = ignore
  | otherwise     = forAllQ (elementsQ $ map fst (regs s)) $ \name ->
                      after (Unregister name) (canRegisterName name)

canRegisterName' name s = forAllQ (elementsQ availableTids) $ \tid ->
                            after (Successful $ Register name tid) done
  where availableTids = (tids s \\ map snd (regs s)) \\ dead s

canReregister' s
  | null (regs s) = toStop $
                      if null availableTids then after Spawn canReregister'
                      else after (Register "a" (head availableTids)) canReregister'
  | otherwise     = forAllQ (elementsQ $ map fst (regs s)) $ \name ->
                      after (Unregister name) (canRegisterName' name)
  where availableTids = (tids s \\ map snd (regs s)) \\ dead s

