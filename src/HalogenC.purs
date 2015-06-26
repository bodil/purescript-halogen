module HalogenC where

  import Control.Functor (($>))
  import Control.Monad.Free (Free(), runFreeM, mapF, liftFC)
  import Control.Monad.Rec.Class (MonadRec)
  import Control.Monad.State.Class (MonadState, get, put)
  import Control.Monad.State.Trans (StateT(), runStateT)
  import Control.Monad.Trans (MonadTrans, lift)
  import Control.Plus (Plus, empty)
  import Data.Bifunctor (bimap, lmap)
  import Data.Coyoneda (Natural(), lowerCoyoneda)
  import Data.Either (Either(..))
  import Data.Functor.Coproduct (Coproduct(), coproduct, left, right)
  import Data.Maybe (Maybe(..), maybe)
  import Data.Tuple (Tuple(..), fst, snd)
  import Halogen.HTML
  import qualified Data.Map as M

  newtype Component s f g p = Component
    { render :: s -> HTML p (f Unit)
    , query  :: forall i. Free f i -> StateT s g i
    }

  runComponent :: forall s f g p. Component s f g p -> _
  runComponent (Component c) = c

  instance functorComponent :: Functor (Component s f g) where
    (<$>) f (Component c) =
      Component { render: \s -> f `lmap` c.render s
                , query: c.query
                }

  foreign import todo :: forall a. a

  installR :: forall s f g pl pr s' f' p'. (Ord pr, Plus g) =>
    (pr -> Tuple s' (Component s' f' g p'))               ->
    Component s f (QueryT s s' f' pr p' g) (Either pl pr) ->
    Component (InstalledState s s' f' pl p' g) (Coproduct f (ChildF pr f')) g (Either pl p')
  installR f a = todo

  installL :: forall s f g pl pr s' f' p'. (Ord pl, Plus g) =>
    (pl -> Tuple s' (Component s' f' g p'))               ->
    Component s f (QueryT s s' f' pl p' g) (Either pl pr) ->
    Component (InstalledState s s' f' pr p' g) (Coproduct f (ChildF pl f')) g (Either pr p')
  installL f a = todo

  installAll :: forall s f g p s' f' p'. (Ord p, Functor f, Functor f', MonadRec g, Plus g) =>
    (p -> Tuple s' (Component s' f' g p'))  ->
    Component s f (QueryT s s' f' p p' g) p ->
    Component (InstalledState s s' f' p p' g) (Coproduct f (ChildF p f')) g p'
  installAll f (Component c) = Component { render: render, query: query }
    where

    render :: (InstalledState s s' f' p p' g) -> HTML p' ((Coproduct f (ChildF p f')) Unit)
    render st = install (renderChild st) left $ c.render st.parent

    renderChild :: (InstalledState s s' f' p p' g) -> p -> HTML p' ((Coproduct f (ChildF p f')) Unit)
    renderChild st p = case f p of
      Tuple si (Component c) ->
        (right <<< ChildF p) <$> c.render (maybe si fst $ M.lookup p st.children)

    query :: forall i. Free (Coproduct f (ChildF p f')) i -> StateT (InstalledState s s' f' p p' g) g i
    query fi = runFreeM (coproduct (pure empty) queryChild) fi

    queryChild :: forall i. ChildF p f' i -> StateT (InstalledState s s' f' p p' g) g i
    queryChild (ChildF p q) = do
      st <- get :: _ (InstalledState s s' f' p p' g)
      case M.lookup p st.children of
        Nothing -> empty
        Just (Tuple s comp@(Component c)) -> do
          Tuple i s' <- lift $ runStateT (c.query $ lowerCoyoneda `mapF` liftFC q) s
          put st { children = M.insert p (Tuple s' comp) st.children }
          pure i

  data ChildF p f i = ChildF p (f i)

  instance functorChildF :: (Functor f) => Functor (ChildF p f) where
    (<$>) f (ChildF p fi) = ChildF p (f <$> fi)

  type ComponentState s f g p = Tuple s (Component s f g p)

  type InstalledState s s' f' p p' g =
    { parent   :: s
    , children :: M.Map p (ComponentState s' f' g p')
    , factory  :: p -> ComponentState s' f' g p'
    }

  newtype QueryT s s' f' p p' g a = QueryT (StateT (InstalledState s s' f' p p' g) g a)

  runQueryT :: forall s s' f' p p' g a. QueryT s s' f' p p' g a -> StateT (InstalledState s s' f' p p' g) g a
  runQueryT (QueryT a) = a

  query :: forall s s' f' p p' g. (Monad g, Ord p) => p -> (forall i. Free f' i -> QueryT s s' f' p p' g (Maybe i))
  query p q = QueryT $ do
    st <- get :: _ (InstalledState s s' f' p p' g)
    case M.lookup p st.children of
      Nothing -> pure Nothing
      Just (Tuple s comp@(Component c)) -> do
        Tuple i s' <- lift $ runStateT (c.query q) s
        put st { children = M.insert p (Tuple s' comp) st.children }
        pure (Just i)

  instance functorQueryT :: (Monad g) => Functor (QueryT s s' f' p p' g) where
    (<$>) f (QueryT a) = QueryT (f <$> a)

  instance applyQueryT :: (Monad g) => Apply (QueryT s s' f' p p' g) where
    (<*>) (QueryT f) (QueryT a) = QueryT (f <*> a)

  instance applicativeQueryT :: (Monad g) => Applicative (QueryT s s' f' p p' g) where
    pure a = QueryT (pure a)

  instance bindQueryT :: (Monad g) => Bind (QueryT s s' f' p p' g) where
    (>>=) (QueryT a) f = QueryT $ a >>= runQueryT <<< f

  instance monadQueryT :: (Monad g) => Monad (QueryT s s' f' p p' g)

  instance monadStateQueryT :: (Monad g) => MonadState s (QueryT s s' f' p p' g) where
    state f = QueryT $ do
      st <- get
      let s' = f st.parent
      put st { parent = snd s' }
      pure $ fst s'

  instance monadTransQueryT :: MonadTrans (QueryT s s' f' p p') where
    lift m = QueryT $ lift m

module ClickComponent where

  import Control.Monad.Free
  import Control.Monad.Rec.Class
  import Control.Monad.State.Class (modify)
  import Control.Monad.State.Trans

  import Data.Coyoneda
  import Data.Identity
  import Data.Inject
  import Data.Void

  import HalogenC
  import qualified Halogen.HTML as H

  data Input a = ClickIncrement a | ClickDecrement a
  type InputC = Coyoneda Input

  clickIncrement :: forall g. (Functor g, Inject (Coyoneda Input) g) => Free g Unit
  clickIncrement = liftF (inj (liftCoyoneda $ ClickIncrement unit) :: g Unit)

  clickDecrement :: forall g. (Functor g, Inject (Coyoneda Input) g) => Free g Unit
  clickDecrement = liftF (inj (liftCoyoneda $ ClickDecrement unit) :: g Unit)

  counterComponent :: forall g. (MonadRec g) => Component Number InputC g Void
  counterComponent = Component { render : render, query : query }
    where

    eval :: forall g. (Monad g) => Natural Input (StateT Number g)
    eval (ClickIncrement next) = do
      modify (+1)
      return next
    eval (ClickDecrement next) = do
      modify (flip (-) 1)
      return next

    render :: Number -> H.HTML Void (InputC Unit)
    render n = H.text (show n)

    query :: forall g i. (MonadRec g) => Free InputC i -> StateT Number g i
    query = runFreeCM eval

  test :: Free InputC Unit
  test = do
    clickIncrement
    clickIncrement
    clickDecrement

module EditorComponent where

  import Control.Monad.State.Trans
  import Control.Monad.State.Class (modify)
  import Control.Monad.Free
  import Control.Monad.Rec.Class
  import Control.Monad.Eff
  import Control.Monad.Trans (lift)
  import Control.Apply ((*>))

  import Data.Coyoneda
  import Data.Inject
  import Data.Void
  import Data.Identity

  import DOM (DOM())
  import HalogenC
  import qualified Halogen.HTML as H

  data Input a = GetContent (String -> a) | SetContent a String | GetCursor (Number -> a)
  type InputC = Coyoneda Input

  getContent :: forall g. (Functor g, Inject (Coyoneda Input) g) => Free g String
  getContent = liftF (inj (liftCoyoneda $ GetContent id) :: g String)

  setContent :: forall g. (Functor g, Inject (Coyoneda Input) g) => String -> Free g Unit
  setContent s = liftF (inj (liftCoyoneda $ SetContent unit s) :: g Unit)

  getCursor :: forall g. (Functor g, Inject (Coyoneda Input) g) => Free g Number
  getCursor = liftF (inj (liftCoyoneda $ GetCursor id) :: g Number)

  editorComponent :: forall eff. Component Unit InputC (Eff (dom :: DOM | eff)) Void
  editorComponent = Component { render : render, query : query }
    where

    eval :: forall eff a. Natural Input (StateT Unit (Eff (dom :: DOM | eff)))
    eval (GetContent f  ) = lift $       f <$> effectfulGetContent
    eval (SetContent n s) = lift $ const n <$> effectfulSetContent s
    eval (GetCursor  f  ) = lift $       f <$> effectfulGetCursor

    render s = H.text "todo"

    query :: forall eff i. Free InputC i -> StateT Unit (Eff (dom :: DOM | eff)) i
    query = runFreeCM eval

  test :: Free InputC Unit
  test = do
    cursor  <- getCursor
    content <- getContent
    setContent $ content ++ (show cursor)

  foreign import effectfulGetContent :: forall eff. Eff (dom :: DOM | eff) String
  foreign import effectfulSetContent :: forall eff. String -> Eff (dom :: DOM | eff) Unit
  foreign import effectfulGetCursor  :: forall eff. Eff (dom :: DOM | eff) Number