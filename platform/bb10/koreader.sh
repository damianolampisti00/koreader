#!/bin/sh
# KOReader launcher for BlackBerry 10, from a shell (e.g. Term49, or ssh).
cd "${0%/*}" || exit 1
export LD_LIBRARY_PATH="$PWD/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export TESSDATA_PREFIX="$PWD/data"
exec ./luajit reader.lua "$@"
