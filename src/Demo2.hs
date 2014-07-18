{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Demo2 where

import Data.Monoid
import Data.Function
import Data.List
import Data.Maybe
import qualified Data.IntMap as Map
import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Lens.Family2
import Lens.Family2.Stock
import Lens.Family2.Unchecked

import Data.LensRef.EqRef

infixl 1 <&>

{-# INLINE (<&>) #-}
(<&>) :: Functor f => f a -> (a -> b) -> f b
as <&> f = f <$> as

--------------------------------------------------------------------------------

type Widget s = RefCreator s (RefReader s (Int, [String]))

class RefContext s => WidgetContext s where
    registerControl :: NewCtrl s

type NewCtrl s = RefReader s [Action s] -> RefReader s Color -> RefReader s String -> Widget s

data Action s
    = Click (RefWriter s ())             -- button and checkbox
    | Put   (String -> RefWriter s ())   -- entry
    | Get   (RefReader s String)         -- entry and dynamic label

--------------------------------------------------------------------------------

type Color = Int

color :: Color -> String -> String
color (-1) s = s
color c s = "\x1b[" ++ show c ++ "m" ++ s ++ "\x1b[0m"

--------------------------------------------------------------------------------

newtype WContext m a
    = WContext { runWContext :: ReaderT (NewCtrl (WContext m)) m a }
        deriving (Functor, Applicative, Monad)

instance MonadTrans WContext where
    lift = WContext . lift

instance RefContext m => RefContext (WContext m) where
    type SimpleRef (WContext m) = SimpleRef m
    newSimpleRef = lift . newSimpleRef
    readSimpleRef = lift . readSimpleRef
    writeSimpleRef r = lift . writeSimpleRef r

instance RefContext m => WidgetContext (WContext m) where
    registerControl acts col name = do
        f <- lift $ WContext ask
        f acts col name

runWidget
    :: forall m . RefContext m
    => Maybe ([String] -> m ())
    -> Widget (WContext m)
    -> m (Int -> m (), Int -> String -> m (), Int -> m String, m [String])
runWidget autodraw cw = do
    controlmap <- newSimpleRef mempty
    controlcounter <- newSimpleRef 0

    let registerControl acts col name = do
            i <- lift $ modSimpleRef controlcounter $ state $ \c -> (c, succ c)
            let setControlActions cs = modSimpleRef controlmap $ modify $ case cs of
                    [] -> Map.delete i
                    _ -> Map.insert i cs
                f Unblock = acts
                f _ = pure []
            _ <- onChange acts $ lift . setControlActions
            onRegionStatusChange_ $ \msg -> f msg <&> setControlActions
            let n = show i
            return $ do
                c <- col
                s <- name
                return (length n + length s, [color 31 n ++ color c s])

    flip runReaderT registerControl $ runWContext $ runRefCreator $ \runRefWriter_ -> do

        w <- cw <&> fmap snd

        maybe (pure ()) (\out -> void $ onChangeEq w $ lift . lift . out) autodraw

        let runRefWriter :: RefWriter (WContext m) b -> m b
            runRefWriter = flip runReaderT registerControl . runWContext . runRefWriter_

            click cs = fromMaybe (fail "not a button or checkbox") $ listToMaybe [runRefWriter act | Click act <- cs]
            put cs s = fromMaybe (fail "not an entry")             $ listToMaybe [runRefWriter $ act s | Put act <- cs]
            get cs   = fromMaybe (fail "not an entry or label")    $ listToMaybe [runRefWriter $ readerToWriter act | Get act <- cs]

            lookup_ :: Int -> m [Action (WContext m)]
            lookup_ i = readSimpleRef controlmap >>= maybe (fail "control not registered") pure . Map.lookup i

            draw = runRefWriter $ readerToWriter w

        return (lookup_ >=> click, flip $ \s -> lookup_ >=> (`put` s), lookup_ >=> get, draw)

--------------------------------------------------------------------------------

label :: WidgetContext s => String -> Widget s
label s = pure $ pure (length s, [color 35 s])

padding :: WidgetContext s => Widget s -> Widget s
padding w = w <&> \l -> l <&> \(n, s) -> (n+2, map ("  " ++) $ {- replicate n ' ' : -} s)

dynLabel :: WidgetContext s => RefReader s String -> Widget s
dynLabel r = registerControl (pure [Get r]) (pure 44) (r <&> \s -> " " ++ s ++ " ")

primButton
    :: WidgetContext s
    => RefReader s String     -- ^ dynamic label of the button
    -> Maybe (RefReader s Color)
    -> RefReader s Bool       -- ^ the button is active when this returns @True@
    -> RefWriter s ()        -- ^ the action to do when the button is pressed
    -> Widget s
primButton name col vis act =
    registerControl (vis <&> \v -> if v then [Click act, Get name] else [])
         (fromMaybe (pure 37) col >>= \c -> vis <&> bool c 35)
         name

primEntry :: (RefClass r, WidgetContext s) => RefReader s Bool -> r s String -> Widget s
primEntry ok r =
    registerControl (pure [Put $ writeRef r, Get $ readRef r])
         (ok <&> bool 42 41)
         (readRef r <&> \s -> " " ++ s ++ " ")

vertically :: WidgetContext s => [Widget s] -> Widget s
vertically ws = sequence ws <&> \l -> sequence l <&> foldr vert (0, [])
  where
    vert (n, s) (m, t) = (k, map (pad (k-n)) s ++ map (pad (k-m)) t)
      where
        k = max n m
        pad n l = l ++ replicate n ' '

horizontally :: WidgetContext s => [Widget s] -> Widget s
horizontally ws = sequence ws <&> \l -> sequence l <&> foldr horiz (0, [])
  where
    horiz (0, _) ys = ys
    horiz (n, xs) (m, ys) = (n + m + 1, zipWith (++) (ext n xs) (map (' ':) $ ext m ys))
      where
        h = max (length xs) (length ys)
        ext n l = take h $ l ++ repeat (replicate n ' ')

cell :: (Eq a, WidgetContext s) => RefReader s a -> (a -> Widget s) -> Widget s
cell r f = onChangeMemo r (\v -> f v <&> pure) <&> join

--------------------------------------------------------------------------------

checkbox :: WidgetContext s => Ref s Bool -> Widget s
checkbox r = primButton (readRef r <&> show) Nothing (pure True) $ modRef r not

notebook :: WidgetContext s => [(String, Widget s)] -> Widget s
notebook ws = do
    i <- newRef (0 :: Int)
    vertically
        [ horizontally
            [ primButton (pure s) (Just $ readRef i <&> bool 32 37 . (== n)) (pure True) $ writeRef i n
            | (n, (s,_)) <- zip [0..] ws
            ]
        , padding $ cell (readRef i) $ \i -> snd (ws !! i)
        ]

-- | Button.
button
    :: WidgetContext s
    => RefReader s String     -- ^ dynamic label of the button
    -> RefReader s (Maybe (RefWriter s ()))     -- ^ when the @Maybe@ readRef is @Nothing@, the button is inactive
    -> Widget s
button r fm = primButton r Nothing (fmap isJust fm) $ readerToWriter fm >>= fromMaybe (pure ())

-- | Button which inactivates itself automatically.
smartButton
    :: WidgetContext s
    => RefReader s String     -- ^ dynamic label of the button
    -> EqRef s a              -- ^ underlying reference
    -> (a -> a)   -- ^ The button is active when this function is not identity on readRef of the reference. When the button is pressed, the readRef of the reference is modified with this function.
    -> Widget s
smartButton s r f
    = primButton s Nothing (readRef r >>= changing r . f) (modRef r f)

emptyWidget :: WidgetContext s => Widget s
emptyWidget = horizontally []

-- | Label entry.
entry :: WidgetContext s => Ref s String -> Widget s
entry r = primEntry (pure True) r

entryShow :: (Show a, Read a, RefClass r, WidgetContext s) => r s a -> Widget s
entryShow r = do
    x <- readerToCreator $ readRef r
    v <- extendRef (toRef r) (lens fst set') (x, Nothing)
    primEntry (readRef v <&> isNothing . snd) $ lens get set `lensMap` v
  where
    set' t@(v',_) v | show v == show v' = t
    set' _ v = (v, Nothing)

    get (_, Just s) = s
    get (v, _) = show v

    set (v, _) s = case reads s of
        ((x,""):_) -> (x, Nothing)
        _ -> (v, Just s)

--------------------------------------------------------------------------------

showw = appendFile "out" . (++ "\n")

demo' :: IO (Int -> IO (), Int -> String -> IO (), Int -> IO ())
demo' = do
    (click, put, get, _) <- runWidget (Just $ appendFile "out" . unlines . (++ [[]])) $ do
        s <- newRef True
        st <- newRef []
        padding $ intListEditor (0, True) 15 st s
    return (click, put, get >=> showw)

demo :: IO (Int -> IO (), Int -> String -> IO (), Int -> IO String)
demo = do
    (click, put, get, _) <- runWidget (Just $ mapM_ putStrLn . (++ [[]])) $ do
        s <- newRef True
        st <- newRef []
        padding $ intListEditor (0, True) 15 st s
    return (click, put, get)


intListEditor
    :: forall s
    .  WidgetContext s
    => (Integer, Bool)          -- ^ default element
    -> Int                      -- ^ maximum number of elements
    -> Ref s [(Integer, Bool)]  -- ^ state reference
    -> Ref s Bool               -- ^ settings reference
    -> Widget s
intListEditor def maxi list_ range = do
    (undo, redo)  <- undoTr ((==) `on` map fst) list_
    op <- newRef sum
    notebook
        [ (,) "Editor" $ vertically
            [ horizontally
                [ button (pure "Undo") undo
                , button (pure "Redo") redo
                ]
            , horizontally
                [ entryShow len
                , label "items"
                , smartButton (pure "AddItem") len (+1)
                , smartButton (pure "RemoveItem") len (+(-1))
                , smartButton (readRef len <&> \n -> "RemoveAll(" ++ show n ++ ")") len $ const 0
                ]
            , horizontally
                [ smartButton (pure "All+1")      list $ map $ over _1 (+1)
                , smartButton (pure "All-1")      list $ map $ over _1 (+(-1))
                , smartButton (pure "Sort")       list $ sortBy (compare `on` fst)
                ]
            , horizontally
                [ smartButton (pure "SelectAll")  list $ map $ set _2 True
                , smartButton (pure "SelectPos")  list $ map $ \(a,_) -> (a, a>0)
                , smartButton (pure "SelectEven") list $ map $ \(a,_) -> (a, even a)
                , smartButton (pure "InvertSel")  list $ map $ over _2 not
                ]
            , horizontally
                [ smartButton (sel <&> \s -> "DelSel(" ++ show (length s) ++ ")") list $ filter $ not . snd
                , smartButton (pure "CopySel") safeList $ concatMap $ \(x,b) -> (x,b): [(x,False) | b]
                , smartButton (pure "Sel+1")     list $ map $ mapSel (+1)
                , smartButton (pure "Sel-1")     list $ map $ mapSel (+(-1))
                ]
            , horizontally
                [ dynLabel $ liftA2 ($) (readRef op) (sel <&> map fst) <&> show
                , label "selected sum"
                ]
            , padding $ listEditor def (map itemEditor [0..]) list_
            ]
        , (,) "Settings" $ horizontally
            [ label "create range"
            , checkbox range
            ]
        ]
 where
    list = toEqRef list_

    itemEditor :: Int -> Ref s (Integer, Bool) -> Widget s
    itemEditor i r = horizontally
        [ label $ show (i+1) ++ "."
        , entryShow $ _1 `lensMap` r
        , button (readRef r <&> bool "unselect" "select" . snd) $ pure $ Just $ modRef (_2 `lensMap` r) not
        , button (pure "Del")  $ pure $ Just $ modRef list $ \xs -> take i xs ++ drop (i+1) xs
        , button (pure "Copy") $ pure $ Just $ modRef list $ \xs -> take (i+1) xs ++ drop i xs
        ]

    safeList = lens id (const $ take maxi) `lensMap` list

    sel = fmap (filter snd) $ readRef list

    len = joinRef $ readRef range <&> \r -> ll r `lensMap` safeList   -- todo
    ll :: Bool -> Lens' [(Integer, Bool)] Int
    ll r = lens length extendList where
        extendList xs n = take n $ (reverse . drop 1 . reverse) xs ++
            (uncurry zip . (iterate (+ if r then 1 else 0) *** repeat)) (head $ reverse xs ++ [def])

    mapSel f (x, y) = (if y then f x else x, y)

    (f *** g) (a, b) = (f a, g b)

listEditor :: forall s a . WidgetContext s => a -> [Ref s a -> Widget s] -> Ref s [a] -> Widget s
listEditor _ [] _ = error "not enought editors for listEditor"
listEditor def (ed: eds) r = do
    q <- extendRef r listLens (False, (def, []))
    cell (fmap fst $ readRef q) $ \b -> case b of
        False -> emptyWidget
        True -> vertically
            [ ed $ _2 . _1 `lensMap` q
            , listEditor def eds $ _2 . _2 `lensMap` q
            ]

bool a _ True = a
bool _ b False = b

--------------------------------------------------------------------------------

listLens :: Lens' (Bool, (a, [a])) [a]
listLens = lens get set where
    get (False, _) = []
    get (True, (l, r)) = l: r
    set (_, x) [] = (False, x)
    set _ (l: r) = (True, (l, r))


-- | Undo-redo state transformation.
undoTr
    :: RefContext s
    => (a -> a -> Bool)    -- ^ equality on state
    -> Ref s a             -- ^ reference of state
    -> RefCreator s
           ( RefReader s (Maybe (RefWriter s ()))
           , RefReader s (Maybe (RefWriter s ()))
           )  -- ^ undo and redo actions
undoTr eq r = do
    ku <- extendRef r (undoLens eq) ([], [])
    let try f = fmap (fmap (writeRef ku) . f) $ readRef ku
    pure (try undo, try redo)
  where
    undo (x: xs@(_:_), ys) = Just (xs, x: ys)
    undo _ = Nothing

    redo (xs, y: ys) = Just (y: xs, ys)
    redo _ = Nothing

undoLens :: (a -> a -> Bool) -> Lens' ([a],[a]) a
undoLens eq = lens get set where
    get = head . fst
    set (x' : xs, ys) x | eq x x' = (x: xs, ys)
    set (xs, _) x = (x : xs, [])


