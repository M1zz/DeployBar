#!/usr/bin/env python3
"""앱 소개 페이지 생성기.

레포의 docs/site/ 에 있는 글(언어마다 JSON 한 장)과 이미 있는 스크린샷으로
docs/index.html · docs/<언어>/index.html 을 만든다. 디자인은 이 폴더의 sitegen.css 한 벌을 모든 앱이 같이 쓴다.

    python3 sitegen.py <레포 경로>
    python3 sitegen.py <레포>/docs/site-remote     한 레포에 두 번째 페이지가 있을 때 (README 의 '한 레포에 페이지 둘')

docs/site/site.json , 앱 공통: 이름, 주소, App Store ID, 색, 언어 목록
docs/site/<code>.json , 그 언어의 글. 없는 언어는 건너뛴다.
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


def shot_dir(shots, folder, loc, fallback=None, need=None):
    """스크린샷 폴더는 스토어 로케일(en-US, de-DE)이라 웹 언어 코드와 다를 수 있다.
    need 파일이 실제로 있는 첫 폴더를 고르고, 그 언어 화면이 없으면 fallback 로케일을 쓴다."""
    base = shots / folder
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


def images(repo, docs, src, site, loc):
    """그 언어 화면의 스크린샷을 웹용 크기로 줄여 docs/img/<code>/ 에 두고, 그림마다 크기를 돌려준다."""
    out, sizes = docs / site.get("img", "img") / loc["code"], {}
    shots = (src / site["screenshots"]).resolve() if "screenshots" in site else docs / "screenshots"
    folder = shot_dir(shots, site.get("shotsFrom", "raw"), loc, site.get("shotsFallback"), f'{site["shots"][0]}.png')
    spare = shots / site.get("shotsFrom", "raw") / site.get("shotsFallback", "")
    for name in site["shots"]:
        dst, src = out / f"{name}.jpg", folder / f"{name}.png"
        if not src.exists():   # 그 언어에 이 화면만 빠졌으면 대체 언어의 같은 화면
            src = spare / f"{name}.png"
        jpeg(src, dst, site.get("shotWidth", 600))
        sizes[name] = size(dst)
    creative = shot_dir(shots, "creative", loc, site.get("shotsFallback"), "header.png")
    if creative:
        jpeg(creative / "header.png", out / "og.jpg", 1200)
        sizes["og"] = size(out / "og.jpg")
    icon_out = docs / site.get("icon", "icon.png")
    if not icon_out.exists():
        icons = sorted((p for p in repo.glob("**/AppIcon.appiconset/*")
                        if p.suffix.lower() in (".png", ".jpg", ".jpeg") and "/build/" not in str(p)),
                       key=lambda p: (any(w in p.name.lower() for w in ("dark", "tint")), -p.stat().st_size))   # 기본 · 큰 것 먼저
        if not icons:   # Icon Composer(AppIcon.icon)는 겹친 층이라 그림 한 장이 없다
            sys.exit("docs/icon.png 가 없고 AppIcon.appiconset 그림도 없다. 앱 아이콘 PNG 를 docs/icon.png 로 두고 다시 돌린다.")
        icon = icons[0]
        subprocess.run(["sips", "-s", "format", "png", "-Z", "256", str(icon), "--out", str(icon_out)],
                       check=True, capture_output=True)
    return sizes


def page(site, loc, t, locales, sizes, at=None):
    """at: 이 글을 둘 폴더. 기본은 그 언어의 path, 옛 주소에 같은 글을 하나 더 둘 때만 다르다."""
    at = loc["path"] if at is None else at
    file = "" if site.get("page", "index.html") == "index.html" else site["page"]   # 폴더 주소 뒤에 붙는 파일 이름
    code, url = loc["code"], site["url"] + loc["path"] + file
    up = "../" if at else ""
    icon = site.get("icon", "icon.png")
    img = f"{up}{site.get('img', 'img')}/{code}"
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
        f'  <link rel="alternate" hreflang="{l["code"]}" href="{site["url"]}{l["path"]}{file}">' for l in locales)
    here = ' aria-current="page"'
    langs = "\n".join(
        f'<a href="{up}{l["path"]}{file}" hreflang="{l["code"]}" lang="{l["code"]}"'
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
    # 첫 주소(x-default)로 들어오면 브라우저 언어에 가장 가까운 페이지로 보낸다. 직접 고른 언어는 기억해 따른다.
    paths = {l["code"]: l["path"] + file for l in locales}
    autolang = "" if at else f"""
  <script>(function () {{
    var P = {json.dumps(paths)}, here = "{code}", want;
    try {{ want = localStorage.getItem("sitegen-lang"); }} catch (e) {{}}
    function match(tag) {{
      var t = (tag || "").toLowerCase(), b = t.split("-")[0], ks = Object.keys(P), i;
      for (i = 0; i < ks.length; i++) if (ks[i].toLowerCase() === t) return ks[i];
      if (b === "zh") return /hant|tw|hk|mo/.test(t) ? (P["zh-Hant"] !== undefined ? "zh-Hant" : null) : (P["zh-Hans"] !== undefined ? "zh-Hans" : null);
      if (b === "no" || b === "nn") b = "nb";
      if (P[b] !== undefined) return b;
      for (i = 0; i < ks.length; i++) if (ks[i].toLowerCase().split("-")[0] === b) return ks[i];
      return null;
    }}
    if (!(want in P)) {{
      want = null;
      var ls = navigator.languages || [navigator.language];
      for (var i = 0; i < ls.length && !want; i++) want = match(ls[i]);
    }}
    if (want && want !== here) location.replace(P[want] + location.hash);
  }})();</script>"""
    og = f'{site["url"]}{site.get("img", "img")}/{code}/{"og" if "og" in sizes else site["shots"][0]}.jpg'

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
  <link rel="alternate" hreflang="x-default" href="{site["url"]}{file}">
  <meta property="og:type" content="website">
  <meta property="og:title" content="{html.escape(t["title"])}">
  <meta property="og:description" content="{html.escape(t["description"])}">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="{og}">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" href="{up}{icon}">
  <link rel="apple-touch-icon" href="{up}{icon}">
  <link rel="stylesheet" href="{up}sitegen.css">{f'{chr(10)}  <link rel="stylesheet" href="{up}demo.css">' if demo else ""}
  <style>:root{{--accent:{site["color"]["light"]}}}@media (prefers-color-scheme:dark){{:root{{--accent:{site["color"]["dark"]}}}}}</style>
  <script>document.documentElement.classList.add("js")</script>{autolang}
</head>
<body>
  <a class="skip" href="#main">{esc(ui["skip"])}</a>
  <header class="bar">
    <a class="brand" href="{up}{loc["path"]}{file}"><img src="{up}{icon}" alt="" width="32" height="32">{esc(site["name"].get(code, site["name"]["en"]) if isinstance(site["name"], dict) else site["name"])}</a>
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
    <p><a href="{loc.get('privacy', site.get('privacy', 'privacy.html'))}">{esc(ui["privacy"])}</a> · {"".join(f'<a href="{h}">{esc(label)}</a> · ' for label, h in ui.get("links", []))}<a href="mailto:{email}">{email}</a> · © {site["year"]} {html.escape(site["copyright"])}</p>
  </footer>

  <script>
    const io = new IntersectionObserver(es => es.forEach(e => {{
      if (e.isIntersecting) {{ e.target.classList.add("in"); io.unobserve(e.target) }}
    }}), {{ rootMargin: "0px 0px -10% 0px" }});
    document.querySelectorAll(".reveal").forEach(el => io.observe(el));
    document.querySelectorAll(".langs a").forEach(a => a.addEventListener("click", () => {{
      try {{ localStorage.setItem("sitegen-lang", a.hreflang) }} catch (e) {{}}
    }}));
  </script>{f'{chr(10)}  <script src="{up}demo.js"></script>' if demo else ""}
</body>
</html>
"""


def main(arg):
    arg = Path(arg).resolve()
    src = arg if (arg / "site.json").exists() else arg / "docs" / "site"   # 글 폴더를 직접 주거나 레포를 준다
    docs = src.parent
    repo = docs.parent
    site = json.loads((src / "site.json").read_text())
    locales = [l for l in site["locales"] if (src / f'{l["code"]}.json').exists()]
    missing = [l["code"] for l in site["locales"] if l not in locales]
    if missing:
        print("⚠️  글이 없어 건너뛴 언어:", ", ".join(missing))
    shutil.copy(HERE / "sitegen.css", docs / "sitegen.css")
    for extra in ("demo.js", "demo.css"):   # 앱마다 있을 수 있는 체험 데모
        if (src / extra).exists():
            shutil.copy(src / extra, docs / extra)
    for loc in locales:
        t = json.loads((src / f'{loc["code"]}.json').read_text())
        sizes = images(repo, docs, src, site, loc)
        for at in [loc["path"]] + loc.get("also", []):   # also: 같은 글을 둘 옛 주소(스토어에 등록된 주소)
            out = docs / at / site.get("page", "index.html")
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(page(site, loc, t, locales, sizes, at))
            print("✓", out.relative_to(repo))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
