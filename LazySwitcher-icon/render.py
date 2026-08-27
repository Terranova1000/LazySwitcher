import asyncio, pathlib
from playwright.async_api import async_playwright

SRC = pathlib.Path("/root/icon/src")
OUT = pathlib.Path("/root/icon/out"); OUT.mkdir(exist_ok=True)

async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch()
        for svg in sorted(SRC.glob("*.svg")):
            page = await b.new_page(viewport={"width":1024,"height":1024},
                                    device_scale_factor=2)
            await page.set_content(
                "<style>html,body{margin:0;padding:0;background:transparent}"
                "svg{display:block}</style>" + svg.read_text())
            await page.wait_for_timeout(300)
            await page.screenshot(path=str(OUT/f"{svg.stem}@2048.png"), omit_background=True)
            await page.close()
        await b.close()
asyncio.run(main())
