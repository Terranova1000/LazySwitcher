# -*- coding: utf-8 -*-
import os
OUT="/root/icon/menubar"; os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT): os.remove(os.path.join(OUT,f))

ARR = ("M 2.8 6.6 L 13.6 6.6 M 11.8 4.8 L 13.6 6.6 L 11.8 8.4 "
       "M 15.2 11.4 L 4.4 11.4 M 6.2 9.6 L 4.4 11.4 L 6.2 13.2")
def st(w): return f'fill="none" stroke="#000" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"'
def svg(body, defs=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">{defs}{body}</svg>\n'

icons = {
  # обычная работа
  "MenuBarIcon":         svg(f'<path d="{ARR}" {st(1.7)}/>'),
  # не работает: пауза, Secure Input, приложение в исключениях
  "MenuBarIconInactive": svg(f'<path d="{ARR}" {st(1.1)}/>'),
  # нет разрешений — точка-бейдж в углу
  "MenuBarIconAlert":    svg(f'<g mask="url(#c)"><path d="{ARR}" {st(1.7)}/></g>'
                             '<circle cx="15.6" cy="2.9" r="1.9" fill="#000"/>',
      defs='<defs><mask id="c" maskUnits="userSpaceOnUse" x="0" y="0" width="18" height="18">'
           '<rect width="18" height="18" fill="#fff"/>'
           '<circle cx="15.6" cy="2.9" r="3.1" fill="#000"/></mask></defs>'),
}
for n,s in icons.items(): open(f"{OUT}/{n}.svg","w").write(s)
print("ok")
