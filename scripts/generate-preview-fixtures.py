#!/usr/bin/env python3
"""Original fictional metadata and geometric artwork; stdlib only, no downloads."""
from pathlib import Path
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1] / 'Sources/Albumer/Resources/Fixtures'
NAMES = ['Paper Horizons', 'Copper Steps', 'Quiet Geometry', 'Evening Current',
         'Small Hours', 'North Window', 'Distant Rooms', 'Parallel Garden',
         'Open Water', 'Still Lines', 'Field Notes']
ARTISTS = ['Lumen Assembly', 'Copper Avenue', 'Sora Vale', 'Evening Current',
           'Moss Circuit', 'Lumen Assembly', 'Sora Vale', 'Copper Avenue',
           'Moss Circuit', 'Sora Vale', 'Lumen Assembly']
PALETTES = [((231, 222, 202), (44, 73, 78), (193, 84, 52)),
            ((37, 52, 64), (232, 183, 112), (175, 79, 54)),
            ((217, 225, 222), (49, 87, 105), (164, 183, 167)),
            ((95, 60, 74), (239, 205, 163), (197, 128, 109)),
            ((220, 212, 186), (79, 92, 65), (172, 133, 76))]


def png(path, index, avatar=False):
    size = 320
    background, ink, accent = PALETTES[index % len(PALETTES)]
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            color = background
            if avatar:
                if (x-160)**2 + (y-112)**2 < 48**2 or ((x-160)/98)**2 + ((y-270)/100)**2 < 1:
                    color = ink
            else:
                style = index % 3
                if style == 0:
                    if (x-160)**2 + (y-138)**2 < 102**2: color = ink
                    if 72 < x < 248 and 178 < y < 226: color = accent
                elif style == 1:
                    if 45 < x < 128 and 50 < y < 270: color = ink
                    if 148 < x < 275 and 118 < y < 270: color = accent
                    if 169 < x < 254 and 139 < y < 249: color = background
                else:
                    if abs(x-y) < 36 and 36 < x < 284: color = ink
                    if abs(x+y-320) < 36 and 36 < y < 284: color = accent
            row.extend(color)
        rows.append(bytes(row))
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 2, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
    path.write_bytes(data)


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    albums = []
    for index, (name, artist) in enumerate(zip(NAMES, ARTISTS)):
        identifier = f'preview-{index+1:02}'
        artist_id = 'preview-artist-' + artist.lower().replace(' ', '-')
        count = 10 if index == 0 else 8 + index % 6
        albums.append(dict(id=identifier, name=name,
                           artists=[dict(id=artist_id, name=artist,
                                         images=[dict(url=f'albumer-preview://{artist_id}', width=320, height=320)])],
                           album_type='album', images=[dict(url=f'albumer-preview://{identifier}', width=320, height=320)],
                           release_date=f'{2010+index}-04-12', total_tracks=count,
                           preview_tracks=[dict(title=f'Passage {n+1:02}', duration=180000 + ((n+index)*17000) % 120000)
                                           for n in range(count)]))
        png(ROOT / f'{identifier}.png', index)
    for index, artist in enumerate(dict.fromkeys(ARTISTS)):
        png(ROOT / ('preview-artist-' + artist.lower().replace(' ', '-') + '.png'), index, avatar=True)
    (ROOT / 'albums.json').write_text(json.dumps(albums, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
