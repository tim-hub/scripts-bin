#!/bin/sh

SRC="$1"
LOW=60


if [ "$1" == "-h" ]  || [ "$1" == "--help" ]; then
    echo "Usage: `basename $0` [-h]/[--help]\n
in a folder containing an image named foo.jpg (or whatever):\n
	./convert.sh foo"
    exit 0
else
	convert $SRC.jpg -quality $LOW low_$SRC.jpg
	convert $SRC.jpg -quality $LOW low_$SRC.webp
	convert $SRC.jpg -quality $LOW -resize 50% "$SRC"_"$LOW"q_50pc.jpg
	convert $SRC.jpg -quality $LOW -resize 50% "$SRC"_"$LOW"q_50pc.webp
fi
# To use this script,
# run the following from a terminal
# in a folder containing an image named foo.jpg (or whatever):
#   chmod u+x convert.sh
#   ./convert.sh foo
