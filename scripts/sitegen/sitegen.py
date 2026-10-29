#!/usr/bin/env python3
"""앱 소개 페이지 생성기.

레포의 docs/site/ 에 있는 글(언어마다 JSON 한 장)과 이미 있는 스크린샷으로
docs/index.html · docs/<언어>/index.html 을 만든다. 디자인은 이 폴더의 site.css 한 벌을 모든 앱이 같이 쓴다.

    python3 sitegen.py <레포 경로>

docs/site/site.json — 앱 공통: 이름, 주소, App Store ID, 색, 언어 목록
docs/site/<code>.json — 그 언어의 글. 없는 언어는 건너뛴다.
"""
import html, json, re, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def esc(s):
    """글 안의 `명령` 만 <code> 로 바꾸고 나머지는 이스케이프한다."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(s, quote=False))


def lines(s):
    return "<br>".join(esc(x) for x in s.split("\n"))


def jpeg(src, dst, width):
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "78",
                    "--resampleWidth", str(width), str(src), "--out", str(dst)],
                   check=True, capture_output=True)


def shot_dir(docs, folder, loc, fallback=None, need=None):
    """스크린샷 폴더는 스토어 로케일(en-US, de-DE)이라 웹 언어 코드와 다를 수 있다.
    need 파일이 실제로 있는 첫 폴더를 고르고, 그 언어 화면이 없으면 fallback 로케일을 쓴다."""
    base = docs / "screenshots" / folder
    main = loc["code"] + ("-US" if loc["code"] == "en" else "-" + loc["code"].upper())   # en-US, de-DE, fr-FR
    names = [loc.get("shots"), loc["code"], main] + sorted(p.name for p in base.glob(loc["code"] + "-*")) + [fallback]
    for name in names:
        if name and (base / name).is_dir() and (not need or (base / name / need).exists()):
            return base / name
    return None


def size(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True).stdout
    w, h = re.findall(r"pixel\w+: (\d+)", out)
    return int(w), int(h)


def images(repo, docs, site, loc):
    """그 언어 화면의 스크린샷을 웹용 크기로 줄여 docs/img/<code>/ 에 두고, 그림마다 크기를 돌려준다."""
    out, sizes = docs / "img" / loc["code"], {}
    folder = shot_dir(docs, site.get("shotsFrom", "raw"), loc, site.get("shotsFallback"), f'{site["shots"][0]}.png')
    spare = docs / "screenshots" / site.get("shotsFrom", "raw") / site.get("shotsFallback", "")
    for name in site["shots"]:
        dst, src = out / f"{name}.jpg", folder / f"{name}.png"
        if not src.exists():   # 그 언어에 이 화면만 빠졌으면 대체 언어의 같은 화면
            src = spare / f"{name}.png"
        jpeg(src, dst, site.get("shotWidth", 600))
        sizes[name] = size(dst)
    creative = shot_dir(docs, "creative", loc, site.get("shotsFallback"), "header.png")
    if creative:
        jpeg(creative / "header.png", out / "og.jpg", 1200)
    if not (docs / "icon.png").exists():
        icons = sorted((p for p in repo.glob("**/AppIcon.appiconset/*")
                        if p.suffix.lower() in (".png", ".jpg", ".jpeg") and "/build/" not in str(p)),
                       key=lambda p: any(w in p.name.lower() for w in ("dark", "tint")))   # 기본 아이콘 먼저
        icon = icons[0]
        subprocess.run(["sips", "-s", "format", "png", "-Z", "256", str(icon), "--out", str(docs / "icon.png")],
                       check=True, capture_output=True)
    return sizes


def page(site, loc, t, locales, sizes):
    code, url = loc["code"], site["url"] + loc["path"]
    up = "../" if loc["path"] else ""
    img = f"{up}img/{code}"
    store = f"https://apps.apple.com/app/id{site['appStoreId']}"
    lazy, frame = ' loading="lazy"', site.get("frame", "phone")   # phone: 아이폰 테두리 · plain: 둥근 그림만
    shot = lambda name, alt, eager=False: (
        f'<div class="{frame}"><img src="{img}/{name}.jpg" alt="{html.escape(alt)}" '
        f'width="{sizes[name][0]}" height="{sizes[name][1]}"{"" if eager else lazy} decoding="async"></div>')
    video = site.get("video")
    if isinstance(video, dict):
        video = video.get(code, video.get("default"))
    first = site["shots"][0]
    hero_media = (f'<div class="{frame}"><video src="{up}{video}" poster="{img}/{first}.jpg" autoplay muted loop '
                  f'playsinline width="{sizes[first][0]}" height="{sizes[first][1]}" '
                  f'aria-label="{html.escape(t["hero"]["headline"].replace(chr(10), " "))}"></video></div>'
                  if video else shot(first, t["hero"]["headline"].replace(chr(10), " "), eager=True))
    cta = lambda label: f'<a class="cta" href="{store}">{esc(label)}</a>'

    alt_links = "\n".join(
        f'  <link rel="alternate" hreflang="{l["code"]}" href="{site["url"]}{l["path"]}">' for l in locales)
    here = ' aria-current="page"'
    langs = "\n".join(
        f'<a href="{up}{l["path"]}" hreflang="{l["code"]}" lang="{l["code"]}"'
        f'{here if l is loc else ""}>{l["name"]}</a>' for l in locales)

    features = "\n".join(f"""
    <section class="feature reveal">
      <div class="copy">
        <h2>{esc(f["title"])}</h2>
        <p>{lines(f["text"])}</p>
      </div>
      {shot(f["shot"], f["title"])}
    </section>""" for f in t["features"])

    steps = "\n".join(
        f'<li class="card"><span class="n">{i}</span><h3>{esc(s["title"])}</h3><p>{esc(s["text"])}</p></li>'
        for i, s in enumerate(t["steps"]["items"], 1))

    ref = t.get("reference")
    reference = "" if not ref else f"""
    <section class="reveal" id="commands">
      <h2>{esc(ref["title"])}</h2>
      <div class="card table">
        <dl>{"".join(f"<div><dt>{esc(k)}</dt><dd>{esc(v)}</dd></div>" for k, v in ref["rows"])}</dl>
      </div>
      <p class="muted">{esc(ref["note"])}</p>
    </section>"""

    p = t.get("pricing")
    plan = lambda x, cls: f"""<div class="card plan {cls}">
          <h3>{esc(x["name"])}</h3>
          <ul>{"".join(f"<li>{esc(i)}</li>" for i in x["items"])}</ul>
          {f'<p class="muted">{esc(x["note"])}</p>' if x.get("note") else ""}
        </div>"""
    pricing = "" if not p else f"""
    <section class="reveal" id="pricing">
      <h2>{esc(p["title"])}</h2>
      <div class="plans">
        {plan(p["free"], "free")}
        {plan(p["pro"], "pro")}
      </div>
      <p class="muted">{esc(p["note"])}</p>
    </section>"""

    faq = "\n".join(
        f'<details><summary>{esc(q["q"])}</summary><p>{esc(q["a"])}</p></details>' for q in t["faq"]["items"])

    demo = "" if not t.get("demo") else f"""
    <section class="reveal" id="try">
      <h2>{esc(t["demo"]["title"])}</h2>
      <p class="muted">{esc(t["demo"]["lead"])}</p>
      <div id="demo" class="card demo-card" data-text="{html.escape(json.dumps(t["demo"], ensure_ascii=False))}"></div>
    </section>"""

    ui = t["ui"]
    email = site["email"]
    contact = esc(ui["contact"]).replace("{email}", f'<a href="mailto:{email}">{email}</a>')
    og = f'{site["url"]}img/{code}/og.jpg'

    return f"""<!doctype html>
<html lang="{code}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(t["title"])}</title>
  <meta name="description" content="{html.escape(t["description"])}">
  <meta name="theme-color" content="{site["color"]["light"]}" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="{site["color"]["darkBg"]}" media="(prefers-color-scheme: dark)">
  <meta name="apple-itunes-app" content="app-id={site['appStoreId']}">
  <link rel="canonical" href="{url}">
{alt_links}
  <link rel="alternate" hreflang="x-default" href="{site["url"]}">
  <meta property="og:type" content="website">
  <meta property="og:title" content="{html.escape(t["title"])}">
  <meta property="og:description" content="{html.escape(t["description"])}">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="{og}">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" href="{up}icon.png">
  <link rel="apple-touch-icon" href="{up}icon.png">
  <link rel="stylesheet" href="{up}site.css">{f'{chr(10)}  <link rel="stylesheet" href="{up}demo.css">' if demo else ""}
  <style>:root{{--accent:{site["color"]["light"]}}}@media (prefers-color-scheme:dark){{:root{{--accent:{site["color"]["dark"]}}}}}</style>
  <script>document.documentElement.classList.add("js")</script>
</head>
<body>
  <a class="skip" href="#main">{esc(ui["skip"])}</a>
  <header class="bar">
    <a class="brand" href="{up}{loc["path"]}"><img src="{up}icon.png" alt="" width="32" height="32">{esc(site["name"].get(code, site["name"]["en"]) if isinstance(site["name"], dict) else site["name"])}</a>
    <a class="lang-link" href="#languages">{esc(ui["languages"])}</a>
  </header>

  <main id="main">
    <section class="hero">
      <div class="copy">
        <h1>{lines(t["hero"]["headline"])}</h1>
        <p class="lead">{esc(t["hero"]["lead"])}</p>
        <div class="actions">{cta(t["hero"]["cta"])}{f'<a class="try" href="#try">{esc(t["demo"]["title"])} ↓</a>' if demo else ""}</div>
        <p class="muted small">{esc(t["hero"]["note"])}</p>
      </div>
      {hero_media}
    </section>

{demo}

    <section class="problem reveal">
      <h2>{esc(t["problem"]["title"])}</h2>
      <p>{esc(t["problem"]["text"])}</p>
    </section>
{features}

    <section class="reveal">
      <h2>{esc(t["steps"]["title"])}</h2>
      <ol class="steps">{steps}</ol>
    </section>
{reference}

{pricing}

    <section class="reveal" id="faq">
      <h2>{esc(t["faq"]["title"])}</h2>
      <div class="faq">{faq}</div>
      <p class="contact">{contact}</p>
    </section>

    <section class="closing reveal">
      <h2>{lines(t["closing"]["headline"])}</h2>
      {cta(t["closing"]["cta"])}
    </section>
  </main>

  <footer>
    <nav id="languages" class="langs" aria-label="{html.escape(ui["languages"])}">{langs}</nav>
    <p><a href="{loc.get('privacy', 'privacy.html')}">{esc(ui["privacy"])}</a> · {"".join(f'<a href="{h}">{esc(label)}</a> · ' for label, h in ui.get("links", []))}<a href="mailto:{email}">{email}</a> · © {site["year"]} {html.escape(site["copyright"])}</p>
  </footer>

  <script>
    const io = new IntersectionObserver(es => es.forEach(e => {{
      if (e.isIntersecting) {{ e.target.classList.add("in"); io.unobserve(e.target) }}
    }}), {{ rootMargin: "0px 0px -10% 0px" }});
    document.querySelectorAll(".reveal").forEach(el => io.observe(el));
  </script>{f'{chr(10)}  <script src="{up}demo.js"></script>' if demo else ""}
</body>
</html>
"""


def main(repo):
    repo = Path(repo).resolve()
    docs = repo / "docs"
    site = json.loads((docs / "site" / "site.json").read_text())
    locales = [l for l in site["locales"] if (docs / "site" / f'{l["code"]}.json').exists()]
    missing = [l["code"] for l in site["locales"] if l not in locales]
    if missing:
        print("⚠️  글이 없어 건너뛴 언어:", ", ".join(missing))
    shutil.copy(HERE / "site.css", docs / "site.css")
    for extra in ("demo.js", "demo.css"):   # 앱마다 있을 수 있는 체험 데모
        if (docs / "site" / extra).exists():
            shutil.copy(docs / "site" / extra, docs / extra)
    for loc in locales:
        t = json.loads((docs / "site" / f'{loc["code"]}.json').read_text())
        sizes = images(repo, docs, site, loc)
        out = docs / loc["path"] / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(page(site, loc, t, locales, sizes))
        print("✓", out.relative_to(repo))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
