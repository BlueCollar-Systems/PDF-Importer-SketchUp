"""Generate public fictional fonts/PDFs; consumes no private drawing/font bytes."""
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
import hashlib
import base64
import io
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / 'test' / 'fixtures' / 'source_zero_ink'
OUT.mkdir(exist_ok=True)


def glyph(points=()):
    pen = TTGlyphPen(None)
    if points:
        pen.moveTo(points[0])
        for point in points[1:]:
            pen.lineTo(point)
        pen.closePath()
    return pen.glyph()


def font_bytes(visible_space, raw_code_space=False, cmap_conflict=False, visible_euro=False,
               symbolic_named=False, mixed_symbol_prefix=False):
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(['.notdef', 'space', 'A'] + (['Euro'] if visible_euro else []))
    builder.setupCharacterMap({32:'space', 65:'A', 128:'space', 0x20ac:'Euro'} if visible_euro else {32:'space', 65:'A'})
    if raw_code_space:
        from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
        mac = CmapSubtable.newSubtable(6)
        mac.platformID=1; mac.platEncID=0; mac.language=0
        mac.cmap={9:'space',65:'A'}
        symbol = CmapSubtable.newSubtable(4)
        symbol.platformID=3; symbol.platEncID=0; symbol.language=0
        symbol.cmap={0xf009:'space',0xf041:'A'}
        if mixed_symbol_prefix:
            symbol.cmap[0xf109]='A'
        tables=[mac,symbol]
        if cmap_conflict:
            unicode = CmapSubtable.newSubtable(4)
            unicode.platformID=3; unicode.platEncID=1; unicode.language=0
            unicode.cmap={9:'A',32:'space',65:'A'}
            tables.append(unicode)
        builder.font['cmap'].tables=tables
    if symbolic_named:
        from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
        mac=CmapSubtable.newSubtable(6)
        mac.platformID=1; mac.platEncID=0; mac.language=0; mac.cmap={32:'A',65:'A'}
        symbol=CmapSubtable.newSubtable(4)
        symbol.platformID=3; symbol.platEncID=0; symbol.language=0
        symbol.cmap={0xf020:'A',0xf041:'A'}
        builder.font['cmap'].tables.extend([mac,symbol])
    box = [(0,0),(400,0),(400,700),(0,700)]
    glyphs={'.notdef':glyph(box), 'space':glyph(box if visible_space else ()), 'A':glyph([(0,0),(500,0),(250,700)])}
    metrics={'.notdef':(500,0), 'space':(500,0), 'A':(600,0)}
    if visible_euro:
        glyphs['Euro']=glyph(box); metrics['Euro']=(500,0)
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    name = 'BCSyntheticVisibleSpace' if visible_space else 'BCSyntheticEmptySpace'
    builder.setupNameTable({'familyName':name, 'styleName':'Regular', 'uniqueFontIdentifier':name+'-public-fixture', 'fullName':name, 'psName':name, 'version':'Version 1.0'})
    builder.setupOS2(sTypoAscender=800,sTypoDescender=-200,usWinAscent=800,usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    builder.font['head'].created = builder.font['head'].modified = 2082844800
    builder.font.recalcTimestamp=False
    output=io.BytesIO()
    builder.save(output)
    return output.getvalue(), name


def stream(data, additional=b''):
    return b'<< /Length '+str(len(data)).encode()+additional+b' >>\nstream\n'+data+b'\nendstream'


def pdf(visible_space, blank_only=False, raw_code_space=False, label=None,
        flags=None, cmap_conflict=False, visible_euro=False, encoding_differences=False,
        symbolic_named=False, mixed_symbol_prefix=False):
    program, name = font_bytes(visible_space, raw_code_space, cmap_conflict, visible_euro,
                               symbolic_named,mixed_symbol_prefix)
    # The authored red rectangle intersects the blank span's fabricated bbox.
    # A final-page raster crop cannot establish ownership of that red ink.
    content = (b'q 1 0 0 rg 72 138 72 22 re f Q\n'
               b'BT /F1 20 Tf 1 0 0 1 72 144 Tm (    ) Tj ET\n'
               b'BT /F1 20 Tf 1 0 0 1 72 90 Tm (A) Tj ET\n')
    if blank_only:
        content = b'BT /F1 20 Tf 1 0 0 1 72 144 Tm (    ) Tj ET\n'
    if raw_code_space:
        content = content.replace(b'(    )',b'<09090909>')
    if visible_euro:
        content = content.replace(b'(    )',b'<80808080>')
    cmap = (b'/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n'
            b'/CIDSystemInfo << /Registry (BCFixture) /Ordering (Synthetic) /Supplement 0 >> def\n'
            b'/CMapName /BCPublicFixture def\n/CMapType 2 def\n'
            b'1 begincodespacerange\n<00> <FF>\nendcodespacerange\n'
            b'2 beginbfchar\n<20> <0020>\n<41> <0041>\nendbfchar\n'
            b'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n')
    if raw_code_space:
        cmap = cmap.replace(b'<20> <0020>',b'<09> <0020>')
    if visible_euro:
        cmap = cmap.replace(b'<20> <0020>',b'<80> <0020>')
    first_char=9 if raw_code_space else 32
    last_char=128 if visible_euro else 65
    widths=b' '.join(str(500 if i in (first_char,128) else (600 if i==65 else 0)).encode()
                     for i in range(first_char,last_char+1))
    encoding=b'' if raw_code_space else b' /Encoding /WinAnsiEncoding'
    if encoding_differences:
        encoding=b' /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [32 /A] >>'
    if flags is None:
        flags=4 if raw_code_space else 32
    flags_entry='' if flags=='absent' else f' /Flags {flags}'
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 288 216] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
        stream(content),
        (f'<< /Type /Font /Subtype /TrueType /BaseFont /{name} /FirstChar {first_char} /LastChar {last_char} /Widths ['.encode()+widths+b']'+encoding+b' /FontDescriptor 6 0 R /ToUnicode 8 0 R >>'),
        f'<< /Type /FontDescriptor /FontName /{name}{flags_entry} /FontBBox [0 0 500 700] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontFile2 7 0 R >>'.encode(),
        stream(program, b' /Length1 '+str(len(program)).encode()),
        stream(cmap),
    ]
    data=bytearray(b'%PDF-1.4\n% public synthetic control\n')
    offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(data))
        data += str(i).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
    xref=len(data)
    data += b'xref\n0 9\n0000000000 65535 f \n'
    for off in offsets[1:]:
        data += f'{off:010d} 00000 n \n'.encode()
    data += b'trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n'
    label = label or ('raw-code-09-space' if raw_code_space else ('blank-only-page' if blank_only else ('visible-space-must-retain-ink' if visible_space else 'empty-space-over-neighboring-ink')))
    path=OUT/(label+'.pdf')
    path.write_bytes(data)
    return {'file':path.name,'sha256':hashlib.sha256(data).hexdigest(),'pdf_base64':base64.b64encode(data).decode('ascii'),'font_program_sha256':hashlib.sha256(program).hexdigest(),'glyph_id_space':1,'visible_space':visible_space,'blank_only':blank_only,'space_character_count':4,'font_descriptor_flags':flags,'scope':'Public fictional font; no private source content'}


if __name__=='__main__':
    receipt={'schema':'bcs.public-zero-ink-controls/1','controls':[
        pdf(False),pdf(True),pdf(False,True),pdf(False,raw_code_space=True),
        pdf(False,raw_code_space=True,flags=32,cmap_conflict=True,label='nonsymbolic-conflicting-cmap'),
        pdf(False,raw_code_space=True,flags=36,label='conflicting-font-flags'),
        pdf(False,raw_code_space=True,flags='absent',label='missing-font-flags'),
        pdf(False,visible_euro=True,label='winansi-visible-euro-tounicode-space'),
        pdf(False,encoding_differences=True,label='encoding-differences-visible-A'),
        pdf(False,flags=4,symbolic_named=True,label='symbolic-named-winansi-visible-A'),
        pdf(False,raw_code_space=True,mixed_symbol_prefix=True,label='ambiguous-symbol-prefixes')
    ]}
    (OUT/'CONTROLS.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
