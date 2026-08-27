import asyncio, pathlib
from playwright.async_api import async_playwright
SRC=pathlib.Path("/root/icon/menubar")
async def main():
    async with async_playwright() as pw:
        b=await pw.chromium.launch()
        for svg in sorted(SRC.glob("*.svg")):
            for scale,suf in [(1,""),(2,"@2x"),(3,"@3x")]:
                page=await b.new_page(viewport={"width":18,"height":18}, device_scale_factor=scale)
                await page.set_content("<style>html,body{margin:0;background:transparent}svg{display:block}</style>"+svg.read_text())
                await page.wait_for_timeout(120)
                await page.screenshot(path=str(SRC/f"{svg.stem}{suf}.png"), omit_background=True)
                await page.close()
        await b.close()
asyncio.run(main())
