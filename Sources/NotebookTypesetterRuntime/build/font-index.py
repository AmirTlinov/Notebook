from pathlib import Path
from fontTools.ttLib import TTFont
import zipfile,io,argparse
p=argparse.ArgumentParser();p.add_argument("distribution",type=Path);p.add_argument("output",type=Path);args=p.parse_args()
z=zipfile.ZipFile(args.distribution)
rows=[]
for n in sorted(z.namelist()):
 if not n.lower().endswith(('.otf','.ttf')):continue
 try:
  f=TTFont(io.BytesIO(z.read(n)),lazy=True)
  def names(ids):
   return '|'.join(dict.fromkeys(r.toUnicode().replace('|',' ').replace('\t',' ').replace('\n',' ') for r in f['name'].names if r.nameID in ids))
  ps=names([6]).split('|')[0]
  os2=f.get('OS/2'); style='italic' if os2 and os2.fsSelection & 1 else 'oblique' if os2 and os2.fsSelection & 512 else 'normal'
  rows.append('\t'.join([n,ps,names([1,16]),names([2,17]),names([4]),str(os2.usWeightClass if os2 else 400),str(os2.usWidthClass if os2 else 5),style,str(int(bool(f['post'].isFixedPitch)))]))
 except Exception as e: print(n,type(e).__name__)
args.output.write_text('\n'.join(rows)+'\n')
print(len(rows))
