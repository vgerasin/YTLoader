"""Рисует скриншоты интерфейса (app/Resources/ui.html) на демо-данных.

Приложение собрано как нативная оболочка вокруг ui.html: в настоящем окне
состояние приходит из Swift через window.applyState(). Здесь мост подменён,
а состояние — вымышленное. Запуск: make screenshots
"""
import json, base64, sys, os
from playwright.sync_api import sync_playwright

UI = os.path.abspath(sys.argv[1]); OUT = os.path.abspath(sys.argv[2])
os.makedirs(OUT, exist_ok=True)

def thumb(c1, c2):
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="160" height="90"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c1}"/><stop offset="1" stop-color="{c2}"/></linearGradient></defs><rect width="160" height="90" fill="url(#g)"/><circle cx="80" cy="45" r="14" fill="rgba(255,255,255,.55)"/><path d="M75 37l13 8-13 8z" fill="rgba(0,0,0,.35)"/></svg>'
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()

T = [thumb("#5B8DEF","#8E5BEF"), thumb("#F2994A","#EB5757"), thumb("#27AE60","#2D9CDB"), thumb("#BB6BD9","#2F80ED"), thumb("#56CCF2","#2F80ED")]

def settings(**kw):
    s = dict(onboarded=True, theme="light", density="normal", accent="#007AFF", language="ru",
             folder="/Users/demo/Movies/YTLoader", defaultQuality="1080p", maxParallel="3",
             speedLimit="", organize="channel", codec="any", cookieBrowser="none",
             filenameTemplate="%(title)s [%(id)s].%(ext)s", subtitles="ru,en", subsEmbed=True,
             chapters=True, sponsorblock=True, wifiOnly=False, autoResume=True, clipboardWatch=True,
             autoUpdate=True, notify=True, dockBadge=True, menuBar=True)
    s.update(kw); return s

ENV = dict(ytdlp=True, ytdlpVersion="2026.09.30", ytdlpPath="/Applications/YTLoader.app/Contents/Resources/bin/yt-dlp",
           ffmpeg=True, ffmpegPath="~/Library/Application Support/YTLoader/ffmpeg",
           ffprobe=True, ffprobePath="~/Library/Application Support/YTLoader/ffprobe",
           js=True, jsKind="deno", jsPath="~/Library/Application Support/YTLoader/deno",
           window="1080 × 760", systemLang="ru", installing="")

def item(i, **kw):
    d = dict(id=f"i{i}", url=f"https://www.youtube.com/watch?v=demo{i:04d}", title="", channel="", status="queued",
             stage="video", pct=0, total=0, downloaded=0, speed=0, eta=0, quality="1080p", format="mp4",
             duration=0, thumb="", streams=[], added=i, error="", rawError="", noCookies=False,
             groupId="", groupTitle="", groupTotal=0, deferMode="", deferTime="", filepath="", dateLabel="")
    d.update(kw); return d

MB = 1048576
items = [
    item(1, title="Как устроен современный компилятор: от кода до машинных команд", channel="Лекторий Практика", status="downloading",
         pct=62, total=int(812*MB), downloaded=int(503*MB), speed=int(7.4*MB), eta=42, duration=3725, thumb=T[0],
         streams=[dict(kind="video", total=int(740*MB), done=int(503*MB), active=True), dict(kind="audio", total=int(72*MB), done=0, estimated=True)]),
    item(2, title="Ambient Focus Mix — 2 hours of calm music", channel="Quiet Waves", status="downloading", stage="audio",
         quality="audio", format="mp3", pct=88, total=int(118*MB), downloaded=int(104*MB), speed=int(4.1*MB), eta=4, duration=7200, thumb=T[2],
         streams=[dict(kind="audio", total=int(118*MB), done=int(104*MB), active=True)]),
    item(3, title="Курс по данным, урок 4: витрины и слой KPI", channel="Школа аналитики", status="downloading", stage="merge",
         pct=100, total=int(430*MB), downloaded=int(430*MB), duration=1980, thumb=T[3],
         streams=[dict(kind="video", total=int(400*MB), done=int(400*MB)), dict(kind="audio", total=int(30*MB), done=int(30*MB))]),
    item(4, title="Planning your week: a 15-minute method", channel="Deep Work Studio", status="queued", duration=905, thumb=T[1]),
    item(5, title="Урок 1. Введение", channel="Плейлист «Основы SQL»", status="downloading", pct=34, total=int(210*MB), downloaded=int(71*MB),
         speed=int(5.2*MB), eta=27, duration=1260, thumb=T[4], groupId="pl1", groupTitle="Основы SQL — 12 уроков", groupTotal=12,
         streams=[dict(kind="video", total=int(190*MB), done=int(71*MB), active=True), dict(kind="audio", total=int(20*MB), done=0, estimated=True)]),
    item(6, title="Урок 2. SELECT и фильтры", channel="Плейлист «Основы SQL»", status="queued", duration=1410, thumb=T[4], groupId="pl1", groupTitle="Основы SQL — 12 уроков", groupTotal=12),
    item(8, title="Закрытая лекция (приватное видео)", channel="youtube.com", status="error",
         error="Приватное видео. Нужны cookies из браузера, где вы вошли в аккаунт.", rawError="", thumb=""),
]
deferred = [
    item(20, title="Большой документальный фильм в 4K", channel="Doc Archive", status="deferred", deferMode="wifi", quality="best", duration=5400, thumb=T[1]),
    item(21, title="Вебинар: аналитика на ночь", channel="Школа аналитики", status="deferred", deferMode="time", deferTime="23:00", duration=4100, thumb=T[3]),
]
history = [
    item(30, title="Основы Python за 60 минут", channel="Код с нуля", status="done", total=int(640*MB), dateLabel="Сегодня, 10:42", filepath="/Users/demo/Movies/YTLoader/Код с нуля/Основы Python за 60 минут.mp4", duration=3600, thumb=T[0]),
    item(31, title="Lo-fi beats to study to", channel="Quiet Waves", status="done", quality="audio", format="mp3", total=int(86*MB), dateLabel="Вчера, 21:15", filepath="/Users/demo/Movies/YTLoader/Quiet Waves/Lo-fi beats.mp3", duration=5400, thumb=T[2]),
    item(32, title="Интервью: как строить культуру данных", channel="Школа аналитики", status="done", total=int(1.4*1024*MB), dateLabel="12 окт., 18:03", filepath="/Users/demo/Movies/YTLoader/Школа аналитики/Интервью.mp4", quality="1440p", duration=4800, thumb=T[3]),
]

def state(items_, history_=history, **kw):
    s = dict(items=items_, history=history_, settings=settings(),
             env=ENV, net=dict(kind="wifi", label="Wi-Fi"),
             totals=dict(active=3, speed=int(16.7*MB)), notice="")
    s.update(kw); return s

def apply(page, s):
    page.evaluate("s => window.applyState(s)", s)
    page.wait_for_timeout(500)

with sync_playwright() as p:
    b = p.chromium.launch()
    def new(w=900, h=720):
        ctx = b.new_context(viewport=dict(width=w, height=h), device_scale_factor=2)
        pg = ctx.new_page()
        pg.add_init_script("window.webkit={messageHandlers:{ytl:{postMessage:function(){}}}};")
        pg.goto("file://" + UI)
        return pg
    def shot(pg, name): pg.screenshot(path=f"{OUT}/{name}.png")

    # 1 очередь
    pg = new(h=1180); apply(pg, state(items)); shot(pg, "01-queue")
    # 3 пустая очередь
    pg = new(); apply(pg, state([], totals=dict(active=0, speed=0))); shot(pg, "03-empty-dropzone")
    # 4 история
    pg = new(); apply(pg, state(items)); pg.click("#tabHistory"); pg.wait_for_timeout(400); shot(pg, "04-history")
    # 5 отложено
    pg = new(); apply(pg, state(items + deferred)); pg.click("#tabDeferred"); pg.wait_for_timeout(400); shot(pg, "05-deferred")
    # 6 настройки
    pg = new(w=900,h=1180); apply(pg, state(items)); pg.click("#gear"); pg.wait_for_timeout(600); shot(pg, "06-settings")
    # 7 меню качества
    pg = new(); apply(pg, state(items)); pg.click("#ddQuality .ddbtn"); pg.wait_for_timeout(300); shot(pg, "07-quality-menu")
    # 8 фрагмент
    pg = new(); apply(pg, state(items)); pg.click("#cutBtn"); pg.fill("#cutFrom","00:05:00"); pg.fill("#cutTo","00:12:00"); pg.wait_for_timeout(300); shot(pg, "08-clip-range")
    # 9 плотный список
    pg = new(h=760); apply(pg, state(items + [], settings=settings(density="list", accent="#AF52DE"))); shot(pg, "09-dense-list-accent")
    # 10 мастер первого запуска
    pg = new(); apply(pg, state([], settings=settings(onboarded=False), totals=dict(active=0, speed=0))); pg.wait_for_timeout(300); shot(pg, "10-onboarding-1")
    pg.click('[data-onb="next"]'); pg.wait_for_timeout(300); pg.click('[data-onb="check"]'); pg.wait_for_timeout(1500); shot(pg, "11-onboarding-2")
    # 12 предупреждение об отсутствии ffmpeg
    pg = new(h=1180); e = dict(ENV, ffmpeg=False, ffmpegPath=""); apply(pg, state(items, env=e)); shot(pg, "12-missing-component")
    b.close()
print("ok")
