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
    total = sum(f.getlength(t) for t, _ in segs)
    x = cx - total / 2
    for t, col in segs:
        draw.text((x, y), t, font=f, fill=C[col], stroke_width=stroke, stroke_fill=stroke_fill)
        x += f.getlength(t)


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
    fk = fit_size([[[k, "white"]] for k in sub["ko"]], "Bold", 50, SUB_W)
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
    f = font("ExtraBold", 44)
    cx, cy = b["center"]
    tw = f.getlength(b["text"])
    seg_line(d, [[b["text"], "white"]], f, cx, cy - f.size / 2 - 6, 6)
    img.save(path)


def render_outro(ep, bg_frame, path):
    o = ep["outro"]
    bg = Image.open(bg_frame).convert("RGB").resize((W, H)).filter(ImageFilter.GaussianBlur(28))
    tint = Image.new("RGB", (W, H), (243, 240, 255))  # 연보라 바탕
    img = Image.blend(bg, tint, 0.86).convert("RGBA")
    d = ImageDraw.Draw(img)

    # 1) 라벨 (보라 알약)
    fl = font("ExtraBold", 50)
    lw = fl.getlength(o["label"]) + 72
    ly = 330
    d.rounded_rectangle([(W - lw) / 2, ly, (W + lw) / 2, ly + 92], radius=46, fill=C["purple"])
    d.text((W / 2, ly + 46), o["label"], font=fl, fill=C["white"], anchor="mm")

    # 2) 학습 표현 카드 (가장 크게)
    card = [70, 470, W - 70, 950]
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([card[0], card[1] + 14, card[2], card[3] + 14], radius=44, fill=(125, 95, 255, 70))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18)))
    d.rounded_rectangle(card, radius=44, fill=C["white"], outline=C["lavender"], width=4)
    fe = fit_size([[[t, "navy"]] for t in o["en"]], "Black", 92, card[2] - card[0] - 90)
    y = 560
    for t in o["en"]:
        d.text((W / 2, y), t, font=fe, fill=C["navy"], anchor="mt")
        y += int(fe.size * 1.2)
    # 구분선 + 한국어 뜻
    d.line([(W / 2 - 60, y + 22), (W / 2 + 60, y + 22)], fill=C["lavender"], width=5)
    fk = font("Bold", 46)
    d.text((W / 2, y + 62), o["ko"], font=fk, fill=C["gray"], anchor="mt")

    # 3) 구독 문구
    fs = font("Bold", 44)
    d.text((W / 2, 1040), o["subscribe"], font=fs, fill=C["navy"], anchor="mt")

    # 4) 레벨테스트 안내
    fq = font("SemiBold", 42)
    d.text((W / 2, 1150), o["cta_question"], font=fq, fill=C["gray"], anchor="mt")
    fb = font("ExtraBold", 44)
    bw = fb.getlength(o["cta_button"]) + 90
    by = 1215
    d.rounded_rectangle([(W - bw) / 2, by, (W + bw) / 2, by + 96], radius=48, fill=C["navy"])
    d.text((W / 2, by + 48), o["cta_button"], font=fb, fill=C["white"], anchor="mm")

    # 5) 브랜드
    fbr = font("Black", 40)
    brand = o["brand"]
    sp = 10
    total = sum(fbr.getlength(ch) for ch in brand) + sp * (len(brand) - 1)
    x = W / 2 - total / 2
    for ch in brand:
        d.text((x, 1395), ch, font=fbr, fill=C["purple"])
        x += fbr.getlength(ch) + sp
    img.convert("RGB").save(path)


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
    lay = os.path.join(out, "layers")
    os.makedirs(lay, exist_ok=True)

    end = ep["scene_end"]
    total = end + ep["outro_duration"]

    # 레이어 그리기
    render_title(ep, f"{lay}/title.png")
    for i, s in enumerate(ep["subs"]):
        render_sub(s, f"{lay}/sub{i}.png")
    for i, b in enumerate(ep.get("badges", [])):
        render_badge(b, f"{lay}/badge{i}.png")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(end - 0.1), "-i", a.src, "-frames:v", "1", f"{lay}/last.png"], check=True)
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
    fc.append(f"[{cur}][o]overlay=0:0:enable='gte(t,{end})',format=yuv420p[vout]")
    fc.append(f"[0:a]atrim=0:{end},afade=out:st={end - 0.4}:d=0.4,apad=whole_dur={total}[aout]")

    mp4 = os.path.join(out, f"{ep['id']}.mp4")
    cmd = ["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(fc),
           "-map", "[vout]", "-map", "[aout]", "-t", str(total),
           "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", mp4]
    subprocess.run(cmd, check=True)
    print(mp4)


if __name__ == "__main__":
    main()
