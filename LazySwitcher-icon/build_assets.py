# -*- coding: utf-8 -*-
import json, os, shutil, pathlib
from PIL import Image

OUT   = pathlib.Path("/root/icon/out")
DIST  = pathlib.Path("/root/LazySwitcher-icon"); 
if DIST.exists(): shutil.rmtree(DIST)
VARIANTS = ["indigo","ocean","graphite"]
PRIMARY  = "indigo"

# 16 и 32 берём из упрощённого рисунка, остальное — из основного
def px(variant, size):
    src = OUT/f"icon-{variant}{'-small' if size<=32 else ''}@2048.png"
    return Image.open(src).convert("RGBA").resize((size,size), Image.LANCZOS)

MAC = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]

for v in VARIANTS:
    base = DIST/("AppIcon" if v==PRIMARY else f"variants/AppIcon-{v}")
    aset = base.with_name(base.name+".appiconset") if v==PRIMARY else base.parent/f"AppIcon-{v}.appiconset"
    aset = (DIST/"AppIcon.appiconset") if v==PRIMARY else (DIST/"variants"/f"AppIcon-{v}.appiconset")
    aset.mkdir(parents=True, exist_ok=True)
    images=[]
    for pt,scale in MAC:
        real = pt*scale
        fn = f"icon_{pt}x{pt}{'@2x' if scale==2 else ''}.png"
        px(v, real).save(aset/fn)
        images.append({"size":f"{pt}x{pt}","idiom":"mac","filename":fn,"scale":f"{scale}x"})
    json.dump({"images":images,"info":{"version":1,"author":"xcode"}},
              open(aset/"Contents.json","w"), indent=2)

    # .iconset для iconutil
    iset = (DIST/"Lazy Switcher.iconset") if v==PRIMARY else (DIST/"variants"/f"Lazy Switcher-{v}.iconset")
    iset.mkdir(parents=True, exist_ok=True)
    for pt,scale in MAC:
        real=pt*scale
        fn = f"icon_{pt}x{pt}{'@2x' if scale==2 else ''}.png"
        px(v, real).save(iset/fn)

    # мастер 1024
    (DIST/"png").mkdir(exist_ok=True)
    px(v,1024).save(DIST/"png"/f"LazySwitcher-{v}-1024.png")

# исходники
srcdir = DIST/"svg"; srcdir.mkdir(exist_ok=True)
for f in pathlib.Path("/root/icon/src").glob("*.svg"):
    shutil.copy(f, srcdir/f.name)

# строка меню
mb = DIST/"MenuBar"; mb.mkdir(exist_ok=True)
for f in pathlib.Path("/root/icon/menubar").iterdir():
    shutil.copy(f, mb/f.name)
for name in ["MenuBarIcon","MenuBarIconInactive","MenuBarIconAlert"]:
    s=(mb/f"{name}.imageset"); s.mkdir(exist_ok=True)
    for suf,scale in [("","1x"),("@2x","2x"),("@3x","3x")]:
        shutil.copy(mb/f"{name}{suf}.png", s/f"{name}{suf}.png")
    json.dump({"images":[{"idiom":"mac","filename":f"{name}{suf}.png","scale":sc}
                         for suf,sc in [("","1x"),("@2x","2x"),("@3x","3x")]],
               "info":{"version":1,"author":"xcode"},
               "properties":{"template-rendering-intent":"template"}},
              open(s/"Contents.json","w"), indent=2)

print("built")
for p in sorted(DIST.rglob("*")):
    if p.is_dir(): print(" ", p.relative_to(DIST))
