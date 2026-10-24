"""Modelo do pacer da engine de playback (VMS.Play.Engine.PaceOnce).

Mesma regra, relógio virtual: nada dorme de verdade. Serve para conferir que a
mídia sai no tempo certo em 1x, na metade em 2x, que o trecho anterior ao alvo do
seek sai sem ritmo, e que o áudio não vai junto fora de 1x.

  python pacemodel.py <arquivo.vms> [velocidade] [alvoMsDoInicio]
"""

import sys

import vmslib

MAX_WAIT_MS = 1000
MAX_LAG_MS = 2000


def simulate(path, speed=1.0, seek_offset_ms=0):
    header, blocks = vmslib.load(path, with_data=False)
    v_ts = header.video.timescale or 90000
    a_ts = header.audio.timescale or 8000

    now = 0.0            # relógio virtual, ms
    anchor_valid = False
    anchor_pts = 0
    anchor_wall = 0.0
    has_video = header.video.present
    target = blocks[0].start_unix_ms + seek_offset_ms

    fed_video = fed_audio = burst = anchors = 0
    first_wall = last_wall = None

    for b in blocks:
        # uma origem por trilha: vídeo em 90 kHz, áudio na taxa de amostragem
        first_pts = {}
        for s in b.samples:
            ts = v_ts if s.is_video else a_ts
            first_pts.setdefault(s.track_id, s.pts)
            # âncora A/V (v3): cada trilha datada de quando ELA começou no bloco.
            # Sem âncora, sobra o começo do bloco — a suposição antiga.
            anchor = b.video_anchor_ms if s.is_video else b.audio_anchor_ms
            if not anchor:
                anchor = b.start_unix_ms
            wall = anchor + (s.pts - first_pts[s.track_id]) * 1000 // ts

            in_burst = wall < target
            if in_burst and not s.is_video:
                continue                       # áudio do borrão não é entregue
            if (not s.is_video) and abs(speed - 1.0) > 0.01:
                continue                       # áudio só em 1x

            if (not in_burst) and (s.is_video or not has_video):
                if not anchor_valid:
                    anchor_valid, anchor_pts, anchor_wall = True, s.pts, now
                    anchors += 1
                    wait = 0
                else:
                    rel = (s.pts - anchor_pts) * 1000 // ts
                    rel = round(rel / speed)
                    wait = (anchor_wall + rel) - now
                    if wait > MAX_WAIT_MS or wait < -MAX_LAG_MS:
                        anchor_pts, anchor_wall = s.pts, now
                        anchors += 1
                        wait = 0
                if wait > 0:
                    now += wait

            if in_burst:
                burst += 1
            if s.is_video:
                fed_video += 1
            else:
                fed_audio += 1
            if first_wall is None:
                first_wall = wall
            last_wall = wall

    return dict(elapsed_s=now / 1000.0, media_s=(last_wall - first_wall) / 1000.0,
                video=fed_video, audio=fed_audio, burst=burst, anchors=anchors)


def main():
    path = sys.argv[1]
    speed = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    seek = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    r = simulate(path, speed, seek)
    print('velocidade %.2gx  alvo do seek: +%d ms' % (speed, seek))
    print('  midia entregue: %.1f s   tempo de relogio gasto: %.1f s'
          % (r['media_s'], r['elapsed_s']))
    print('  samples: video=%d audio=%d  (sem ritmo, antes do alvo: %d)'
          % (r['video'], r['audio'], r['burst']))
    print('  ancoragens: %d' % r['anchors'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
