{-# LANGUAGE QuasiQuotes #-}
-- | Game rules and assorted data for LambdaHack.
module Content.RuleKind ( cdefs ) where

import Multiline

-- Cabal
import qualified Paths_LambdaHack as Self (getDataFileName, version)

import Game.LambdaHack.Vector
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind
import qualified Game.LambdaHack.Feature as F
import qualified Game.LambdaHack.Content as Content

cdefs :: Content.CDefs RuleKind
cdefs = Content.CDefs
  { getSymbol = rsymbol
  , getName = rname
  , getFreq = rfreq
  , validate = ruvalidate
  , content =
      [standard]
  }
standard :: RuleKind

standard = RuleKind
  { rsymbol        = 's'
  , rname          = "standard LambdaHack ruleset"
  , rfreq          = [("standard", 100)]
    -- Check whether one location is accessible from another.
    -- Precondition: the two locations are next to each other.
    -- Apart of checking the target tile, we forbid diagonal movement
    -- to and from doors.
  , raccessible    = \ lxsize sloc src tloc tgt ->
      F.Walkable `elem` tfeature tgt
      && not ((F.Closable `elem` tfeature src ||
               F.Closable `elem` tfeature tgt)
              && diagonal lxsize (towards lxsize sloc tloc))
  , rtitle         = "LambdaHack"
  , rpathsDataFile = Self.getDataFileName
  , rpathsVersion  = Self.version
  , ritemMelee     = ")"
  , ritemProject   = "!?|/"
  -- ASCII art for the Main Menu. Only pure 7-bit ASCII characters are
  -- allowed. The picture should be exactly 24 rows by 80 columns,
  -- plus an extra frame of any charecters that is ignored for all purposes.
  -- For a different screen size, the picture is centered and the outermost
  -- rows and columns cloned. When displayed in the Main Menu screen,
  -- it's overwritten with the game version string and keybinding strings.
  -- The game version string begins and ends with a space and is placed
  -- in the very bottom right corner. The keybindings overwrite places
  -- marked with 25 starting brace signs '{' in a row. The sign is forbidden
  -- everywhere else. Exactly five such places with 25 starting braces
  -- are required, at most one per row, and all are overwritten
  -- with text that is flushed left and padded with spaces.
  -- The Main Menu is displayed dull white on black.
  -- TODO: Highlighted keybinding is in inverse video or bright white on grey
  -- background. The spaces that pad keybindings are not highlighted.
  , rmainMenuArt   = [multiline|
----------------------------------------------------------------------------------
|                                                                                |
|                                                                                |
|                      >> LambdaHack <<                                          |
|                                                                                |
|                                                                                |
|                                                                                |
|                      {{{{{{{{{{{{{{{{{{{{{{{{{                                 |
|                                                                                |
|                      {{{{{{{{{{{{{{{{{{{{{{{{{                                 |
|                                                                                |
|                      {{{{{{{{{{{{{{{{{{{{{{{{{                                 |
|                                                                                |
|                      {{{{{{{{{{{{{{{{{{{{{{{{{                                 |
|                                                                                |
|                      {{{{{{{{{{{{{{{{{{{{{{{{{                                 |
|                                                                                |
|                                                                                |
|                                                                                |
|                                                                                |
|                                                                                |
|                                                                                |
|                                                                                |
|                                                                                |
|                        Version X.X.X (frontend: gtk, engine: LambdaHack X.X.X) |
----------------------------------------------------------------------------------
|]}
