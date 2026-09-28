"""report.py <songs/run dir>: HTML report for a songloop.sh run.

Per song: a contact sheet of every frame, fps/draw samples from the window
title, how the song ended, and the frames the classifier flags (black, flat,
or the highway gone mid-song). Writes index.html and sheet_NN.jpg next to the
song folders.
"""
import html
import os
import re
import statistics
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import screen  # noqa: E402

TW, TH = 320, 180


def sheet(frames, out):
    cols = 6
    rows = max(1, (len(frames) + cols - 1) // cols)
    im = Image.new('RGB', (TW * cols, TH * rows), (20, 20, 20))
    for i, f in enumerate(frames):
        im.paste(Image.open(f).convert('RGB').resize((TW, TH)), ((i % cols) * TW, (i // cols) * TH))
    im.save(out, quality=82)


def song(d):
    frames = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith('.png'))
    log = open(os.path.join(d, 'fps.txt'), encoding='utf-8', errors='replace').read()
    fps = [float(x) for x in re.findall(r'FPS: ([0-9.]+)', log)]
    draws = [int(x) for x in re.findall(r'draws: (\d+)', log)]
    states = [screen.classify(f) for f in frames]
    # Suspect: black/flat anywhere, or a non-play frame between two play frames.
    first = states.index('play') if 'play' in states else len(states)
    last = len(states) - 1 - states[::-1].index('play') if 'play' in states else -1
    flags = [(os.path.basename(f), s) for f, s in zip(frames, states) if s in ('black', 'flat')]
    flags += [(os.path.basename(frames[i]), 'highway gone mid-song')
              for i in range(first + 1, last) if states[i] != 'play']
    end = ('HANG' if 'HANG' in log else 'FAILED' if 'FAILED' in log else 'timeout' if 'TIMEOUT' in log else 'exited' if 'exited' in log
           else 'completed' if 'play' in states else 'never started')
    return {
        'frames': frames, 'played': states.count('play'), 'end': end, 'flags': flags,
        'fps': (statistics.median(fps), min(fps), max(fps)) if fps else None,
        'zero_draw': sum(1 for x in draws if x == 0), 'samples': len(draws),
    }


def main(run):
    songs = sorted(d for d in os.listdir(run) if re.fullmatch(r'\d\d', d))
    rows, blocks = [], []
    for s in songs:
        r = song(os.path.join(run, s))
        img = 'sheet_%s.jpg' % s
        sheet(r['frames'], os.path.join(run, img))
        fps = '%.1f (%.1f-%.1f)' % r['fps'] if r['fps'] else '-'
        rows.append('<tr><td>%s</td><td>%s</td><td>%d / %d</td><td>%s</td><td>%d</td></tr>' % (
            s, r['end'], r['played'], len(r['frames']), fps, len(r['flags'])))
        flags = ''.join('<li>%s: %s</li>' % (html.escape(f), html.escape(w)) for f, w in r['flags'])
        blocks.append('<h2>Song %s: %s</h2><p>fps median (min-max): %s; zero-draw samples: %d of %d</p>'
                      '<ul>%s</ul><img src="%s" alt="song %s frames">' % (
                          s, r['end'], fps, r['zero_draw'], r['samples'], flags or '<li>no flagged frames</li>', img, s))
    page = ('<!doctype html><meta charset="utf-8"><title>GH3 song run</title>'
            '<style>body{font-family:sans-serif;background:#111;color:#ddd;margin:16px}'
            'img{max-width:100%%}table{border-collapse:collapse}td,th{border:1px solid #444;padding:4px 8px}</style>'
            '<h1>GH3 bot-play run: %s</h1><table><tr><th>song</th><th>end</th><th>play frames</th>'
            '<th>fps</th><th>flags</th></tr>%s</table>%s') % (
                html.escape(os.path.basename(os.path.normpath(run))), ''.join(rows), ''.join(blocks))
    open(os.path.join(run, 'index.html'), 'w', encoding='utf-8').write(page)
    print(os.path.join(run, 'index.html'))


if __name__ == '__main__':
    main(sys.argv[1])
