#!/usr/bin/env python3
"""Набор стикеров «Мемы»: котик и ласточка в мемных позах — оригинальные рисунки (векторные, рисуются здесь).

Запуск (нужен Python с playwright и Chromium):  python3 tool/make_meme_stickers.py [папка_вывода]
По умолчанию пишет PNG 512×512 с прозрачным фоном в assets/stickers/.
"""
import base64
import pathlib
import sys

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'assets' / 'stickers'
FONT = base64.b64encode((ROOT / 'assets' / 'fonts' / 'Inter-Bold.ttf').read_bytes()).decode()

# ---------- палитра (как у встроенных наборов «Котик» и «Ласточка») ----------
CAT, CAT_D, CAT_L, PINK, INK = '#F5A44C', '#D97A2B', '#FFE4C4', '#F6A8A8', '#2A2A2E'
NAVY, NAVY_D, BEAK, CHEEK = '#24356F', '#18264F', '#F6A623', '#FF8FA3'
CAPTION = '#FF6A3D'


def eyes(x1, x2, y, kind='normal', r=17):
    """Глаза: normal, wide, squint, closed, sparkle, sad, angry, dead, happy."""
    s = ''
    for x in (x1, x2):
        if kind == 'normal':
            s += f'<ellipse cx="{x}" cy="{y}" rx="{r*0.8}" ry="{r}" fill="{INK}"/><circle cx="{x-r*0.25}" cy="{y-r*0.4}" r="{r*0.3}" fill="#fff"/>'
        elif kind == 'wide':
            s += f'<circle cx="{x}" cy="{y}" r="{r*1.45}" fill="#fff" stroke="{INK}" stroke-width="5"/><circle cx="{x}" cy="{y}" r="{r*0.55}" fill="{INK}"/>'
        elif kind == 'sparkle':
            s += (f'<ellipse cx="{x}" cy="{y}" rx="{r*1.15}" ry="{r*1.35}" fill="{INK}"/>'
                  f'<circle cx="{x-r*0.38}" cy="{y-r*0.5}" r="{r*0.45}" fill="#fff"/><circle cx="{x+r*0.4}" cy="{y+r*0.45}" r="{r*0.22}" fill="#fff"/>'
                  f'<circle cx="{x+r*0.1}" cy="{y-r*0.05}" r="{r*0.12}" fill="#fff"/>')
        elif kind == 'squint':
            s += f'<path d="M{x-r*1.1} {y} Q{x} {y-r*0.55} {x+r*1.1} {y}" fill="none" stroke="{INK}" stroke-width="7" stroke-linecap="round"/><ellipse cx="{x}" cy="{y+2}" rx="{r*0.55}" ry="{r*0.28}" fill="{INK}"/>'
        elif kind == 'closed':
            s += f'<path d="M{x-r} {y-2} Q{x} {y+r*0.7} {x+r} {y-2}" fill="none" stroke="{INK}" stroke-width="7" stroke-linecap="round"/>'
        elif kind == 'happy':
            s += f'<path d="M{x-r} {y+4} Q{x} {y-r*0.9} {x+r} {y+4}" fill="none" stroke="{INK}" stroke-width="7" stroke-linecap="round"/>'
        elif kind == 'sad':
            s += (f'<ellipse cx="{x}" cy="{y+3}" rx="{r*0.75}" ry="{r*0.85}" fill="{INK}"/><circle cx="{x-r*0.22}" cy="{y-r*0.2}" r="{r*0.28}" fill="#fff"/>'
                  f'<path d="M{x-r*1.1} {y-r*1.25} L{x+r*1.0} {y-r*1.75}" stroke="{INK}" stroke-width="6" stroke-linecap="round" transform="{"" if x == x1 else f"scale(-1 1) translate({-2*x} 0)"}"/>')
        elif kind == 'angry':
            s += (f'<ellipse cx="{x}" cy="{y+3}" rx="{r*0.7}" ry="{r*0.75}" fill="{INK}"/><circle cx="{x-r*0.2}" cy="{y-r*0.15}" r="{r*0.25}" fill="#fff"/>')
        elif kind == 'dead':
            d = r * 0.8
            s += f'<path d="M{x-d} {y-d} L{x+d} {y+d} M{x+d} {y-d} L{x-d} {y+d}" stroke="{INK}" stroke-width="7" stroke-linecap="round"/>'
    if kind == 'angry':
        # брови «домиком» к переносице
        s += (f'<path d="M{x1-r*1.2} {y-r*1.7} L{x1+r*0.9} {y-r*0.9}" stroke="{INK}" stroke-width="8" stroke-linecap="round"/>'
              f'<path d="M{x2+r*1.2} {y-r*1.7} L{x2-r*0.9} {y-r*0.9}" stroke="{INK}" stroke-width="8" stroke-linecap="round"/>')
    return s


def cat_head(cx, cy, s=1.0, eye='normal', mouth='w', blush=True, tilt=0, brows=None):
    """Голова котика: уши, полоски, мордочка. Центр (cx, cy), масштаб s."""
    g = f'<g transform="translate({cx} {cy}) rotate({tilt}) scale({s})">'
    # уши
    g += f'<path d="M-118 -40 L-104 -150 L-30 -98 Z" fill="{CAT}" stroke="{CAT_D}" stroke-width="4" stroke-linejoin="round"/>'
    g += f'<path d="M118 -40 L104 -150 L30 -98 Z" fill="{CAT}" stroke="{CAT_D}" stroke-width="4" stroke-linejoin="round"/>'
    g += f'<path d="M-100 -62 L-95 -125 L-50 -95 Z" fill="{PINK}"/><path d="M100 -62 L95 -125 L50 -95 Z" fill="{PINK}"/>'
    # голова
    g += f'<ellipse cx="0" cy="0" rx="135" ry="112" fill="{CAT}" stroke="{CAT_D}" stroke-width="4"/>'
    # полоски на лбу
    g += f'<path d="M-22 -108 Q-18 -80 -26 -62 M0 -112 Q2 -86 0 -66 M22 -108 Q18 -80 26 -62" stroke="{CAT_D}" stroke-width="7" fill="none" stroke-linecap="round"/>'
    # мордочка
    g += f'<ellipse cx="-30" cy="42" rx="46" ry="36" fill="{CAT_L}"/><ellipse cx="30" cy="42" rx="46" ry="36" fill="{CAT_L}"/>'
    if blush:
        g += f'<ellipse cx="-88" cy="38" rx="20" ry="11" fill="{PINK}" opacity=".85"/><ellipse cx="88" cy="38" rx="20" ry="11" fill="{PINK}" opacity=".85"/>'
    g += eyes(-50, 50, -8, eye)
    if brows == 'up':
        g += f'<path d="M-72 -52 Q-50 -66 -28 -54 M28 -54 Q50 -66 72 -52" stroke="{INK}" stroke-width="6" fill="none" stroke-linecap="round"/>'
    # нос
    g += f'<path d="M-11 22 L11 22 L0 34 Z" fill="#E8707A" stroke="#C9505C" stroke-width="2" stroke-linejoin="round"/>'
    # рот
    if mouth == 'w':
        g += f'<path d="M-24 44 Q-12 58 0 44 Q12 58 24 44" fill="none" stroke="{INK}" stroke-width="5" stroke-linecap="round"/>'
    elif mouth == 'o':
        g += f'<ellipse cx="0" cy="56" rx="13" ry="17" fill="#7A2E3A"/>'
    elif mouth == 'flat':
        g += f'<path d="M-18 52 L18 52" stroke="{INK}" stroke-width="5" stroke-linecap="round"/>'
    elif mouth == 'frown':
        g += f'<path d="M-20 60 Q0 44 20 60" fill="none" stroke="{INK}" stroke-width="5" stroke-linecap="round"/>'
    elif mouth == 'open':
        g += f'<path d="M-30 44 Q0 100 30 44 Z" fill="#7A2E3A"/><path d="M-16 66 Q0 86 16 66 Q0 74 -16 66" fill="#FF7E8B"/>'
    elif mouth == 'tongue':
        g += f'<path d="M-22 46 Q0 54 22 46" fill="none" stroke="{INK}" stroke-width="5" stroke-linecap="round"/><path d="M4 50 Q8 76 20 72 Q28 66 22 48 Z" fill="#FF7E8B" stroke="#D9576A" stroke-width="2"/>'
    elif mouth == 'smirk':
        g += f'<path d="M-16 52 Q8 56 26 42" fill="none" stroke="{INK}" stroke-width="5" stroke-linecap="round"/>'
    # усы
    g += f'<path d="M-70 30 L-140 18 M-70 42 L-142 46 M70 30 L140 18 M70 42 L142 46" stroke="{INK}" stroke-width="3" stroke-linecap="round" opacity=".7"/>'
    return g + '</g>'


def cat_body(cx, cy, s=1.0, tail=True):
    """Сидящее туловище (под головой) с пушистым хвостом."""
    g = f'<g transform="translate({cx} {cy}) scale({s})">'
    if tail:
        g += f'<path d="M95 60 Q190 50 170 -40 Q160 -80 132 -66 Q150 -20 120 20 Q100 40 80 40 Z" fill="{CAT}" stroke="{CAT_D}" stroke-width="4" stroke-linejoin="round"/>'
        g += f'<path d="M152 -40 Q160 -10 146 12" stroke="{CAT_D}" stroke-width="7" fill="none" stroke-linecap="round"/>'
    g += f'<ellipse cx="0" cy="40" rx="112" ry="92" fill="{CAT}" stroke="{CAT_D}" stroke-width="4"/>'
    g += f'<ellipse cx="0" cy="54" rx="64" ry="66" fill="{CAT_L}"/>'
    return g + '</g>'


def paw(x, y, s=1.0, rot=0):
    return (f'<g transform="translate({x} {y}) rotate({rot}) scale({s})">'
            f'<ellipse cx="0" cy="0" rx="30" ry="24" fill="{CAT}" stroke="{CAT_D}" stroke-width="4"/>'
            f'<path d="M-10 -14 L-10 0 M2 -16 L2 -1 M14 -12 L14 0" stroke="{CAT_D}" stroke-width="3" stroke-linecap="round"/></g>')


def arm(x1, y1, x2, y2, w=44):
    """Лапа-рука от плеча (x1,y1) до кисти (x2,y2) — толстая скруглённая линия с обводкой."""
    return (f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{CAT_D}" stroke-width="{w+8}" stroke-linecap="round"/>'
            f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{CAT}" stroke-width="{w}" stroke-linecap="round"/>')


def swallow(cx, cy, s=1.0, eye='happy', mouth='smile', wings='down', tilt=0, cheeks=True, brows=None):
    """Ласточка: круглое синее тельце, белая грудка и щёчки, раздвоенный хвост."""
    g = f'<g transform="translate({cx} {cy}) rotate({tilt}) scale({s})">'
    # хвост-вилочка
    g += f'<path d="M-30 100 L-70 190 L-20 128 L0 150 L20 128 L70 190 L30 100 Z" fill="{NAVY_D}"/>'
    # крылья
    if wings == 'up':
        g += f'<path d="M-110 -10 Q-210 -110 -150 -170 Q-120 -90 -80 -50 Z" fill="{NAVY_D}"/>'
        g += f'<path d="M110 -10 Q210 -110 150 -170 Q120 -90 80 -50 Z" fill="{NAVY_D}"/>'
    elif wings == 'cross':
        pass  # рисуются поверх тела
    elif wings == 'hold':
        g += f'<path d="M-118 10 Q-170 60 -90 110 Z" fill="{NAVY_D}"/><path d="M118 10 Q170 60 90 110 Z" fill="{NAVY_D}"/>'
    else:
        g += f'<path d="M-118 0 Q-190 80 -120 130 Q-100 70 -90 40 Z" fill="{NAVY_D}"/><path d="M118 0 Q190 80 120 130 Q100 70 90 40 Z" fill="{NAVY_D}"/>'
    # тельце
    g += f'<ellipse cx="0" cy="0" rx="128" ry="135" fill="{NAVY}"/>'
    g += f'<ellipse cx="0" cy="52" rx="86" ry="80" fill="#fff"/>'
    g += f'<path d="M-92 -40 Q-60 -78 0 -70 Q60 -78 92 -40 Q86 10 0 8 Q-86 10 -92 -40 Z" fill="#fff"/>'
    if cheeks:
        g += f'<ellipse cx="-74" cy="6" rx="18" ry="11" fill="{CHEEK}" opacity=".9"/><ellipse cx="74" cy="6" rx="18" ry="11" fill="{CHEEK}" opacity=".9"/>'
    g += eyes(-44, 44, -30, eye, r=15)
    if brows == 'angry':
        g += f'<path d="M-70 -68 L-24 -50 M70 -68 L24 -50" stroke="{NAVY_D}" stroke-width="9" stroke-linecap="round"/>'
    # клюв/рот
    if mouth == 'smile':
        g += f'<path d="M-26 6 Q0 44 26 6 Z" fill="#D9364A"/><path d="M-14 4 L14 4 L0 -14 Z" fill="{BEAK}"/>'
    elif mouth == 'beak':
        g += f'<path d="M-16 0 L16 0 L0 22 Z" fill="{BEAK}"/>'
    elif mouth == 'pout':
        g += f'<path d="M-18 4 Q0 -8 18 4 L0 16 Z" fill="{BEAK}"/>'
    elif mouth == 'o':
        g += f'<ellipse cx="0" cy="14" rx="14" ry="17" fill="#D9364A"/><path d="M-12 -2 L12 -2 L0 -16 Z" fill="{BEAK}"/>'
    if wings == 'cross':
        g += f'<path d="M-112 30 Q-20 80 70 40 Q40 90 -40 92 Q-100 80 -112 30 Z" fill="{NAVY_D}"/>'
        g += f'<path d="M112 30 Q20 80 -70 40 Q-40 90 40 92 Q100 80 112 30 Z" fill="{NAVY_D}"/>'
    return g + '</g>'


def sweat(x, y, s=1):
    return f'<path transform="translate({x} {y}) scale({s})" d="M0 -26 Q16 0 0 12 Q-16 0 0 -26 Z" fill="#7CC7FF" stroke="#3A8FD6" stroke-width="3"/>'


def sparkle(x, y, s=1, c='#FFD54A'):
    return f'<path transform="translate({x} {y}) scale({s})" d="M0 -22 L6 -6 L22 0 L6 6 L0 22 L-6 6 L-22 0 L-6 -6 Z" fill="{c}"/>'


def heart(x, y, s=1, c='#FF4F6D'):
    return f'<path transform="translate({x} {y}) scale({s})" d="M0 18 C-30 -4 -26 -26 -12 -28 C-4 -29 0 -22 0 -18 C0 -22 4 -29 12 -28 C26 -26 30 -4 0 18 Z" fill="{c}"/>'


def zzz(x, y):
    return (f'<text x="{x}" y="{y}" font-size="54" fill="#7A8BD8" font-family="L" transform="rotate(-12 {x} {y})">Z</text>'
            f'<text x="{x+38}" y="{y-40}" font-size="40" fill="#7A8BD8" font-family="L" transform="rotate(-12 {x+38} {y-40})">z</text>'
            f'<text x="{x+66}" y="{y-72}" font-size="30" fill="#7A8BD8" font-family="L" transform="rotate(-12 {x+66} {y-72})">z</text>')


# ---------- сами стикеры: (ключ, подпись, svg-рисунок в поле 512×420) ----------
def st_lapki():
    return (cat_body(256, 300, 0.95) + cat_head(256, 190, 0.95, eye='sparkle', mouth='w')
            + arm(196, 300, 150, 200) + arm(316, 300, 362, 200)
            + paw(146, 190, 1.05, -20) + paw(366, 190, 1.05, 20)
            + sparkle(90, 120, 1) + sparkle(430, 110, 0.8))


def st_podozr():
    return cat_head(256, 230, 1.35, eye='squint', mouth='flat', blush=False) + sweat(430, 120, 0)


def st_yavse():
    # котик-блинчик лежит на полу
    g = f'<ellipse cx="256" cy="340" rx="200" ry="60" fill="{CAT}" stroke="{CAT_D}" stroke-width="4"/>'
    g += f'<path d="M120 320 Q120 300 140 300 M200 300 Q200 284 220 286 M300 300 Q320 288 330 300" stroke="{CAT_D}" stroke-width="7" fill="none" stroke-linecap="round"/>'
    g += f'<path d="M440 330 Q500 330 490 280" stroke="{CAT_D}" stroke-width="30" fill="none" stroke-linecap="round"/><path d="M440 330 Q500 330 490 280" stroke="{CAT}" stroke-width="22" fill="none" stroke-linecap="round"/>'
    g += cat_head(170, 270, 0.72, eye='dead', mouth='tongue', blush=False, tilt=-14)
    return g


def st_kofe():
    mug = (f'<rect x="196" y="256" width="120" height="120" rx="20" fill="#FFFFFF" stroke="#8A6A55" stroke-width="7"/>'
           f'<path d="M316 284 Q362 284 360 318 Q358 350 316 350" fill="none" stroke="#8A6A55" stroke-width="12"/>'
           f'<rect x="206" y="266" width="100" height="20" rx="8" fill="#7A4A2A"/>'
           f'<path d="M228 240 Q216 220 230 200 Q244 182 232 160 M268 240 Q256 218 270 198 Q284 180 272 158" stroke="#C9C9D6" stroke-width="7" fill="none" stroke-linecap="round"/>')
    return (cat_body(256, 320, 0.9) + cat_head(256, 180, 0.9, eye='angry', mouth='frown', blush=False)
            + mug + paw(196, 316, 0.9, -10) + paw(316, 316, 0.9, 10))


def st_ponedelnik():
    blanket = (f'<path d="M40 300 Q60 220 140 230 Q256 250 372 230 Q452 220 472 300 L480 410 L32 410 Z" fill="#8FA6E8" stroke="#5C74C2" stroke-width="5"/>'
               f'<path d="M80 330 L120 300 M160 340 L200 300 M300 345 L340 305 M380 335 L420 300" stroke="#C7D3F7" stroke-width="7" stroke-linecap="round"/>')
    return cat_head(256, 210, 1.0, eye='sad', mouth='frown', blush=False) + blanket


def st_hochu():
    return (cat_body(256, 310, 0.95) + cat_head(256, 190, 1.0, eye='sparkle', mouth='o', brows='up')
            + paw(226, 300, 0.95, -6) + paw(286, 300, 0.95, 6)
            + heart(90, 110, 1.1) + heart(430, 130, 0.9) + sparkle(420, 60, 0.7))


def st_ponyatiya():
    q = f'<text x="400" y="150" font-size="90" fill="{CAPTION}" font-family="L">?</text><text x="80" y="140" font-size="70" fill="{CAPTION}" font-family="L">?</text>'
    return (cat_body(256, 315, 0.95, tail=False) + arm(186, 300, 110, 250) + arm(326, 300, 402, 250)
            + paw(104, 244, 1.0, -60) + paw(408, 244, 1.0, 60)
            + cat_head(256, 190, 0.95, eye='normal', mouth='flat', brows='up') + q)


def st_shpion():
    wall = f'<rect x="0" y="0" width="200" height="420" fill="#D6D0C8" stroke="#B8B0A6" stroke-width="6"/><path d="M0 120 L200 120 M0 260 L200 260 M100 0 L100 120 M60 120 L60 260 M150 260 L150 420" stroke="#C2BAB0" stroke-width="5"/>'
    return cat_head(250, 210, 1.05, eye='normal', mouth='smirk', tilt=-8) + wall + paw(205, 250, 1.0, 90)


def st_pyatnitsa():
    hat = f'<path d="M210 70 L256 -20 L302 70 Z" fill="#FF6A9A" stroke="#E04B7C" stroke-width="5" stroke-linejoin="round"/><circle cx="256" cy="-22" r="14" fill="#FFD54A"/><path d="M226 50 L286 50 M236 30 L276 30" stroke="#FFE9F0" stroke-width="6"/>'
    conf = ''.join(f'<rect x="{x}" y="{y}" width="16" height="9" rx="2" fill="{c}" transform="rotate({r} {x} {y})"/>'
                   for x, y, c, r in [(70, 90, '#FFD54A', 20), (440, 70, '#4FC3F7', -30), (110, 230, '#FF6A9A', 45), (420, 220, '#7ED957', 10), (60, 330, '#4FC3F7', -20), (450, 340, '#FFD54A', 35), (150, 40, '#7ED957', -40), (370, 30, '#FF6A9A', 15)])
    return conf + f'<g transform="translate(0 70)">{swallow(256, 200, 0.95, eye="happy", mouth="smile", wings="up", tilt=-8)}</g>' + f'<g transform="translate(0 52) rotate(-8 256 200)">{hat}</g>'


def st_dedlain():
    lines = ''.join(f'<path d="M{x} {y} L{x-90} {y}" stroke="#9AA8D6" stroke-width="8" stroke-linecap="round"/>' for x, y in [(130, 170), (110, 230), (140, 290)])
    laptop = (f'<g transform="translate(300 250) rotate(-10)"><rect x="-70" y="-50" width="140" height="92" rx="8" fill="#3C4150" stroke="#23262F" stroke-width="5"/>'
              f'<rect x="-58" y="-40" width="116" height="70" rx="4" fill="#7FD3FF"/><rect x="-90" y="42" width="180" height="14" rx="6" fill="#23262F"/></g>')
    return lines + swallow(280, 210, 0.85, eye='wide', mouth='o', wings='up', tilt=18) + laptop + sweat(430, 110, 1.1) + sweat(160, 90, 0.8)


def st_obida():
    puff = f'<path d="M408 120 q20 -16 34 0 q14 16 -6 30" stroke="#9AA8D6" stroke-width="7" fill="none" stroke-linecap="round"/>'
    return swallow(256, 230, 1.0, eye='angry', mouth='pout', wings='cross', tilt=-10, brows='angry') + puff


def st_slezhu():
    bino = (f'<g transform="translate(256 180)"><circle cx="-46" cy="0" r="40" fill="#3C4150" stroke="#23262F" stroke-width="6"/>'
            f'<circle cx="46" cy="0" r="40" fill="#3C4150" stroke="#23262F" stroke-width="6"/><rect x="-18" y="-16" width="36" height="32" fill="#23262F"/>'
            f'<circle cx="-46" cy="0" r="24" fill="#7FD3FF"/><circle cx="46" cy="0" r="24" fill="#7FD3FF"/><circle cx="-54" cy="-8" r="8" fill="#fff"/><circle cx="38" cy="-8" r="8" fill="#fff"/></g>')
    return swallow(256, 230, 1.0, eye='normal', mouth='beak', wings='hold') + bino


def st_spat():
    pillow = f'<rect x="96" y="300" width="320" height="110" rx="46" fill="#FFFFFF" stroke="#C9CFE8" stroke-width="6"/><path d="M140 320 Q256 340 372 320" stroke="#E1E6F5" stroke-width="6" fill="none"/>'
    cap = f'<path d="M190 120 Q256 20 330 70 Q380 100 400 160 Q350 120 320 130 Z" fill="#7A8BD8" stroke="#5C6DBA" stroke-width="5"/><circle cx="402" cy="166" r="18" fill="#FFFFFF"/>'
    return pillow + swallow(256, 250, 0.95, eye='closed', mouth='beak', wings='down') + cap + zzz(380, 100)


def st_obnimashki():
    s = swallow(330, 240, 0.78, eye='happy', mouth='smile', wings='down', tilt=8)
    c = cat_body(180, 300, 0.8, tail=False) + cat_head(180, 205, 0.8, eye='happy', mouth='w', tilt=-8)
    hug = arm(220, 300, 300, 260, 40) + paw(300, 258, 0.85, 30)
    return s + c + hug + heart(256, 80, 1.3) + heart(160, 70, 0.7) + heart(360, 60, 0.8)


STICKERS = [
    ('m_lapki', 'У меня лапки', st_lapki),
    ('m_podozr', 'Подозрительно…', st_podozr),
    ('m_ya_vse', 'Я всё', st_yavse),
    ('m_kofe', 'Мой кофе!', st_kofe),
    ('m_ponedelnik', 'Понедельник…', st_ponedelnik),
    ('m_hochu', 'Хочу!', st_hochu),
    ('m_ponyatiya', 'Без понятия', st_ponyatiya),
    ('m_shpion', 'Я только посмотреть', st_shpion),
    ('m_pyatnitsa', 'Пятница!', st_pyatnitsa),
    ('m_dedlain', 'Дедлайн!', st_dedlain),
    ('m_obida', 'Обиделась', st_obida),
    ('m_slezhu', 'Слежу', st_slezhu),
    ('m_spat', 'Спать пора', st_spat),
    ('m_obnimashki', 'Обнимашки', st_obnimashki),
]


def page(art, caption):
    # белая обводка вокруг рисунка (как у стикеров в Telegram) и подпись с белой обводкой
    size = 46 if len(caption) <= 12 else 38 if len(caption) <= 16 else 32
    return f'''<!doctype html><html><head><style>
@font-face {{ font-family: L; src: url(data:font/ttf;base64,{FONT}); }}
html,body {{ margin:0; background:transparent; }}
</style></head><body>
<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
<defs><filter id="o" x="-10%" y="-10%" width="120%" height="120%">
<feMorphology in="SourceAlpha" operator="dilate" radius="9" result="d"/>
<feFlood flood-color="#fff"/><feComposite in2="d" operator="in" result="w"/>
<feGaussianBlur in="d" stdDeviation="5" result="b"/><feFlood flood-color="#000" flood-opacity=".18"/><feComposite in2="b" operator="in" result="sh"/>
<feOffset in="sh" dx="0" dy="4" result="sho"/>
<feMerge><feMergeNode in="sho"/><feMergeNode in="w"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
<g filter="url(#o)"><g transform="translate(26 6) scale(0.9)">{art}</g></g>
<text x="256" y="490" text-anchor="middle" font-family="L" font-size="{size}" fill="{CAPTION}" stroke="#fff" stroke-width="12" stroke-linejoin="round" paint-order="stroke">{caption}</text>
</svg></body></html>'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={'width': 512, 'height': 512})
        for key, cap, fn in STICKERS:
            pg.set_content(page(fn(), cap))
            pg.wait_for_timeout(50)
            pg.locator('svg').screenshot(path=str(OUT / f'{key}.png'), omit_background=True)
            print('готово', key)
        b.close()


if __name__ == '__main__':
    main()
