import struct, pathlib
from PIL import Image
OUT = pathlib.Path("/root/icon/out")
DIST = pathlib.Path("/root/LazySwitcher-icon")

# тип чанка ICNS -> (пиксели, брать ли упрощённый рисунок)
TYPES = [(b"icp4",16),(b"icp5",32),(b"icp6",64),
         (b"ic07",128),(b"ic08",256),(b"ic09",512),(b"ic10",1024),
         (b"ic11",32),(b"ic12",64),(b"ic13",256),(b"ic14",512)]

def build(variant, dest):
    chunks=[]
    for tag,size in TYPES:
        src = OUT/f"icon-{variant}{'-small' if size<=32 else ''}@2048.png"
        im = Image.open(src).convert("RGBA").resize((size,size), Image.LANCZOS)
        import io; buf=io.BytesIO(); im.save(buf,"PNG",optimize=True)
        data=buf.getvalue()
        chunks.append(tag + struct.pack(">I", 8+len(data)) + data)
    body=b"".join(chunks)
    dest.write_bytes(b"icns" + struct.pack(">I", 8+len(body)) + body)

build("indigo", DIST/"Lazy Switcher.icns")
(DIST/"variants").mkdir(exist_ok=True)
for v in ["ocean","graphite"]:
    build(v, DIST/"variants"/f"Lazy Switcher-{v}.icns")
for p in sorted(DIST.rglob("*.icns")):
    print(p.relative_to(DIST), p.stat().st_size//1024, "КБ")
