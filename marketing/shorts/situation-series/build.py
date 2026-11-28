#!/usr/bin/env python3
"""엣지영어 상황극 쇼츠/릴스 빌더 (재사용 편집 프로젝트).

사용법:
  python3 build.py episodes/ep01-uh-good.json --src 원본.mp4 --out 결과폴더

에피소드 JSON 만 바꾸면 같은 제목·자막·마지막 학습 화면 디자인으로 새 편이 나온다.
필요: ffmpeg, Pillow, Pretendard 글꼴(fonts/ 에 없으면 npm 으로 자동 내려받음).
"""
import math, argparse, json, os, subprocess, sys, tarfile, glob, shutil
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1080, 1920

# 엣지영어 홈페이지 색 (src/app 기준)
C = {
    "white": (255, 255, 255, 255),
    "yellow": (255, 212, 1, 255),      # #FFD401
    "purple": (125, 95, 255, 255),     # #7D5FFF
    "lavender": (170, 150, 255, 255),  # #AA96FF
    "navy": (20, 15, 51, 255),         # #140F33
    "black": (0, 0, 0, 255),
    "gray": (74, 74, 74, 255),         # #4A4A4A
}

# 레이아웃 (쇼츠·릴스 화면 UI 피하는 안전 영역)
TITLE_TOP = 128
SUB_TOP = 1120
SAFE_W = 880
SUB_W = 800  # 오른쪽 좋아요·댓글 버튼 피하기


def ensure_fonts():
    d = os.path.join(HERE, "fonts")
    need = ["Pretendard-Black.otf", "Pretendard-ExtraBold.otf", "Pretendard-Bold.otf", "Pretendard-SemiBold.otf", "Pretendard-Medium.otf"]
    if all(os.path.exists(os.path.join(d, n)) for n in need):
        return d
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, "_dl")
    os.makedirs(tmp, exist_ok=True)
    subprocess.run(["npm", "pack", "pretendard@1.3.9"], cwd=tmp, check=True, capture_output=True)
    with tarfile.open(glob.glob(os.path.join(tmp, "*.tgz"))[0]) as t:
        t.extractall(tmp, filter="data")
    for n in need:
        shutil.copy(glob.glob(os.path.join(tmp, "package", "**", n), recursive=True)[0], d)
    shutil.rmtree(tmp)
    return d


FONT_DIR = None


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, f"Pretendard-{weight}.otf"), size)


def seg_line(draw, segs, f, cx, y, stroke, stroke_fill=C["black"]):
    """색이 섞인 한 줄을 가운데 정렬로 그린다. segs = [[text, color], ...]"""
    runs = []
    for t, col in segs:
        for kind, part in split_emoji(t):
            runs.append((kind, part, col))
    def rw(kind, part):
        return f.size * 1.15 * len(part) if kind == "emoji" else f.getlength(part)
    total = sum(rw(k, p) for k, p, _ in runs)
    x = cx - total / 2
    for kind, part, col in runs:
        if kind == "emoji":
            for ch in part:
                paste_emoji(draw, ch, x + f.size * 0.08, y + f.size * 0.12, f.size)
                x += f.size * 1.15
        else:
            draw.text((x, y), part, font=f, fill=C[col], stroke_width=stroke, stroke_fill=stroke_fill)
            x += f.getlength(part)


EMOJI_FONT = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"


def split_emoji(t):
    """글자/이모지 구간 나누기 (이모지는 Noto Color Emoji 로 그림)."""
    out = []
    for ch in t:
        if ch == "\ufe0f":
            continue
        k = "emoji" if ord(ch) >= 0x2600 and not (0xAC00 <= ord(ch) <= 0xD7A3 or 0x3130 <= ord(ch) <= 0x318F) else "text"
        if out and out[-1][0] == k:
            out[-1][1] += ch
        else:
            out.append([k, ch])
    return out


def paste_emoji(draw, ch, x, y, size):
    ef = ImageFont.truetype(EMOJI_FONT, 109)
    g = Image.new("RGBA", (136, 128), (0, 0, 0, 0))
    ImageDraw.Draw(g).text((0, 0), ch, font=ef, embedded_color=True)
    g = g.crop(g.getbbox()).resize((size, size), Image.LANCZOS)
    draw._image.alpha_composite(g, (int(x), int(y)))


def fit_size(lines, weight, size, max_w):
    while size > 30:
        f = font(weight, size)
        if all(sum(f.getlength(t) for t, _ in segs) <= max_w for segs in lines):
            return f
        size -= 2
    return font(weight, size)


def render_title(ep, path):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    band = ep.get("title_band")
    if band:  # 위쪽 검은 띠 + 큰 제목 (채널 목록·쇼츠 화면에서 잘 보임. EP03부터 기본)
        d.rectangle([0, 0, W, band], fill=(0, 0, 0, 255))
        f = fit_size(ep["title"], "Black", 104, W - 80)
        lh = int(f.size * 1.25)
        y = 110 + (band - 110 - lh * len(ep["title"])) / 2 + 6
        pr = ep.get("top_promo")
        if pr:  # 맨 위 채널 소개 문구 (인스타 기본 글씨처럼: 흰 글씨 + 얇은 검정 외곽선, 제목보다 작게)
            fpm = font("Medium", pr.get("size", 40))
            py = pr.get("top", 160)
            pimg = Image.new("RGBA", (W, H), (0, 0, 0, 0)) if pr.get("start") is not None else img
            pd = ImageDraw.Draw(pimg)
            for t in pr["lines"]:
                pd.text((W / 2, py), t, font=fpm, fill=(255, 255, 255, 255), anchor="mt", stroke_width=2, stroke_fill=(0, 0, 0, 255))
                py += int(fpm.size * 1.3)
            if pimg is not img:  # 중간에 나타나는 홍보 문구는 따로 저장
                pimg.save(path.replace("title.png", "promo.png"))
            y = pr.get("title_top", py + pr.get("gap", 40))
        for segs in ep["title"]:
            seg_line(d, segs, f, W / 2, y, 0)
            y += lh
        img.save(path)
        return
    f = fit_size(ep["title"], "Black", 80, SAFE_W + 60)
    y = TITLE_TOP
    for segs in ep["title"]:
        seg_line(d, segs, f, W / 2, y, 8)
        y += int(f.size * 1.22)
    img.save(path)


def render_sub(sub, path):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    fe = fit_size(sub["en"], "ExtraBold", 66, SUB_W)
    fk = fit_size([[[k, "white"]] for k in sub["ko"]], "Bold", sub.get("ko_size", 50), SUB_W)
    y = sub.get("top", SUB_TOP)
    for segs in sub["en"]:
        seg_line(d, segs, fe, W / 2, y, 7)
        y += int(fe.size * 1.2)
    y += 10
    for k in sub["ko"]:
        seg_line(d, [[k, "white"]], fk, W / 2, y, 6)
        y += int(fk.size * 1.3)
    img.save(path)


def render_badge(b, path):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = font("ExtraBold", b.get("size", 44))
    cx, cy = b["center"]
    lines = b["text"].split("\n")
    pitch = int(f.size * 1.25)
    y0 = cy - pitch * (len(lines) - 1) / 2
    for i, t in enumerate(lines):
        seg_line(d, [[t, b.get("color", "white")]], f, cx, y0 + pitch * i - f.size / 2 - 6, 6)
    img.save(path)


def render_outro(ep, bg_frame, path):
    o = ep["outro"]
    bg = Image.open(bg_frame).convert("RGB").resize((W, H)).filter(ImageFilter.GaussianBlur(28))
    tint = Image.new("RGB", (W, H), (243, 240, 255))  # 연보라 바탕
    img = Image.blend(bg, tint, 0.86).convert("RGBA")
    d = ImageDraw.Draw(img)

    fl = font("ExtraBold", 50)
    card_x = [70, W - 70]
    fe = fit_size([[[t, "navy"]] for t in o["en"]], "Black", 92, card_x[1] - card_x[0] - 90)
    fp = fit_size([[[o["pron"], "purple"]]], "SemiBold", 44, card_x[1] - card_x[0] - 90) if o.get("pron") else None
    fk = fit_size([[[o["ko"], "gray"]]], "Bold", 46, card_x[1] - card_x[0] - 90)
    fs = font("Bold", 57)
    fq = font("SemiBold", 55)
    fb = font("ExtraBold", 57)
    fbr = font("Black", 40)
    subs = o["subscribe"] if isinstance(o["subscribe"], list) else [o["subscribe"]]

    # 세로 배치 계산 (EP01 간격 기준, 길어지면 위로 올림)
    def layout(top):
        L = {"label": top, "card_top": top + 140}
        y = L["card_top"] + 90
        L["en"] = y
        y += int(fe.size * 1.2) * len(o["en"])
        if fp:
            L["pron"] = y + 8
            y += fp.size + 30
        L["div"] = y + 22
        L["ko"] = y + 62
        L["card_bot"] = y + 62 + fk.size + 62
        L["sub"] = L["card_bot"] + 85
        L["q"] = L["sub"] + 115 + 72 * (len(subs) - 1)
        L["btn"] = L["q"] + 85
        L["brand"] = L["btn"] + 185
        return L
    L = layout(0)
    L = layout(min(330, 1460 - (L["brand"] + 40)))

    # 1) 라벨 (보라 알약)
    lw = fl.getlength(o["label"]) + 72
    ly = L["label"]
    d.rounded_rectangle([(W - lw) / 2, ly, (W + lw) / 2, ly + 92], radius=46, fill=C["purple"])
    d.text((W / 2, ly + 46), o["label"], font=fl, fill=C["white"], anchor="mm")

    # 2) 학습 표현 카드 (가장 크게)
    card = [card_x[0], L["card_top"], card_x[1], L["card_bot"]]
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([card[0], card[1] + 14, card[2], card[3] + 14], radius=44, fill=(125, 95, 255, 70))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18)))
    d.rounded_rectangle(card, radius=44, fill=C["white"], outline=C["lavender"], width=4)
    y = L["en"]
    for t in o["en"]:
        d.text((W / 2, y), t, font=fe, fill=C["navy"], anchor="mt")
        y += int(fe.size * 1.2)
    if fp:  # 한글 발음
        d.text((W / 2, L["pron"]), o["pron"], font=fp, fill=C["purple"], anchor="mt")
    d.line([(W / 2 - 60, L["div"]), (W / 2 + 60, L["div"])], fill=C["lavender"], width=5)
    d.text((W / 2, L["ko"]), o["ko"], font=fk, fill=C["gray"], anchor="mt")

    # 3) 구독 문구
    for i, t in enumerate(subs):
        d.text((W / 2, L["sub"] + 72 * i), t, font=fs, fill=C["navy"], anchor="mt")

    # 4) 레벨테스트 안내
    d.text((W / 2, L["q"]), o["cta_question"], font=fq, fill=C["gray"], anchor="mt")
    bw = fb.getlength(o["cta_button"]) + 90
    by = L["btn"]
    d.rounded_rectangle([(W - bw) / 2, by, (W + bw) / 2, by + 124], radius=62, fill=C["navy"])
    d.text((W / 2, by + 62), o["cta_button"], font=fb, fill=C["white"], anchor="mm")

    # 5) 브랜드
    brand = o["brand"]
    sp = 10
    total = sum(fbr.getlength(ch) for ch in brand) + sp * (len(brand) - 1)
    x = W / 2 - total / 2
    for ch in brand:
        d.text((x, L["brand"]), ch, font=fbr, fill=C["purple"])
        x += fbr.getlength(ch) + sp
    img.convert("RGB").save(path)


def render_outro_steps(ep, bg_frame, lay):
    """학습 화면 여러 단계 (질문 → 표현 1·2·3 → 정리). 카드 아래 구독·레벨테스트는 계속 보임."""
    o = ep["outro"]
    bg = Image.open(bg_frame).convert("RGB").resize((W, H)).filter(ImageFilter.GaussianBlur(28))
    tint = Image.new("RGB", (W, H), (243, 240, 255))
    base_bg = Image.blend(bg, tint, 0.86).convert("RGBA")
    inner = W - 140 - 90
    fl = font("ExtraBold", 50)
    fs, fq, fb, fbr = font("Bold", 57), font("SemiBold", 55), font("ExtraBold", 57), font("Black", 40)
    subs = o["subscribe"] if isinstance(o["subscribe"], list) else [o["subscribe"]]

    def card_content(st, d, top, draw_it):
        """카드 안 내용 높이를 돌려주고, draw_it 이면 그린다."""
        y = top
        k = st["type"]
        def put(text, f, col, gap):
            nonlocal y
            if draw_it:
                d.text((W / 2, y), text, font=f, fill=C[col], anchor="mt")
            y += gap
        if k == "question":
            fe = fit_size([[[t, "navy"]] for t in st["en"]], "Black", 76, inner)
            for t in st["en"]:
                put(t, fe, "navy", int(fe.size * 1.2))
            y += 20
            if draw_it:
                d.line([(W / 2 - 60, y), (W / 2 + 60, y)], fill=C["lavender"], width=5)
            y += 40
            put(st["ko"], font("Bold", 50), "gray", 50)
        elif k == "expr":
            put(st["num"], font("ExtraBold", 40), "purple", 70)
            put(st["ko"], fit_size([[[st["ko"], "gray"]]], "Bold", 52, inner), "gray", 82)
            fe = fit_size([[[t, "navy"]] for t in st["en"]], "Black", 88, inner)
            for t in st["en"]:
                put(t, fe, "navy", int(fe.size * 1.2))
            y += 6
            put(st["pron"], fit_size([[[st["pron"], "purple"]]], "SemiBold", 46, inner), "purple", 46)
        elif k == "recap":
            for r in st["rows"]:
                put(r["en"], fit_size([[[r["en"], "navy"]]], "ExtraBold", 56, inner), "navy", 70)
                put(r["ko"], font("Bold", 38), "gray", 38 + 40)
            y -= 40
        return y - top

    tmp = ImageDraw.Draw(base_bg.copy())
    ch = max(card_content(st, tmp, 0, False) for st in o["steps"])
    card_h = ch + 90 + 80
    top = min(330, 1460 - (140 + card_h + 85 + 115 + 72 * (len(subs) - 1) + 85 + 185 + 40))
    card = [70, top + 140, W - 70, top + 140 + card_h]
    paths = []
    for j, st in enumerate(o["steps"]):
        img = base_bg.copy()
        d = ImageDraw.Draw(img)
        label = st.get("label", o["label"])
        lw = fl.getlength(label) + 72
        d.rounded_rectangle([(W - lw) / 2, top, (W + lw) / 2, top + 92], radius=46, fill=C["purple"])
        d.text((W / 2, top + 46), label, font=fl, fill=C["white"], anchor="mm")
        sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([card[0], card[1] + 14, card[2], card[3] + 14], radius=44, fill=(125, 95, 255, 70))
        img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18)))
        d.rounded_rectangle(card, radius=44, fill=C["white"], outline=C["lavender"], width=4)
        h = card_content(st, d, 0, False)
        card_content(st, d, card[1] + (card_h - h) / 2, True)
        y = card[3] + 85
        for i, t in enumerate(subs):
            d.text((W / 2, y + 72 * i), t, font=fs, fill=C["navy"], anchor="mt")
        y += 115 + 72 * (len(subs) - 1)
        d.text((W / 2, y), o["cta_question"], font=fq, fill=C["gray"], anchor="mt")
        y += 85
        bw = fb.getlength(o["cta_button"]) + 90
        d.rounded_rectangle([(W - bw) / 2, y, (W + bw) / 2, y + 124], radius=62, fill=C["navy"])
        d.text((W / 2, y + 62), o["cta_button"], font=fb, fill=C["white"], anchor="mm")
        y += 185
        sp = 10
        tot = sum(fbr.getlength(c) for c in o["brand"]) + sp * (len(o["brand"]) - 1)
        x = W / 2 - tot / 2
        for c in o["brand"]:
            d.text((x, y), c, font=fbr, fill=C["purple"])
            x += fbr.getlength(c) + sp
        pth = f"{lay}/outro{j}.png"
        img.convert("RGB").save(pth)
        paths.append(pth)
    return paths


def render_outro_clean(ep, bg_frame, lay):
    """깔끔한 학습 화면: 한 화면에 하나씩 크게 (intro → expr → end). EP02부터 기본."""
    o = ep["outro"]
    bg = Image.open(bg_frame).convert("RGB").resize((W, H)).filter(ImageFilter.GaussianBlur(28))
    tint = Image.new("RGB", (W, H), (243, 240, 255))
    base_bg = Image.blend(bg, tint, 0.88).convert("RGBA")
    inner = W - 2 * 90
    CY = 840  # 화면 가운데 (쇼츠·릴스 위아래 UI 피함)
    paths = []
    for j, st in enumerate(o["steps"]):
        img = base_bg.copy()
        d = ImageDraw.Draw(img)
        items = []  # (text, font, color, height)
        k = st["type"]
        if k == "intro":
            f = fit_size([[[t, "navy"]] for t in st["lines"]], "Black", 92, inner)
            for i, t in enumerate(st["lines"]):
                items.append((t, f, "purple" if i == len(st["lines"]) - 1 else "navy", int(f.size * 1.3)))
        elif k == "expr":
            fk = fit_size([[[st["ko"], "gray"]]], "Bold", 60, inner)
            items.append((st["ko"], fk, "gray", int(fk.size * 1.9)))
            fe = fit_size([[[t, "navy"]] for t in st["en"]], "Black", 104, inner)
            for t in st["en"]:
                items.append((t, fe, "navy", int(fe.size * 1.2)))
            fp = fit_size([[[st["pron"], "purple"]]], "SemiBold", 54, inner)
            items.append(("", fp, "purple", 30))
            items.append((st["pron"], fp, "purple", fp.size))
        elif k == "end":
            f = fit_size([[[t, "navy"]] for t in st["lines"]], "Black", 80, inner)
            for i, t in enumerate(st["lines"]):
                items.append((t, f, "purple" if i == len(st["lines"]) - 1 else "navy", int(f.size * 1.35)))
        btn_h = 140 if st.get("button") else 0
        total = sum(h for *_, h in items) + (90 + btn_h if btn_h else 0)
        y = CY - total / 2
        if k == "expr":  # 흰 카드
            pad = 80
            card = [60, y - pad, W - 60, y + total + pad - 10]
            sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(sh).rounded_rectangle([card[0], card[1] + 14, card[2], card[3] + 14], radius=48, fill=(125, 95, 255, 70))
            img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18)))
            d.rounded_rectangle(card, radius=48, fill=C["white"], outline=C["lavender"], width=4)
        for t, f, col, h in items:
            if t:
                d.text((W / 2, y), t, font=f, fill=C[col], anchor="mt")
            y += h
        if btn_h:
            y += 90
            fb = font("ExtraBold", 62)
            bw = fb.getlength(st["button"]) + 110
            d.rounded_rectangle([(W - bw) / 2, y, (W + bw) / 2, y + btn_h], radius=btn_h / 2, fill=C["navy"])
            d.text((W / 2, y + btn_h / 2), st["button"], font=fb, fill=C["white"], anchor="mm")
        pth = f"{lay}/outro{j}.png"
        img.convert("RGB").save(pth)
        paths.append(pth)
    return paths


def render_learn(ep, bg_frame, lay, end, v, timing):
    """EP02 최종본(대표 업로드) 학습 화면 디자인 — EP03부터 기본 템플릿.
    흐린 상황극 배경(블러 40, 밝기 0.65) + 위 노란 둥근 제목 + 점 3개 + 한국어 → 영어(노랑 강조) + 한글 발음.
    돌려주는 값: [(그림, 시작, 끝, 페이드)]"""
    o = ep["outro"]
    K = o.get("text_scale", 1.0)  # 학습 화면 글씨 배율 (EP03부터 1.15)
    Z = lambda v: int(round(v * K))
    YEL = (254, 209, 0, 255)
    bg = Image.open(bg_frame).convert("RGB").resize((W, H)).filter(ImageFilter.GaussianBlur(40))
    bg = Image.eval(bg, lambda px: int(px * 0.65)).convert("RGBA")
    T0 = end + v["at"]
    seg = {t["i"]: t for t in timing}

    DY = o.get("content_dy", 0)  # 학습 화면 내용 전체를 아래로 (위에 홍보 문구가 있을 때)
    def base(dots=None):
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        f = font("Black", Z(53))
        tw = f.getlength(o["label"])
        ph = Z(91)
        d.rounded_rectangle([W / 2 - tw / 2 - Z(40), 250, W / 2 + tw / 2 + Z(40), 250 + ph], radius=ph // 2, fill=YEL)
        d.text((W / 2, 250 + ph / 2), o["label"], font=f, fill=(17, 17, 17, 255), anchor="mm")
        if dots is not None:
            dy = 430 + (ph - 91)
            for k, x in enumerate([540 - Z(44), 540, 540 + Z(44)]):
                r = Z(11) if k == dots else Z(8)
                d.ellipse([x - r, dy - r, x + r, dy + r], fill=YEL if k == dots else (205, 205, 210, 255))
        return img, d

    def ko_lines(d, lines, cy, size=57, underline=None, px=None):
        f = fit_size([[[t, "white"]] for t in lines], "Black", px or Z(size), W - 80)
        pitch = int(f.size * 1.49)
        y0 = cy - pitch * (len(lines) - 1) / 2
        for i, t in enumerate(lines):
            if underline and t.startswith(underline):  # 노란 형광펜 물결 밑줄 (이어진 물결, 글자 바로 아래)
                x0 = W / 2 - f.getlength(t) / 2
                x1 = x0 + f.getlength(underline)
                yb = y0 + pitch * i + f.size * 0.66
                amp, wl = f.size * 0.07, f.size * 0.42
                pts = [(x0 + k, yb + amp * math.sin(k / wl * 2 * math.pi)) for k in range(0, int(x1 - x0) + 1, 2)]
                lay_ = Image.new("RGBA", (W, H), (0, 0, 0, 0))
                ImageDraw.Draw(lay_).line(pts, fill=(254, 209, 0, 255), width=max(8, int(f.size * 0.13)), joint="curve")
                d._image.alpha_composite(lay_)
            d.text((W / 2, y0 + pitch * i), t, font=f, fill=C["white"], anchor="mm", stroke_width=6, stroke_fill=C["black"])

    out = []
    def save(img, name):
        p = f"{lay}/{name}.png"
        fr = bg.copy()
        sh_ = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sh_.paste(img, (0, DY))
        fr.alpha_composite(sh_)
        fr.convert("RGB").save(p)
        return p

    steps = o["steps"]
    EN_PX = min(fit_size([[[st["en"], "white"]]], "Black", Z(87), W - 70).size for st in steps if st["type"] == "expr")
    starts = []
    for st in steps:
        starts.append(end if st["type"] == "intro" else T0 + seg[st["line"]]["start"] - 0.08)
    for j, st in enumerate(steps):
        nxt = starts[j + 1] if j + 1 < len(steps) else 9999
        if st["type"] == "intro":
            img, d = base()
            ko_lines(d, st["lines"], 820 + Z(0))
            out.append((save(img, f"learn{j}"), starts[j], nxt, 0.3))
        elif st["type"] == "expr":
            img, d = base(st["n"] - 1)
            e = Z(91) - 91
            # 영어: 한 줄에 Z(87) 로 안 들어가면 두 줄로 나눠 크게 (강조 단어 노랑)
            C["yellow_hl"] = YEL
            full = st["en"]
            hl = st.get("highlight", "")
            words = full.split(" ")
            hs = full.index(hl) if hl and hl in full else -1
            def wcol(k):
                pos = len(" ".join(words[:k])) + (1 if k else 0)
                return "yellow_hl" if hs >= 0 and hs <= pos < hs + len(hl) else "white"
            def line_segs(ws):
                out_, k0 = [], ws[0]
                for k in range(ws[0], ws[1]):
                    t = words[k] + (" " if k < ws[1] - 1 else "")
                    col = wcol(k)
                    if out_ and out_[-1][1] == col:
                        out_[-1][0] += t
                    else:
                        out_.append([t, col])
                return out_
            f1 = font("Black", Z(87))
            if st.get("en_lines"):  # 의미 단위로 나눈 줄 (예: "This isn't" / "the room I booked.") — 길면 이 방식 권장
                lines_, k = [], 0
                for ln in st["en_lines"]:
                    n = len(ln.split(" "))
                    lines_.append(line_segs((k, k + n)))
                    k += n
                fe = fit_size(lines_, "Black", Z(87), W - 70)
            elif f1.getlength(full) <= W - 70 or not o.get("en_wrap", False):  # 기본: 한 줄 (가독성 우선, 억지로 키우지 않음)
                lines_ = [line_segs((0, len(words)))]
                fe = fit_size(lines_, "Black", Z(87), W - 40)  # 한 줄로 들어가는 가장 큰 크기
            else:
                best = min(range(1, len(words)), key=lambda k: abs(len(" ".join(words[:k])) - len(" ".join(words[k:]))))
                lines_ = [line_segs((0, best)), line_segs((best, len(words)))]
                fe = fit_size(lines_, "Black", Z(87), W - 70)
            pitch = int(fe.size * 1.15)
            extra = pitch * (len(lines_) - 1)
            ko_lines(d, [st["ko"]], 757 + e * 2 - extra / 2, px=min(Z(57), int(fe.size * 0.9)))  # 한국어가 영어보다 커지지 않게
            out.append((save(img, f"learn{j}a"), starts[j], nxt, 0.2 if st["n"] == 1 else 0))
            ycen = 919 + e * 3 - extra / 2
            for li, segs in enumerate(lines_):
                seg_line(d, segs, fe, W / 2, ycen + pitch * li - fe.size * 0.62, Z(9))
            fp = font("SemiBold", min(Z(46), int(fe.size * 0.8)))
            d.text((W / 2, 1058 + e * 4 + extra / 2), st["pron"], font=fp, fill=(228, 228, 228, 255), anchor="mm", stroke_width=4, stroke_fill=C["black"])
            if st.get("note"):  # 짧은 주의 문구 (발음 아래, 작게)
                fn = fit_size([[[st["note"], "white"]]], "SemiBold", Z(34), W - 80)
                d.text((W / 2, 1058 + e * 4 + extra / 2 + Z(78)), st["note"], font=fn, fill=(228, 228, 228, 255), anchor="mm", stroke_width=3, stroke_fill=C["black"])
            en_start = T0 + seg[st["en_line"]]["start"] - 0.08
            out.append((save(img, f"learn{j}b"), en_start, nxt, 0.2))
        elif st["type"] == "end":
            img, d = base()
            e = Z(91) - 91
            if st.get("button"):
                ko_lines(d, st["lines"], 780 + e, 61, st.get("underline"))
                f = font("Black", Z(59))
                tw = f.getlength(st["button"])
                bh = Z(101)
                d.rounded_rectangle([W / 2 - tw / 2 - Z(52), 940 + e * 3, W / 2 + tw / 2 + Z(52), 940 + e * 3 + bh], radius=bh // 2, fill=YEL)
                d.text((W / 2, 940 + e * 3 + bh / 2), st["button"], font=f, fill=(17, 17, 17, 255), anchor="mm")
                ko_lines(d, [st.get("brand", "엣지영어")], 1188 + e * 5, 62)
            else:  # 노란 버튼 없이 글 줄만 (행간 같게) + 엣지영어
                n = len(st["lines"])
                cy = 860 + e * 2
                ko_lines(d, st["lines"], cy, 61, st.get("underline"))
                yb = cy + Z(61) * 1.49 * (n - 1) / 2 + Z(61) * 2.4
                if st.get("promo_lines"):  # '엣지영어' 대신 채널 소개 문구 (맨 위 문구와 같은 모양)
                    fpm = font("Medium", st.get("promo_size", 44))
                    py = yb - fpm.size * 0.65
                    for t in st["promo_lines"]:
                        d.text((W / 2, py), t, font=fpm, fill=(255, 255, 255, 255), anchor="mt", stroke_width=2, stroke_fill=(0, 0, 0, 255))
                        py += int(fpm.size * 1.3)
                elif st.get("brand", "엣지영어"):
                    ko_lines(d, [st.get("brand", "엣지영어")], yb, 62)
            out.append((save(img, f"learn{j}"), starts[j], nxt, 0))
    return out


def main():
    global FONT_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("episode")
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    ep = json.load(open(a.episode, encoding="utf-8"))
    FONT_DIR = ensure_fonts()
    out = os.path.abspath(a.out)
    lay = os.path.join(out, "layers", ep["id"])
    os.makedirs(lay, exist_ok=True)

    rt = ep.get("retime")
    if rt:  # 장면 한 구간 느리게 + 확대 (원본 시각 기준으로 적은 값들을 뒤로 밀어 줌)
        d_ = (rt["end"] - rt["start"]) * (rt["factor"] - 1)
        sh = lambda t: t if t <= rt["start"] else (rt["start"] + (t - rt["start"]) * rt["factor"] if t <= rt["end"] else t + d_)
        ep["scene_end"] = round(sh(ep["scene_end"]), 3)
        for b in ep.get("badges", []):
            b["start"], b["end"] = sh(b["start"]), sh(b["end"])
            if b.get("track"):
                b["track"] = [[round(sh(k[0]), 3), k[1], k[2]] for k in b["track"]]
        for x in ep.get("subs", []):
            x["start"], x["end"] = sh(x["start"]), sh(x["end"])
        z0, s0, s1, F = rt.get("zoom", 1.0), rt["start"], rt["end"], rt["factor"]
        fx, fy = rt.get("focus", [W / 2, H / 2])
        dur = (s1 - s0) * F
        p = f"min(t/{rt.get('zoom_in', 0.5)},1)"
        zz = f"(1+({z0}-1)*(0.5-0.5*cos(PI*{p})))"
        edit = f"{lay}/src_edit.mp4"
        fcr = (f"[0:v]trim=0:{s0},setpts=PTS-STARTPTS[a];"
               f"[0:v]trim={s0}:{s1},setpts=(PTS-STARTPTS)*{F},fps=30,"
               f"scale=w='trunc({W}*{zz}/2)*2':h='trunc({H}*{zz}/2)*2':eval=frame:flags=lanczos,"
               f"crop={W}:{H}:x='min(max({fx}*(iw/{W})-{fx},0),iw-{W})':y='min(max({fy}*(ih/{H})-{fy},0),ih-{H})'[b];"
               f"[0:v]trim=start={s1},setpts=PTS-STARTPTS[c];"
               f"[a]fps=30,setsar=1[a2];[b]setsar=1[b2];[c]fps=30,setsar=1[c2];[a2][b2][c2]concat=n=3:v=1:a=0[v];"
               f"[0:a]atrim=0:{s0},asetpts=PTS-STARTPTS[x];[0:a]atrim={s0}:{s1},asetpts=PTS-STARTPTS[y1];"
               f"[0:a]atrim={s1 - d_ - 0.08}:{s1},asetpts=PTS-STARTPTS[y2];[y1][y2]acrossfade=d=0.08,volume={rt.get('audio_gain', 1.0)}[y];"  # 소리는 늘이지 않고 같은 배경음을 이어 붙임
               f"[0:a]atrim=start={s1},asetpts=PTS-STARTPTS[z];[x][y][z]concat=n=3:v=0:a=1[aud]")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", a.src, "-filter_complex", fcr, "-map", "[v]", "-map", "[aud]",
                        "-c:v", "libx264", "-crf", "14", "-preset", "medium", "-c:a", "pcm_s16le", edit.replace(".mp4", ".mov")], check=True)
        a.src = edit.replace(".mp4", ".mov")
    end = ep["scene_end"]
    ep_dir = os.path.join(os.path.dirname(os.path.abspath(a.episode)), "..")
    v = ep["outro"].get("voice")
    timing = json.load(open(os.path.join(ep_dir, v["timing"]), encoding="utf-8")) if v and v.get("timing") else None
    if ep["outro_duration"] == "auto":  # 음성 끝 + 여운
        ep["outro_duration"] = round(v["at"] + timing[-1]["end"] + ep["outro"].get("hold", 1.2), 2)
    total = end + ep["outro_duration"]

    # 레이어 그리기
    render_title(ep, f"{lay}/title.png")
    for i, s in enumerate(ep["subs"]):
        render_sub(s, f"{lay}/sub{i}.png")
    for i, b in enumerate(ep.get("badges", [])):
        render_badge(b, f"{lay}/badge{i}.png")
        if b.get("track"):  # 움직이는 자막: 글자 부분만 잘라 두고 위치를 프레임마다 옮김
            im = Image.open(f"{lay}/badge{i}.png")
            bb = im.getbbox()
            im.crop(bb).save(f"{lay}/badge{i}.png")
            b["_size"] = (bb[2] - bb[0], bb[3] - bb[1])
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(end - 0.1), "-i", a.src, "-frames:v", "1", f"{lay}/last.png"], check=True)
    step_imgs, step_win, step_fade = [], [], []
    if ep["outro"].get("style") == "learn":
        L = render_learn(ep, f"{lay}/last.png", lay, end, v, timing)
        step_imgs = [x[0] for x in L]
        step_win = [(x[1], x[2]) for x in L]
        step_fade = [x[3] for x in L]
        shutil.copy(step_imgs[0], f"{lay}/outro.png")
    elif ep["outro"].get("steps"):
        render = render_outro_clean if ep["outro"].get("style") == "clean" else render_outro_steps
        step_imgs = render(ep, f"{lay}/last.png", lay)
        shutil.copy(step_imgs[0], f"{lay}/outro.png")
        starts = [end] + [end + v["at"] + timing[st["line"]]["start"] - 0.08 for st in ep["outro"]["steps"][1:]]
        step_win = [(starts[j], starts[j + 1] if j + 1 < len(starts) else total + 1) for j in range(len(starts))]
    else:
        render_outro(ep, f"{lay}/last.png", f"{lay}/outro.png")

    # ffmpeg 합성
    z = ep.get("zoom")
    inputs = ["-i", a.src, "-loop", "1", "-t", str(total), "-i", f"{lay}/title.png"]
    overlays = [("title.png", 0, end)]
    for i, s in enumerate(ep["subs"]):
        inputs += ["-loop", "1", "-t", str(total), "-i", f"{lay}/sub{i}.png"]
        overlays.append((f"sub{i}", s["start"], s["end"]))
    for i, b in enumerate(ep.get("badges", [])):
        inputs += ["-loop", "1", "-t", str(total), "-i", f"{lay}/badge{i}.png"]
        if b.get("track"):
            bw, bh = b["_size"]
            ax = {"center": 0.5, "left": 0.0}[b.get("anchor", "center")]
            keys = b["track"]
            def lerp(idx):
                ex = str(keys[-1][idx])
                for k in range(len(keys) - 2, -1, -1):
                    t0, t1 = keys[k][0], keys[k + 1][0]
                    v0, v1 = keys[k][idx], keys[k + 1][idx]
                    ex = f"if(lt(t,{t1}),{v0}+({v1}-{v0})*(t-{t0})/{max(t1 - t0, 1e-3)},{ex})"
                return ex
            xe = f"({lerp(1)})-{bw * ax:.1f}"
            ye = f"({lerp(2)})-{bh / 2:.1f}"
            overlays.append((f"badge{i}", b["start"], b["end"], xe, ye))
        else:
            overlays.append((f"badge{i}", b["start"], b["end"]))
    inputs += ["-loop", "1", "-t", str(total), "-i", f"{lay}/outro.png"]
    outro_idx = len(overlays) + 1
    for pth in step_imgs[1:]:
        inputs += ["-loop", "1", "-t", str(total), "-i", pth]
    voice_idx = outro_idx + 1 + max(0, len(step_imgs) - 1)
    if v:
        inputs += ["-i", os.path.join(ep_dir, v["file"])]
    nin = voice_idx + (1 if v else 0)
    pr = ep.get("top_promo") or {}
    promo_idx = None
    if pr.get("start") is not None:
        inputs += ["-loop", "1", "-t", str(total), "-i", f"{lay}/promo.png"]
        promo_idx = nin
        nin += 1
    ins_idx = []
    for x in ep.get("inserts", []):  # 속마음 음성 등 상황극 중간에 넣는 소리
        inputs += ["-i", os.path.join(ep_dir, x["file"])]
        ins_idx.append(nin)
        nin += 1

    fc = []
    base = f"[0:v]scale={W}:{H}:flags=lanczos,setsar=1"
    # 구간별 화질 보정 (필요한 장면만, 전체 적용 안 함)
    for g in ep.get("grade", []):
        for flt in g["filters"]:
            base += f",{flt}:enable='between(t,{g['start']},{g['end']})'"
    if ep.get("title_band"):  # 영상을 띠 아래로 내림 (아래쪽 일부가 잘림)
        base += f",pad={W}:{H + ep['title_band']}:0:{ep['title_band']}:black,crop={W}:{H}:0:0"
    base += f",trim=0:{end},setpts=PTS-STARTPTS"
    if z:
        s0, s1, zs = z["start"], z["end"], z["scale"]
        fx, fy = z["focus"]
        # 부드러운 확대 (ease-in-out), 이후 유지
        p = f"min(max((t-{s0})/({s1}-{s0}),0),1)"
        zz = f"(1+({zs}-1)*(0.5-0.5*cos(PI*{p})))"
        base += (f",scale=w='trunc({W}*{zz}/2)*2':h='trunc({H}*{zz}/2)*2':eval=frame:flags=lanczos"
                 f",crop={W}:{H}:x='{fx}*(iw/{W}-1)':y='{fy}*(ih/{H}-1)'")
    base += f",tpad=stop_mode=clone:stop_duration={ep['outro_duration']},fps=30[v0]"
    fc.append(base)
    cur = "v0"
    for k, ov in enumerate(overlays, start=1):
        name, st, en = ov[:3]
        nxt = f"v{k}"
        if len(ov) == 5:
            fc.append(f"[{cur}][{k}:v]overlay=x='{ov[3]}':y='{ov[4]}':eval=frame:enable='between(t,{st},{en - 0.001})'[{nxt}]")
        else:
            fc.append(f"[{cur}][{k}:v]overlay=0:0:enable='between(t,{st},{en - 0.001})'[{nxt}]")
        cur = nxt
    fc.append(f"[{outro_idx}:v]format=rgba,fade=in:st={end}:d=0.3:alpha=1[o]")
    fc.append(f"[{cur}][o]overlay=0:0:enable='gte(t,{end})'[s0]")
    cur = "s0"
    for j in range(1, len(step_imgs)):
        st0, en0 = step_win[j]
        fd = step_fade[j] if step_fade else 0
        src_in = f"[{outro_idx + j}:v]"
        if fd:
            fc.append(f"{src_in}format=rgba,fade=in:st={st0:.3f}:d={fd}:alpha=1[f{j}]")
            src_in = f"[f{j}]"
        fc.append(f"[{cur}]{src_in}overlay=0:0:enable='between(t,{st0:.3f},{en0:.3f})'[s{j}]")
        cur = f"s{j}"
    if promo_idx is not None:  # 홍보 문구: 상황극 중간에 0.4초 동안 서서히 나타나 상황극 끝까지
        ps = pr["start"]
        fc.append(f"[{promo_idx}:v]format=rgba,fade=in:st={ps}:d=0.4:alpha=1[pm]")
        fc.append(f"[{cur}][pm]overlay=0:0:enable='between(t,{ps},{pr.get("end", total) - 0.001})'[pmo]")
        cur = "pmo"
    fc.append(f"[{cur}]format=yuv420p[vout]")
    duck = ""
    for dk in ep.get("duck", []):  # 현장음 살짝 낮추기 (부드럽게)
        r = dk.get("ramp", 0.25)
        g = dk["gain"]
        a0, a1 = dk["start"], dk["end"]
        duck += (f",volume='if(lt(t,{a0 - r}),1,if(lt(t,{a0}),1-(1-{g})*(t-{a0 - r})/{r},if(lt(t,{a1}),{g},"
                 f"if(lt(t,{a1 + r}),{g}+(1-{g})*(t-{a1})/{r},1))))':eval=frame")
    fc.append(f"[0:a]atrim=0:{end}{duck},afade=out:st={end - ep.get('scene_audio_fade', 0.4)}:d={ep.get('scene_audio_fade', 0.4)},apad=whole_dur={total}[a0]")
    mix = ["[a0]"]
    for k, x in enumerate(ep.get("inserts", [])):
        ms = int(x["at"] * 1000)
        fx = ("," + x["filter"]) if x.get("filter") else ""
        fc.append(f"[{ins_idx[k]}:a]aresample=48000,aformat=channel_layouts=stereo,volume={x.get('volume', 1.0)}{fx},adelay={ms}|{ms}[in{k}]")
        mix.append(f"[in{k}]")
    if v:
        ms = int((end + v["at"]) * 1000)
        fc.append(f"[{voice_idx}:a]aresample=48000,aformat=channel_layouts=stereo,volume={v.get('volume', 1.0)},adelay={ms}|{ms}[vo]")
        mix.append("[vo]")
    if len(mix) > 1:
        fc.append(f"{''.join(mix)}amix=inputs={len(mix)}:duration=first:normalize=0[aout]")
    else:
        fc.append("[a0]anull[aout]")

    mp4 = os.path.join(out, f"{ep['id']}.mp4")
    cmd = ["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(fc),
           "-map", "[vout]", "-map", "[aout]", "-t", str(total),
           "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", mp4]
    subprocess.run(cmd, check=True)
    print(mp4)


if __name__ == "__main__":
    main()
