{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE JavaScriptFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

{-
  Copyright 2019 The CodeWorld Authors. All rights reserved.
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0
  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}

module CodeWorld.CanvasM where

import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans (MonadIO)
import Data.Text (Text, pack)

#ifdef ghcjs_HOST_OS

import Data.JSString.Text
import GHCJS.DOM
import GHCJS.DOM.Element
import GHCJS.DOM.NonElementParentNode
import GHCJS.Marshal.Pure
import GHCJS.Types
import qualified JavaScript.Web.Canvas as Canvas
import qualified JavaScript.Web.Canvas.Internal as Canvas

#else

import qualified Graphics.Blank as Canvas
import Graphics.Blank (Canvas)
import Text.Printf

#endif

class (Monad m, MonadIO m) => MonadCanvas m where
    type Image m

    save :: m ()
    restore :: m ()
    transform ::
           Double -> Double -> Double -> Double -> Double -> Double -> m ()
    translate :: Double -> Double -> m ()
    scale :: Double -> Double -> m ()
    newImage :: Int -> Int -> m (Image m)
    builtinImage :: Text -> m (Maybe (Image m))
    withImage :: Image m -> m a -> m a
    drawImage :: Image m -> Int -> Int -> Int -> Int -> m ()
    globalCompositeOperation :: Text -> m ()
    lineWidth :: Double -> m ()
    strokeColor :: Int -> Int -> Int -> Double -> m ()
    fillColor :: Int -> Int -> Int -> Double -> m ()
    font :: Text -> m ()
    textCenter :: m ()
    textMiddle :: m ()
    beginPath :: m ()
    closePath :: m ()
    moveTo :: (Double, Double) -> m ()
    lineTo :: (Double, Double) -> m ()
    quadraticCurveTo :: (Double, Double) -> (Double, Double) -> m ()
    bezierCurveTo ::
           (Double, Double) -> (Double, Double) -> (Double, Double) -> m ()
    arc :: Double -> Double -> Double -> Double -> Double -> Bool -> m ()
    rect :: Double -> Double -> Double -> Double -> m ()
    fill :: m ()
    stroke :: m ()
    fillRect :: Double -> Double -> Double -> Double -> m ()
    fillText :: Text -> (Double, Double) -> m ()
    measureText :: Text -> m Double
    isPointInPath :: (Double, Double) -> m Bool
    isPointInStroke :: (Double, Double) -> m Bool

saveRestore :: MonadCanvas m => m a -> m a
saveRestore m = do
    save
    r <- m
    restore
    return r

#if defined(ghcjs_HOST_OS)

data CanvasM a = CanvasM
    { unCanvasM :: Canvas.Context -> IO a
    } deriving (Functor)

runCanvasM :: Canvas.Context -> CanvasM a -> IO a
runCanvasM = flip unCanvasM

instance Applicative CanvasM where
    pure x = CanvasM (const (return x))
    f <*> x = CanvasM (\ctx -> unCanvasM f ctx <*> unCanvasM x ctx)

instance Monad CanvasM where
    return = pure
    m >>= f = CanvasM (\ctx -> unCanvasM m ctx >>= ($ ctx) . unCanvasM . f)

foreign import javascript "$2.globalCompositeOperation = $1;"
               js_globalCompositeOperation :: JSString -> Canvas.Context -> IO ()

foreign import javascript "$r = $3.isPointInPath($1, $2);"
               js_isPointInPath :: Double -> Double -> Canvas.Context -> IO Bool

foreign import javascript "$r = $3.isPointInStroke($1, $2);"
               js_isPointInStroke :: Double -> Double -> Canvas.Context -> IO Bool

instance MonadIO CanvasM where
    liftIO = CanvasM . const

instance MonadCanvas CanvasM where
    type Image CanvasM = Canvas.Canvas
    save = CanvasM Canvas.save
    restore = CanvasM Canvas.restore
    transform a b c d e f = CanvasM (Canvas.transform a b c d e f)
    translate x y = CanvasM (Canvas.translate x y)
    scale x y = CanvasM (Canvas.scale x y)
    newImage w h = liftIO (Canvas.create w h)
    builtinImage name = liftIO $ do
        Just doc <- currentDocument
        canvas <- getElementById doc (textToJSString name)
        return (Canvas.Canvas . unElement <$> canvas)
    withImage img m = liftIO $ do
        ctx <- Canvas.getContext img
        unCanvasM m ctx
    drawImage (Canvas.Canvas c) x y w h =
        CanvasM (Canvas.drawImage (Canvas.Image c) x y w h)
    globalCompositeOperation op =
        CanvasM (js_globalCompositeOperation (textToJSString op))
    lineWidth w = CanvasM (Canvas.lineWidth w)
    strokeColor r g b a = CanvasM (Canvas.strokeStyle r g b a)
    fillColor r g b a = CanvasM (Canvas.fillStyle r g b a)
    font t = CanvasM (Canvas.font (textToJSString t))
    textCenter = CanvasM (Canvas.textAlign Canvas.Center)
    textMiddle = CanvasM (Canvas.textBaseline Canvas.Middle)
    beginPath = CanvasM Canvas.beginPath
    closePath = CanvasM Canvas.closePath
    moveTo (x, y) = CanvasM (Canvas.moveTo x y)
    lineTo (x, y) = CanvasM (Canvas.lineTo x y)
    quadraticCurveTo (x1, y1) (x2, y2) =
        CanvasM (Canvas.quadraticCurveTo x1 y1 x2 y2)
    bezierCurveTo (x1, y1) (x2, y2) (x3, y3) =
        CanvasM (Canvas.bezierCurveTo x1 y1 x2 y2 x3 y3)
    arc x y r a1 a2 dir = CanvasM (Canvas.arc x y r a1 a2 dir)
    rect x y w h = CanvasM (Canvas.rect x y w h)
    fill = CanvasM Canvas.fill
    stroke = CanvasM Canvas.stroke
    fillRect x y w h = CanvasM (Canvas.fillRect x y w h)
    fillText t (x, y) = CanvasM (Canvas.fillText (textToJSString t) x y)
    measureText t = CanvasM (Canvas.measureText (textToJSString t))
    isPointInPath (x, y) = CanvasM (js_isPointInPath x y)
    isPointInStroke (x, y) = CanvasM (js_isPointInStroke x y)

#else

-- Unfortunately, the Canvas monad from blank-canvas lacks a MonadIO instance.
-- We can recover it by inserting send calls where needed.  This looks a lot
-- like a free monad, but we want our own interpreter logic, so it's written
-- by hand.

data CanvasM a = CanvasOp (Maybe Canvas.CanvasContext) (Canvas (CanvasM a))
               | NativeOp (Canvas.DeviceContext -> IO (CanvasM a))
               | PureOp a
    deriving (Functor)

doCanvas :: Maybe Canvas.CanvasContext -> Canvas a -> Canvas a
doCanvas Nothing m = m
doCanvas (Just ctx) m = Canvas.with ctx m

interpCanvas :: CanvasM a -> Canvas (CanvasM a)
interpCanvas (CanvasOp mctx op) = doCanvas mctx op >>= interpCanvas
interpCanvas other = return other

runCanvasM :: Canvas.DeviceContext -> CanvasM a -> IO a
runCanvasM _    (PureOp   a)   = return a
runCanvasM dctx (NativeOp fm) = fm dctx >>= runCanvasM dctx
runCanvasM dctx m             = Canvas.send dctx (interpCanvas m) >>= runCanvasM dctx

instance Applicative CanvasM where
    pure = PureOp

    (CanvasOp mctx1 f) <*> (CanvasOp mctx2 x) = CanvasOp mctx1 (fmap (<*>) f <*> doCanvas mctx2 x)
    f <*> x = f `ap` x

instance Monad CanvasM where
    return = pure
    PureOp x >>= f = f x
    NativeOp op >>= f = NativeOp $ \dctx -> do
        next <- op dctx
        return (next >>= f)
    CanvasOp mctx op >>= f = CanvasOp mctx $ bindCanvas (doCanvas mctx op) f

bindCanvas :: Canvas (CanvasM a) -> (a -> CanvasM b) -> Canvas (CanvasM b)
bindCanvas m cont = do
    next <- m
    case next of
        CanvasOp mctx op -> bindCanvas (doCanvas mctx op) cont
        _                -> return (next >>= cont)

instance MonadIO CanvasM where
    liftIO x = NativeOp $ const $ PureOp <$> x

liftCanvas :: Canvas a -> CanvasM a
liftCanvas m = CanvasOp Nothing (PureOp <$> m)

instance MonadCanvas CanvasM where
    type Image CanvasM = Canvas.CanvasContext

    save = liftCanvas $ Canvas.save ()
    restore = liftCanvas $ Canvas.restore ()
    transform a b c d e f = liftCanvas $ Canvas.transform (a, b, c, d, e, f)
    translate x y = liftCanvas $ Canvas.translate (x, y)
    scale x y = liftCanvas $ Canvas.scale (x, y)
    newImage w h = liftCanvas $ Canvas.newCanvas (w, h)
    builtinImage name = return Nothing

    withImage ctx (CanvasOp Nothing m) = CanvasOp (Just ctx) m
    withImage _   (CanvasOp mctx m)    = CanvasOp mctx m
    withImage ctx (NativeOp fm)        = NativeOp $ \dctx -> withImage ctx <$> fm dctx
    withImage _   (PureOp x)           = PureOp x

    drawImage img x y w h = liftCanvas $
        Canvas.drawImageSize
            ( img
            , fromIntegral x
            , fromIntegral y
            , fromIntegral w
            , fromIntegral h)
    globalCompositeOperation op = liftCanvas $
        Canvas.globalCompositeOperation op
    lineWidth w = liftCanvas $ Canvas.lineWidth w
    strokeColor r g b a = liftCanvas $ Canvas.strokeStyle
        (pack (printf "rgba(%d,%d,%d,%.2f)" r g b a))
    fillColor r g b a = liftCanvas $ Canvas.fillStyle
        (pack (printf "rgba(%d,%d,%d,%.2f)" r g b a))
    font t = liftCanvas $ Canvas.font t
    textCenter = liftCanvas $ Canvas.textAlign Canvas.CenterAnchor
    textMiddle = liftCanvas $ Canvas.textBaseline Canvas.MiddleBaseline
    beginPath = liftCanvas $ Canvas.beginPath ()
    closePath = liftCanvas $ Canvas.closePath ()
    moveTo (x, y) = liftCanvas $ Canvas.moveTo (x, y)
    lineTo (x, y) = liftCanvas $ Canvas.lineTo (x, y)
    quadraticCurveTo (x1, y1) (x2, y2) = liftCanvas $
        Canvas.quadraticCurveTo (x1, y1, x2, y2)
    bezierCurveTo (x1, y1) (x2, y2) (x3, y3) = liftCanvas $
        Canvas.bezierCurveTo (x1, y1, x2, y2, x3, y3)
    arc x y r a1 a2 dir = liftCanvas $
        Canvas.arc (x, y, r, a1, a2, dir)
    rect x y w h = liftCanvas $ Canvas.rect (x, y, w, h)
    fill = liftCanvas $ Canvas.fill ()
    stroke = liftCanvas $ Canvas.stroke ()
    fillRect x y w h = liftCanvas $ Canvas.fillRect (x, y, w, h)
    fillText t (x, y) = liftCanvas $ Canvas.fillText (t, x, y)
    measureText t = liftCanvas $ do
        Canvas.TextMetrics w <- Canvas.measureText t
        return w
    isPointInPath (x, y) = liftCanvas $ Canvas.isPointInPath (x, y)
    isPointInStroke (x, y) = liftCanvas $ return False

#endif
