"""screen.py <image>...: classify GH3 frames.

  play     the five fret buttons are on screen (a song is being played)
  black    nearly black
  flat     nearly uniform (a hung or blank frame)
  hiscore  the high-score name entry (pink score rows on the right)
  failed   the "Song Failed" menu (a red frame over the venue; the results
           page that follows a win is neutral grey)
  other    anything else (menus, results, loading, song intro)

Fret-button check: the five buttons sit at fixed places along the bottom of
the highway, so sample a patch at each and ask for the expected hue. Coordinates
are fractions of the frame, so any resolution works.
"""
import sys
from PIL import Image, ImageStat

# (x, y) as fractions of 1280x720, expected dominant channel(s).
FRETS = [((460, 645), 'g'), ((520, 645), 'r'), ((640, 645), 'y'),
         ((760, 645), 'b'), ((830, 645), 'o')]


def hue_ok(rgb, want):
    """The buttons are muted rings, not saturated fills (sampled from frames)."""
    r, g, b = rgb
    if want == 'g': return g > r + 30 and g > b + 30
    if want == 'r': return r > g + 50 and r > b + 40
    if want == 'y': return r > b + 35 and g > b + 35 and abs(r - g) < 30
    if want == 'b': return b > r + 40 and b > g + 10
    if want == 'o': return r > b + 50 and r > g + 20
    return False


def classify(path):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    st = ImageStat.Stat(im.convert('L'))
    if st.mean[0] < 8:
        return 'black'
    if st.stddev[0] < 4:
        return 'flat'
    hits = 0
    for (x, y), want in FRETS:
        cx, cy = x * w // 1280, y * h // 720
        dx, dy = max(2, 12 * w // 1280), max(1, 6 * h // 720)
        patch = im.crop((cx - dx, cy - dy, cx + dx, cy + dy))
        if hue_ok(ImageStat.Stat(patch).mean, want):
            hits += 1
    if hits >= 3:
        return 'play'
    pink = 0
    for y in (190, 240, 290, 340):
        for x in (760, 900, 1050):
            cx, cy = x * w // 1280, y * h // 720
            r, g, b = ImageStat.Stat(im.crop((cx - 6, cy - 3, cx + 6, cy + 3))).mean
            pink += r > g + 25 and b > g + 10
    if pink >= 8:
        return 'hiscore'
    r, g, b = ImageStat.Stat(im.crop((w * 30 // 100, h * 25 // 100, w * 70 // 100, h * 75 // 100))).mean
    # Reddish centre alone also matches some venues' results newspapers; the
    # failed menu sits over the dimmed venue, so both flanks are dark too.
    gray = im.convert('L')
    side = lambda x0, x1: ImageStat.Stat(gray.crop((w * x0 // 100, h * 30 // 100, w * x1 // 100, h * 80 // 100))).mean[0]
    dark = side(5, 25) < 70 and side(75, 95) < 70
    return 'failed' if r > b + 20 and r > g + 15 and dark else 'other'


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(classify(p), p)
