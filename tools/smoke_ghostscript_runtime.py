"""Relocate the bundled runtime; render with only its ROM and app-local DLLs."""
from __future__ import annotations
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ghostscript_runtime as gs

def synthetic_pdf():
    content = b"0 0 0 rg 20 20 40 40 re f BT /F1 15 Tf 20 90 Td (Raster OK) Tj ET\n"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 140] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    data = bytearray(b"%PDF-1.4\n"); offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data)); data.extend(str(i).encode() + b" 0 obj\n" + obj + b"\nendobj\n")
    xref = len(data); data.extend(b"xref\n0 6\n0000000000 65535 f \n")
    for offset in offsets[1:]: data.extend((f"{offset:010d} 00000 n \n").encode())
    data.extend(f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(data)

def rgba_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n": raise RuntimeError("GS output is not PNG")
    width, height, depth, color = struct.unpack(">IIBB", data[16:26])
    if depth != 8 or color != 6: raise RuntimeError("GS output lacks 8-bit RGBA provenance")
    payload = bytearray(); pos = 8
    while pos < len(data):
        count = struct.unpack(">I", data[pos:pos+4])[0]; kind = data[pos+4:pos+8]
        if kind == b"IDAT": payload.extend(data[pos+8:pos+8+count])
        pos += count + 12
    raw = zlib.decompress(payload); stride = width*4; previous = bytearray(stride); pixels = bytearray()
    for y in range(height):
        start = y*(stride+1); kind = raw[start]; row = bytearray(raw[start+1:start+1+stride])
        for x in range(stride):
            a = row[x-4] if x >= 4 else 0; b = previous[x]; c = previous[x-4] if x >= 4 else 0
            if kind == 1: predictor = a
            elif kind == 2: predictor = b
            elif kind == 3: predictor = (a+b)//2
            elif kind == 4:
                p = a+b-c; pa,pb,pc = abs(p-a),abs(p-b),abs(p-c)
                predictor = a if pa <= pb and pa <= pc else b if pb <= pc else c
            elif kind == 0: predictor = 0
            else: raise RuntimeError("Unexpected PNG filter")
            row[x] = (row[x]+predictor) & 255
        pixels.extend(row); previous = row
    return width, height, pixels

def smoke(support=gs.SUPPORT, required=False):
    gs.validate(support)
    if os.name != 'nt':
        if required: raise RuntimeError("Required Ghostscript runtime smoke needs Windows")
        print("SKIP: native Ghostscript smoke requires Windows; integrity and PE closure passed")
        return
    with tempfile.TemporaryDirectory(prefix='bcs_gs_relocated_') as temporary:
        root = Path(temporary); binary = root/'bin'
        shutil.copytree(Path(support)/'Ghostscript/bin', binary)
        pdf = root/'generated.pdf'; pdf.write_bytes(synthetic_pdf()); png=root/'page.png'
        env = {key:value for key,value in os.environ.items() if not key.upper().startswith('GS_')}
        env.update(PATH=str(Path(os.environ['SystemRoot'])/'System32'), GS_LIB='%rom%Resource/Init/;%rom%lib/', GS_FONTPATH='', GS_OPTIONS='', GS_DLL=str(binary/'gsdll64.dll'))
        command=[str(binary/'gswin64c.exe'),'-dSAFER','-dBATCH','-dNOPAUSE','-dPDFSTOPONWARNING','-dPDFNOCIDFALLBACK','-sDEVICE=pngalpha','-r72','-dTextAlphaBits=4','-dGraphicsAlphaBits=4','-dFirstPage=1','-dLastPage=1','-o',str(png),'-f',str(pdf)]
        result=subprocess.run(command,cwd=root,env=env,capture_output=True,text=True,timeout=60)
        if result.returncode or result.stderr.strip(): raise RuntimeError('Relocated Ghostscript failed: '+result.stderr)
        # The fixture intentionally requests only standard Helvetica. Any other
        # font substitution or interpretation warning must fail this smoke.
        diagnostics='\n'.join(line for line in result.stdout.splitlines() if line !=
            'Loading font Helvetica (or substitute) from %rom%Resource/Font/NimbusSans-Regular')
        if re.search(r'\b(?:error|warning|unrecoverable|substitut\w*|repair\w*)\b',diagnostics,re.I):
            raise RuntimeError('Relocated Ghostscript changed PDF interpretation: '+diagnostics)
        width,height,pixels=rgba_png(png); alpha=pixels[3::4]
        if (width,height)!=(200,140) or min(alpha)!=0 or max(alpha)!=255:
            raise RuntimeError('GS MediaBox, transparent background or visible ink proof failed')
        print(json.dumps({'status':'PASS','relocated_runtime':True,'rom_only_search':True,'explicit_local_dll':True,'strict_production_arguments':True,'size':[width,height],'transparent_and_opaque_pixels':True}))

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--required',action='store_true'); parser.add_argument('--support',type=Path,default=gs.SUPPORT)
    args=parser.parse_args(); smoke(args.support,args.required)
