#!/usr/bin/env python3
"""Растеризует assets/icon/IconTint.svg (две иконки 1024x1024 рядом: светлая и тёмная) в PNG.
Мини-растеризатор только под этот файл: rect, circle, path (M C L H V Z), linearGradient. Нужны numpy и Pillow.
Результат: assets/icon/IconTint-{light,dark}-1024.png (мастер) и IconTint-{light,dark}[@2x|@3x].png (60/120/180 px)."""
import re, sys, xml.etree.ElementTree as ET
import numpy as np
from PIL import Image, ImageDraw

SVG = "assets/icon/IconTint.svg"
NS = {"s": "http://www.w3.org/2000/svg"}
SS = 3  # суперсэмплинг

def parse_color(c):
    c = c.lstrip("#"); return np.array([int(c[i:i + 2], 16) for i in (0, 2, 4)], np.float32) / 255

def gradients(root):
    g = {}
    for lg in root.iter("{%s}linearGradient" % NS["s"]):
        stops = []
        for st in lg.findall("s:stop", NS):
            stops.append((float(st.get("offset", "0")), parse_color(st.get("stop-color"))))
        g[lg.get("id")] = dict(p1=(float(lg.get("x1")), float(lg.get("y1"))), p2=(float(lg.get("x2")), float(lg.get("y2"))), stops=stops)
    return g

def fill_array(grad, ox, w, h):
    """Цвет градиента для каждого пикселя области (w×h в юнитах SVG, начало в ox)"""
    (x1, y1), (x2, y2) = grad["p1"], grad["p2"]
    ys, xs = np.mgrid[0:h * SS, 0:w * SS]
    X = (xs + 0.5) / SS + ox; Y = (ys + 0.5) / SS
    dx, dy = x2 - x1, y2 - y1
    t = np.clip(((X - x1) * dx + (Y - y1) * dy) / (dx * dx + dy * dy), 0, 1)
    offs = [o for o, _ in grad["stops"]]; cols = np.array([c for _, c in grad["stops"]])
    out = np.zeros((h * SS, w * SS, 3), np.float32)
    for ch in range(3): out[..., ch] = np.interp(t, offs, cols[:, ch])
    return out

def path_polygons(d, ox):
    toks = re.findall(r"[MCLHVZ]|-?\d*\.?\d+(?:e-?\d+)?", d)
    i = 0; cur = (0.0, 0.0); polys = []; poly = []; cmd = None
    def num():
        nonlocal i; v = float(toks[i]); i += 1; return v
    while i < len(toks):
        if re.match(r"[MCLHVZ]", toks[i]): cmd = toks[i]; i += 1
        if cmd == "M": cur = (num(), num()); poly = [cur]; cmd = "L"
        elif cmd == "L": cur = (num(), num()); poly.append(cur)
        elif cmd == "H": cur = (num(), cur[1]); poly.append(cur)
        elif cmd == "V": cur = (cur[0], num()); poly.append(cur)
        elif cmd == "C":
            p0 = cur; p1 = (num(), num()); p2 = (num(), num()); p3 = (num(), num())
            for k in range(1, 41):
                t = k / 40; a = (1 - t) ** 3; b = 3 * (1 - t) ** 2 * t; c = 3 * (1 - t) * t * t; e = t ** 3
                poly.append((a * p0[0] + b * p1[0] + c * p2[0] + e * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + e * p3[1]))
            cur = p3
        elif cmd == "Z": polys.append(poly); poly = []; i += 0
        else: raise SystemExit("команда пути не поддерживается: %s" % cmd)
    if poly: polys.append(poly)
    return [[(x - ox, y) for x, y in p] for p in polys]

def render(root, grads, ox, size=1024):
    canvas = np.zeros((size * SS, size * SS, 3), np.float32)
    for el in root:
        tag = el.tag.split("}")[1]
        if tag == "defs": continue
        tr = el.get("transform"); tx = 0.0
        if tr: tx = float(re.search(r"translate\(([-\d.]+)", tr).group(1))
        left = tx if tr else (float(el.get("cx", 0)) - float(el.get("r", 0)) if tag == "circle" else 0)
        # элемент относится к нужной иконке, если его x-центр попадает в [ox, ox+size)
        if tag == "rect": cx = tx + size / 2
        elif tag == "circle": cx = float(el.get("cx"))
        else: cx = np.mean([p[0] for pl in path_polygons(el.get("d"), 0) for p in pl])
        if not (ox <= cx < ox + size): continue
        mask = Image.new("L", (size * SS, size * SS), 0); dr = ImageDraw.Draw(mask)
        if tag == "rect": dr.rectangle([0, 0, size * SS, size * SS], fill=255)
        elif tag == "circle":
            x, y, r = float(el.get("cx")) - ox, float(el.get("cy")), float(el.get("r"))
            dr.ellipse([(x - r) * SS, (y - r) * SS, (x + r) * SS, (y + r) * SS], fill=255)
        else:
            for pl in path_polygons(el.get("d"), ox): dr.polygon([(x * SS, y * SS) for x, y in pl], fill=255)
        m = np.asarray(mask, np.float32)[..., None] / 255
        f = el.get("fill")
        col = fill_array(grads[f[5:-1]], ox, size, size) if f.startswith("url(") else parse_color(f)
        canvas = canvas * (1 - m) + col * m
    big = Image.fromarray((np.clip(canvas, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    return big.resize((size, size), Image.LANCZOS)

root = ET.parse(SVG).getroot(); grads = gradients(root)
for name, ox in (("light", 0), ("dark", 1064)):
    im = render(root, grads, ox)
    im.save("assets/icon/IconTint-%s-1024.png" % name)
    for suf, px in (("@3x", 180), ("@2x", 120), ("", 60)):
        im.resize((px, px), Image.LANCZOS).save("assets/icon/IconTint-%s%s.png" % (name, suf))
# Основной значок: диагональ, как плитка «Автоматически» в iOS: слева сверху светлая, справа снизу тёмная (без линии раздела)
light = Image.open("assets/icon/IconTint-light-1024.png").convert("RGB"); dark = Image.open("assets/icon/IconTint-dark-1024.png").convert("RGB")
n = 1024; S = 4
ys, xs = np.mgrid[0:n * S, 0:n * S]
side = ((xs + 0.5) / S + (ys + 0.5) / S > n).astype(np.float32).reshape(n, S, n, S).mean((1, 3))[..., None]
split = np.asarray(light, np.float32) * (1 - side) + np.asarray(dark, np.float32) * side
im = Image.fromarray((split + 0.5).astype(np.uint8), "RGB")
im.save("assets/icon/IconTint-1024.png")
for suf, px in (("@3x", 180), ("@2x", 120), ("", 60)):
    im.resize((px, px), Image.LANCZOS).save("assets/icon/IconTint%s.png" % suf)
print("ok")
