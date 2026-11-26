#!/usr/bin/env python3
"""엣지영어 상황극 쇼츠/릴스 빌더 (재사용 편집 프로젝트).

사용법:
  python3 build.py episodes/ep01-uh-good.json --src 원본.mp4 --out 결과폴더

에피소드 JSON 만 바꾸면 같은 제목·자막·마지막 학습 화면 디자인으로 새 편이 나온다.
필요: ffmpeg, Pillow, Pretendard 글꼴(fonts/ 에 없으면 npm 으로 자동 내려받음).
"""
import argparse, json, os, subprocess, sys, tarfile, glob, shutil
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
    need = ["Pretendard-Black.otf", "Pretendard-ExtraBold.otf", "Pretendard-Bold.otf", "Pretendard-SemiBold.otf"]
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
    y = SUB_TOP
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
    seg_line(d, [[b["text"], b.get("color", "white")]], f, cx, cy - f.size / 2 - 6, 6)
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
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(end - 0.1), "-i", a.src, "-frames:v", "1", f"{lay}/last.png"], check=True)
    step_imgs, step_win = [], []
    if ep["outro"].get("steps"):
        step_imgs = render_outro_steps(ep, f"{lay}/last.png", lay)
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
        overlays.append((f"badge{i}", b["start"], b["end"]))
    inputs += ["-loop", "1", "-t", str(total), "-i", f"{lay}/outro.png"]
    outro_idx = len(overlays) + 1
    for pth in step_imgs[1:]:
        inputs += ["-loop", "1", "-t", str(total), "-i", pth]
    voice_idx = outro_idx + 1 + max(0, len(step_imgs) - 1)
    if v:
        inputs += ["-i", os.path.join(ep_dir, v["file"])]

    fc = []
    base = f"[0:v]scale={W}:{H}:flags=lanczos,setsar=1,trim=0:{end},setpts=PTS-STARTPTS"
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
    for k, (name, st, en) in enumerate(overlays, start=1):
        nxt = f"v{k}"
        fc.append(f"[{cur}][{k}:v]overlay=0:0:enable='between(t,{st},{en - 0.001})'[{nxt}]")
        cur = nxt
    fc.append(f"[{outro_idx}:v]format=rgba,fade=in:st={end}:d=0.3:alpha=1[o]")
    fc.append(f"[{cur}][o]overlay=0:0:enable='gte(t,{end})'[s0]")
    cur = "s0"
    for j in range(1, len(step_imgs)):
        st0, en0 = step_win[j]
        fc.append(f"[{cur}][{outro_idx + j}:v]overlay=0:0:enable='between(t,{st0:.3f},{en0:.3f})'[s{j}]")
        cur = f"s{j}"
    fc.append(f"[{cur}]format=yuv420p[vout]")
    fc.append(f"[0:a]atrim=0:{end},afade=out:st={end - 0.4}:d=0.4,apad=whole_dur={total}[a0]")
    if v:
        ms = int((end + v["at"]) * 1000)
        fc.append(f"[{voice_idx}:a]aresample=48000,aformat=channel_layouts=stereo,volume={v.get('volume', 1.0)},adelay={ms}|{ms}[vo]")
        fc.append(f"[a0][vo]amix=inputs=2:duration=first:normalize=0[aout]")
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
