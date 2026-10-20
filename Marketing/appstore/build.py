import subprocess, pathlib, html
root = pathlib.Path(__file__).parent.resolve()
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,800&family=Instrument+Sans:wght@400;500;600&display=swap">'
CSS = """
*{box-sizing:border-box;margin:0}
html,body{width:2880px;height:1800px;overflow:hidden;background:#F6F6F4;color:#111113}
body{font-family:'Instrument Sans',Helvetica,Arial,sans-serif;position:relative}
.eyebrow{position:absolute;top:96px;left:0;right:0;text-align:center;display:flex;justify-content:center}
.brand{display:inline-flex;align-items:center;gap:20px;font:800 44px 'Bricolage Grotesque',sans-serif;letter-spacing:-.02em}
.mark{width:64px;height:64px;border-radius:18px;background:#141416;display:grid;place-items:center}
.mark svg{width:38px;height:38px;stroke:#fff;fill:none;stroke-width:2.4;stroke-linecap:round;stroke-linejoin:round}
h1{position:absolute;top:230px;left:0;right:0;text-align:center;font:800 170px/1 'Bricolage Grotesque',sans-serif;letter-spacing:-.028em;word-spacing:.08em;text-wrap:balance;padding:0 200px}
p.sub{position:absolute;top:430px;left:0;right:0;text-align:center;font:400 58px/1.3 'Instrument Sans',sans-serif;color:#6B6B70;padding:0 400px}
.shot{position:absolute;left:340px;top:575px;width:2200px;border-radius:26px;box-shadow:0 80px 160px -50px rgba(0,0,0,.45),0 0 0 2px rgba(0,0,0,.10)}
.shot img{display:block;width:100%;border-radius:26px}
"""
MARK = '<span class="mark"><svg viewBox="0 0 24 24"><path d="M4 4l6 6M10 5v5H5M20 4l-6 6M14 5v5h5M4 20l6-6M10 19v-5H5M20 20l-6-6M14 19v-5h5"/></svg></span>'
def page(name, h, sub, body, extra_css=""):
    doc = f"<!doctype html><meta charset=utf-8>{FONTS}<style>{CSS}{extra_css}</style><body><div class=eyebrow><span class=brand>{MARK}Squeezo</span></div><h1>{html.escape(h)}</h1><p class=sub>{html.escape(sub)}</p>{body}</body>"
    f = root/f"{name}.html"; f.write_text(doc)
    out = root/f"{name}.png"
    subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=1","--window-size=2880,1800","--virtual-time-budget=6000",f"--screenshot={out}",f"file://{f}"],check=True,capture_output=True)
    print("built", out.name)
shot = lambda img, extra="": f'<div class=shot style="{extra}"><img src="raw/{img}"></div>'
page("01-compress","Make files smaller.","Photos, videos, GIFs, PDFs and audio, shrunk in one window.",shot("compress.png"))
page("02-crop","Crop by dragging.","Pull the corners or pick a ratio. One area for the whole batch.",shot("crop.png"))
page("03-convert","Switch formats in a click.","Images, video, GIFs, audio and PDF pages, with details before you run.",shot("convert.png"))
page("04-watermark","Stamp your work.","Add a text or logo watermark to pictures, video and PDFs, with a live preview.",shot("watermark.png"))
# every tool: sidebar enlarged beside a tool grid of names
tools = ["Compress","Resize","Crop","Rotate & Flip","Enlarge","Watermark","Hide Faces","Remove Background","Convert","Text & Markdown","Merge PDFs","Split PDF"]
chips = "".join(f'<div class=chip>{html.escape(t)}</div>' for t in tools)
page("05-tools","One app. Every tool.","Compress, resize, crop, convert, merge, split and more, all offline.",
     f'<div class=grid>{chips}</div>',
     ".grid{position:absolute;left:380px;right:380px;top:660px;display:grid;grid-template-columns:repeat(4,1fr);gap:44px}.chip{height:300px;border-radius:44px;background:#fff;border:2px solid #E2E2DE;display:grid;place-items:center;font:800 68px 'Bricolage Grotesque',sans-serif;letter-spacing:-.02em;text-align:center;padding:0 30px;box-shadow:0 30px 60px -40px rgba(0,0,0,.25)}")
page("06-private","Your files never leave your Mac.","No uploads, no account, no tracking. Squeezo has no network access at all.",
     '<div class=grid><div class=pt><b>No uploads</b>Every tool runs on your Mac.</div><div class=pt><b>No account</b>Open it and drop a file.</div><div class=pt><b>Originals are safe</b>Replaced files go to the Trash and can be restored.</div></div>',
     ".grid{position:absolute;left:380px;right:380px;top:660px;display:grid;grid-template-columns:repeat(3,1fr);gap:48px}.pt{height:900px;border-radius:52px;background:#141416;color:#CFCFD2;padding:90px;font:400 62px/1.35 'Instrument Sans',sans-serif}.pt b{display:block;color:#fff;font:800 112px/1.02 'Bricolage Grotesque',sans-serif;letter-spacing:-.03em;margin-bottom:48px}")
