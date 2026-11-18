#!/bin/bash
# Screenshot every forced screen into $1 and build a contact sheet.
OUT=${1:-/shots}
mkdir -p $OUT
for s in idle armed armed-noart hint kind video audio working:0.42 comet done done-file failed setup1 setup2 setup3 ready; do
  HOVER=0; [ "$s" = hint ] && HOVER=1
  DALL_DEBUG_HOVER=$HOVER /src/docker/shot.sh $s $OUT/${s/:/_}.png ${WAIT:-2}
done
cd $OUT && montage idle.png armed.png armed-noart.png hint.png kind.png video.png audio.png working_0.42.png comet.png done.png done-file.png failed.png setup1.png setup2.png setup3.png ready.png -tile 4x -geometry +4+4 -background '#111' sheet.png
