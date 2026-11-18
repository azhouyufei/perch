"""Render the bundled sprites from a checkout of c0le0ni/blob-avatar (Node 24, librsvg, Pillow)."""
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image

source = Path(sys.argv[1]) / "packages/blob-avatar/src"
output = Path(__file__).resolve().parents[1] / "assets/agent-avatar"
with tempfile.TemporaryDirectory() as stage:
    work = Path(stage)
    shutil.copytree(source / "engine", work / "engine")
    (work / "render").mkdir()
    shutil.copy(source / "render/svg.ts", work / "render")
    for module in work.rglob("*.ts"):
        module.write_text(re.sub(r"(from ['\"])(\.[^'\"]+)(['\"])", r"\1\2.ts\3", module.read_text()))
    (work / "frames.mjs").write_text("""
import {frame} from './engine/frame.ts';
import {DEFAULT_STATE} from './engine/state.ts';
import {toSvgString} from './render/svg.ts';
const alert = process.argv[2] === 'alert';
const state = {...DEFAULT_STATE, shape:'ghost', expression:alert?'surprised':'curious', color:'#7061ed', cycle:[{anim:alert?'jump':'nod', dur:2}]};
for(let i=0;i<24;i++) console.log(JSON.stringify(toSvgString(frame(state,i/12),{size:128})));
""")
    for anim in ["question", "alert"]:
        lines = subprocess.check_output(["node", str(work / "frames.mjs"), anim], text=True).splitlines()
        frames = []
        for line in lines:
            png = subprocess.check_output(["rsvg-convert"], input=json.loads(line).encode())
            im = Image.open(io.BytesIO(png)).convert("RGBA")
            pal = im.convert("RGB").quantize(colors=255)
            pal.paste(255, mask=im.getchannel("A").point(lambda a: 255 if a < 128 else 0))
            frames.append(pal)
        frames[0].save(output / (anim + ".gif"), save_all=True, append_images=frames[1:],
                       transparency=255, disposal=2, loop=0, duration=80, optimize=False)
