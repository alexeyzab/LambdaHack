{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Screen frames.
module Game.LambdaHack.Client.UI.Frame
  ( SingleFrame(..), Frames, overlayFrame
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Text as T

import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Common.Color
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point

-- | An overlay that fits on the screen (or is meant to be truncated on display)
-- and is padded to fill the whole screen
-- and is displayed as a single game screen frame.
newtype SingleFrame = SingleFrame {singleFrame :: Overlay}
  deriving (Eq, Show)

-- | Sequences of screen frames, including delays.
type Frames = [Maybe SingleFrame]

-- | Overlays with a given overlay either the top line and level map area
-- of a screen frame or the whole area of a completely empty screen frame.
overlayFrame :: Overlay -> Maybe SingleFrame -> SingleFrame
overlayFrame topTrunc msf =
  let lxsize = fst normalLevelBound + 1  -- TODO
      lysize = snd normalLevelBound + 1
      emptyLine = toAttrLine $ T.replicate lxsize " "
      canvasLength = if isNothing msf then lysize + 3 else lysize + 1
      canvas = maybe (replicate canvasLength emptyLine)
                     (\sf -> singleFrame sf)
                     msf
      topLayer = if length topTrunc <= canvasLength
                 then topTrunc
                 else take (canvasLength - 1) topTrunc
                      ++ [toAttrLine "--a portion of the text trimmed--"]
      f layerLine canvasLine =
        let truncated = truncateAttrLine lxsize layerLine
        in truncated ++ drop (length truncated) canvasLine
      picture = zipWith f topLayer canvas
      newLevel = picture ++ drop (length picture) canvas
  in SingleFrame newLevel

-- | Add a space at the message end, for display overlayed over the level map.
-- Also trim (do not wrap!) too long lines.
truncateAttrLine :: X -> AttrLine -> AttrLine
truncateAttrLine w xs =
  case compare w (length xs) of
    LT -> let discarded = drop w xs
          in if all ((== ' ') . acChar) discarded
             then take w xs
             else take (w - 1) xs ++ [AttrChar (Attr BrBlack defBG) '$']
    EQ -> xs
    GT -> if null xs || acChar (last xs) == ' '
          then xs
          else xs ++ [AttrChar defAttr ' ']