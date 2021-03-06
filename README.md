LambdaHack
==========

[![Build Status](https://travis-ci.org/LambdaHack/LambdaHack.svg?branch=master)](https://travis-ci.org/LambdaHack/LambdaHack)
[![Hackage](https://img.shields.io/hackage/v/LambdaHack.svg)](https://hackage.haskell.org/package/LambdaHack)
[![Join the chat at https://gitter.im/LambdaHack/LambdaHack](https://badges.gitter.im/LambdaHack/LambdaHack.svg)](https://gitter.im/LambdaHack/LambdaHack?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

LambdaHack is a Haskell[1] game engine library for roguelike[2] games
of arbitrary theme, size and complexity,
packaged together with a little sample dungeon crawler.
Try out the browser version of the LambdaHack sample game at
[https://lambdahack.github.io](https://lambdahack.github.io)!
(It runs fastest on Chrome. Keyboard commands and savefiles
are supported only on recent enough versions of browsers.
Mouse should work everywhere.)

![gameplay screenshot](https://raw.githubusercontent.com/LambdaHack/media/master/screenshot/crawl-0.6.0.0-8x8xb.png)

To use the engine, you need to specify the content to be
procedurally generated, including game rules and AI behaviour.
The library lets you compile a ready-to-play game binary,
using either the supplied or a custom-made main loop.
Several frontends are available (SDL2 is the default
for desktop and there is a Javascript browser frontend)
and many other generic engine components are easily overridden,
but the fundamental source of flexibility lies
in the strict and type-safe separation of code from the content
and of clients (human and AI-controlled) from the server.

Please see the changelog file for recent improvements
and the issue tracker for short-term plans. Long term vision
revolves around procedural content generation and includes
in-game content creation, auto-balancing and persistent
content modification based on player behaviour.
Contributions are welcome.

Other games known to use the LambdaHack library:

* Allure of the Stars[6], a near-future Sci-Fi game
* Space Privateers[8], an adventure game set in far future

Note: the engine and the example game are bundled together in a single
Hackage[3] package released under the permissive `BSD3` license.
You are welcome to create your own games by forking and modifying
the single package, but please consider eventually splitting your changes
into a separate content-only package that depends on the upstream
engine library. This will help us exchange ideas and share improvements
to the common codebase. Alternatively, you can already start the development
in separation by cloning and rewriting Allure of the Stars[10]
and mix and merge with the example LambdaHack game rules at will.
Note that the LambdaHack sample game derives from the Hack/Nethack visual
and narrative tradition[9], while Allure of the Stars uses the more free-form
Moria/Angband style (it also uses the `AGPL` license, and `BSD3 + AGPL = AGPL`,
so make sure you want to liberate your code and content to such an extent).

When creating a new game based on LambdaHack I've found it useful to place
completely new content at the end of the content files to distinguish from
merely modified original LambdaHack content and thus help merging with new
releases. Removals of LambdaHack content merge reasonably well, so there are
no special considerations. When modifying individual content items,
it makes sense to keep their Haskell identifier names and change only
in-game names and possibly frequency group names.


Installation of the sample game from binary archives
----------------------------------------------------

The game runs rather slowly in the browser (fastest on Chrome)
and you are limited to only one font, though it's scalable.
Keyboard input and saving game progress requires recent enough
version of a browser (but mouse input is enough to play the game).
Also, savefiles are prone to corruption on the browser,
e.g., when it's closed while the game is still saving progress
(which takes a long time). Hence, after trying out the game,
you may prefer to use a native binary for your architecture, if it exists.

Pre-compiled game binaries for some platforms are available through
the release page[11] and from AppVeyor (Windows 32bit[17] and Windows 64bit[18];
note that these no longer work on Windows XP, since Cygwin and MSYS2
dropped support for XP). To use a pre-compiled binary archive,
unpack it and run the executable in the unpacked directory.

On Linux, make sure you have the SDL2 libraries suite installed on your system
(e.g., libsdl2, libsdl2-ttf). For Windows, the SDL2 and all other needed
libraries are already contained in the game's binary archive.


Screen and keyboard configuration
---------------------------------

The game UI can be configured via a config file.
A file with the default settings, the same that is built into the binary,
is in [GameDefinition/config.ui.default](https://github.com/LambdaHack/LambdaHack/blob/master/GameDefinition/config.ui.default).
When the game is run for the first time, the file is copied to the default
user data folder, which is `~/.LambdaHack/` on Linux,
`C:\Users\<username>\AppData\Roaming\LambdaHack\`
(or `C:\Documents And Settings\user\Application Data\LambdaHack\`
or something else altogether) on Windows, and in RMB menu, under
`Inspect/Application/Local Storage` when run inside the Chrome browser.

Screen font can be changed by editing the config file in the user
data folder. For a small game window, the highly optimized
bitmap fonts 16x16x.fon, 8x8x.fon and 8x8xb.fon are the best,
but for larger window sizes or if you require international characters
(e.g. to give custom names to player characters), a modern scalable font
supplied with the game is the only option. The game window automatically
scales according to the specified font size. Display on SDL2
and in the browser is superior to all the other frontends,
due to custom square font and less intrusive ways of highlighting
interesting squares.

If you don't have a numeric keypad, you can use mouse or laptop keys
(uk8o79jl) for movement or you can enable the Vi keys (aka roguelike keys)
in the config file. If numeric keypad doesn't work, toggling
the Num Lock key sometimes helps. If running with the Shift key
and keypad keys doesn't work, try Control key instead.
The game is fully playable with mouse only, as well as with keyboard only,
but the most efficient combination for some players is mouse for go-to,
inspecting, and aiming at distant positions and keyboard for everything else.

If you are using a terminal frontend, numeric keypad may not work
correctly depending on versions of the libraries, terminfo and terminal
emulators. Toggling the Num Lock key may help.
The curses frontend is not fully supported due to the limitations
of the curses library. With the vty frontend started in an xterm,
Control-keypad keys for running seem to work OK, but on rxvt they do not.
The commands that require pressing Control and Shift together won't
work either, but fortunately they are not crucial to gameplay.


Compilation of the library and sample game from source
------------------------------------------------------

If you want to compile native binaries from the source code,
use Cabal (already a part of your OS distribution, or available within
The Haskell Platform[7]), which also takes care of all the dependencies.

The recommended frontend is based on SDL2, so you need the SDL2 libraries
for your OS. On Linux, remember to install the -dev versions as well,
e.g., libsdl2-dev and libsdl2-ttf-dev on Ubuntu Linux 16.04.
(Compilation to Javascript for the browser is more complicated
and requires the ghcjs[15] compiler and optionally the Google Closure
Compiler[16] as well. See the
[Makefile](https://github.com/LambdaHack/LambdaHack/blob/master/Makefile)
for more details.)

The latest official version of the LambdaHack library can be downloaded,
compiled for SDL2 and installed automatically by Cabal from Hackage[3]
as follows

    cabal update
    cabal install LambdaHack

For a newer snapshot, download the source code from github[5]
and run Cabal from the main directory

    cabal install

There is a built-in line terminal frontend, suitable for teletype terminals
or a keyboard and a printer (but it's going to use a lot of paper,
unless you disable animations with `--noAnim`). To compile with
one of the less rudimentary terminal frontends (in which case you are
on your own regarding font choice and color setup and you won't have
the spiffy colorful squares around special positions, only crude highlights),
use Cabal flags, e.g,

    cabal install -fvty

To compile with GTK2 (deprecated but still supported; beware that
the font is not square and special position highlights are annoying),
you need GTK libraries for your OS. On Windows follow the same steps
as for Wine[13]. On OSX, if you encounter problems, you may want to
compile the GTK libraries from sources[14]. Invoke Cabal as follows

    cabal install -fgtk gtk2hs-buildtools .


Testing and debugging
---------------------

The [Makefile](https://github.com/LambdaHack/LambdaHack/blob/master/Makefile)
contains many sample test commands.
Numerous tests that use the screensaver game modes (AI vs. AI)
and the teletype frontend are gathered in `make test`.
Of these, travis runs `test-travis` on each push to github.
Test commands with prefix `frontend` start AI vs. AI games
with the standard, user-friendly frontend.

Run `LambdaHack --help` to see a brief description of all debug options.
Of these, the `--sniff` option is very useful (though verbose
and initially cryptic), for displaying the traffic between clients
and the server. Some options in the config file may prove useful too,
though they mostly overlap with commandline options (and will be totally
merged at some point).

You can use HPC with the game as follows (details vary according
to HPC version).

    cabal clean
    cabal install --enable-coverage
    make test
    hpc report --hpcdir=dist/hpc/dyn/mix/LambdaHack --hpcdir=dist/hpc/dyn/mix/LambdaHack-xxx/ LambdaHack
    hpc markup --hpcdir=dist/hpc/dyn/mix/LambdaHack --hpcdir=dist/hpc/dyn/mix/LambdaHack-xxx/ LambdaHack

A quick manual playing session after the automated tests would be in order,
as well, since the tests don't touch the topmost UI layer.
Note that a debug option of the form `--stopAfter*` is required to cleanly
terminate any automated test. This is needed to gather any HPC info,
because HPC requires a clean exit to save data files.


Coding style
------------

Stylish Haskell is used for slight auto-formatting at buffer save; see
[.stylish-haskell.yaml](https://github.com/LambdaHack/LambdaHack/blob/master/.stylish-haskell.yaml).
As defined in the file, indentation is 2 spaces wide and screen is
80-columns wide. Spaces, not tabs. Spurious whitespace avoided.
Spaces around arithmetic operators encouraged.
Generally, relax and try to stick to the style apparent in a file
you are editing. Put big formatting changes in separate commits.

Haddocks are provided for all module headers and for all functions and types
from major modules, in particular the modules that are interfaces
for a whole directory of modules. Apart of that only very important
functions and types are distinguished by having a haddock.
If minor ones have comments, they should not be haddocks
and they are permitted to describe implementation details and be out of date.
If not too verbose, use assertions instead of comments.


Further information
-------------------

For more information, visit the wiki[4]
and see [PLAYING.md](https://github.com/LambdaHack/LambdaHack/blob/master/GameDefinition/PLAYING.md),
[CREDITS](https://github.com/LambdaHack/LambdaHack/blob/master/CREDITS)
and [LICENSE](https://github.com/LambdaHack/LambdaHack/blob/master/LICENSE).

Have fun!



[1]: http://www.haskell.org/
[2]: http://roguebasin.roguelikedevelopment.org/index.php?title=Berlin_Interpretation
[3]: http://hackage.haskell.org/package/LambdaHack
[4]: https://github.com/LambdaHack/LambdaHack/wiki
[5]: http://github.com/LambdaHack/LambdaHack
[6]: http://allureofthestars.com
[7]: http://www.haskell.org/platform
[8]: https://github.com/tuturto/space-privateers
[9]: https://github.com/LambdaHack/LambdaHack/wiki/Sample-dungeon-crawler
[10]: https://github.com/AllureOfTheStars/Allure
[11]: https://github.com/LambdaHack/LambdaHack/releases/latest
[13]: http://www.haskell.org/haskellwiki/GHC_under_Wine#Code_that_uses_gtk2hs
[14]: http://www.edsko.net/2014/04/27/haskell-including-gtk-on-mavericks
[15]: https://github.com/ghcjs/ghcjs
[16]: https://www.npmjs.com/package/google-closure-compiler
[17]: https://ci.appveyor.com/project/Mikolaj/lambdahack-4hh0j/build/artifacts
[18]: https://ci.appveyor.com/project/Mikolaj/lambdahack/build/artifacts
