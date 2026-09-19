"""Author-side NumPy experiment. No Python runtime is shipped to Notebook.
Run with Python + NumPy/Pillow and ffmpeg on PATH. Outputs stay beside this script.
Same fixed-edge centred stencil as model.ts; Float32 storage, Float64 arithmetic.
"""
import hashlib,json,math,pathlib,subprocess,wave
import numpy as np
from PIL import Image,ImageDraw,ImageFont
ROOT=pathlib.Path(__file__).resolve().parent
raw=(ROOT/'recording-input.json').read_bytes();cfg=json.loads(raw)
n=cfg['grid'];dx=1/(n-1);steps=math.ceil(cfg['time']/(cfg['courant']*dx/cfg['speed']));dt=cfg['time']/steps;c2=(cfg['speed']*dt/dx)**2
seed=cfg['seed']
def random():
 global seed
 seed^=(seed<<13)&0xffffffff;seed^=seed>>17;seed^=(seed<<5)&0xffffffff;seed&=0xffffffff
 return seed/4294967296
cx,cy=.28+.44*random(),.28+.44*random();y,x=np.mgrid[0:n,0:n]/(n-1)
u=np.exp(-((x-cx)**2+(y-cy)**2)/(2*.045**2)).astype(np.float32)
u[[0,-1],:]=0;u[:,[0,-1]]=0;prev=np.zeros_like(u);next=np.zeros_like(u)
zero=np.array([243,244,248]);blue=np.array([45,85,162]);red=np.array([201,79,47])
def picture(field,time):
 v=np.flipud(field);t=np.minimum(1,np.abs(v));end=np.where((v<0)[...,None],blue,red)
 # Round positive channels as JavaScript Math.round does.
 rgb=np.floor(zero+(end-zero)*t[...,None]+.5).astype(np.uint8)
 image=Image.new('RGB',(768,832),'#f3f4f8');image.paste(Image.fromarray(rgb).resize((704,704),Image.Resampling.BILINEAR),(32,40))
 d=ImageDraw.Draw(image);d.rectangle((31,39,737,745),outline='#838895',width=1)
 d.text((32,10),'1 m',fill='#454957',font=font);d.text((680,751),'1 m',fill='#454957',font=font)
 d.text((32,782),f't = {time:0.3f} s     c = {cfg["speed"]} m/s     u: -1 ... +1 mm',fill='#333743',font=font)
 return image
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',22)
video=ROOT/'experiment.mp4';silent=ROOT/'.experiment-video.mp4';audio=ROOT/'sonification.wav';final=ROOT/'final.bin'
encoder=subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','rawvideo','-pixel_format','rgb24','-video_size','768x832','-framerate',str(cfg['fps']),'-i','pipe:0','-an','-c:v','libx264','-crf','19','-preset','medium','-pix_fmt','yuv420p','-movflags','+faststart',str(silent)],stdin=subprocess.PIPE)
frame_steps=np.rint(np.arange(int(cfg['duration']*cfg['fps']))/cfg['fps']*cfg['time']/cfg['duration']/dt).astype(int);frame_index=0;probes=[];px,py=[round(v*(n-1)) for v in cfg['probe']]
try:
 for step in range(steps+1):
  probes.append(float(u[py,px]))
  while frame_index<len(frame_steps) and frame_steps[frame_index]==step:
   image=picture(u,step*dt);encoder.stdin.write(image.tobytes())
   if frame_index==0:image.save(ROOT/'recording-poster.png')
   frame_index+=1
  if step==steps:break
  a=u.astype(np.float64);lap=a[1:-1,:-2]+a[1:-1,2:]+a[:-2,1:-1]+a[2:,1:-1]-4*a[1:-1,1:-1]
  next[1:-1,1:-1]=a[1:-1,1:-1]+.5*c2*lap if step==0 else 2*a[1:-1,1:-1]-prev[1:-1,1:-1]+c2*lap
  prev,u,next=u,next,prev
finally:
 encoder.stdin.close()
if encoder.wait()!=0:raise RuntimeError('Video encoder failed')
u.astype('<f4').tofile(final)
# Explicit amplitude sonification, not a microphone recording or physical sound.
# The carrier is audible; its envelope follows the same probe and slowed video.
sr=cfg['sampleRate'];t=np.arange(round(sr*cfg['duration']))/sr
values=np.interp(t,np.linspace(0,cfg['duration'],len(probes)),np.abs(probes))
ramp=np.minimum(1,np.minimum(t/.05,(cfg['duration']-t)/.05))
pcm=(np.clip(values*2,0,1)*.35*ramp*np.sin(2*np.pi*cfg['carrierHz']*t)*32767).astype('<i2')
with wave.open(str(audio),'wb') as out:out.setnchannels(1);out.setsampwidth(2);out.setframerate(sr);out.writeframes(pcm.tobytes())
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(silent),'-i',str(audio),'-c:v','copy','-c:a','aac','-b:a','128k','-movflags','+faststart','-shortest',str(video)],check=True);silent.unlink()
def sha(file):return hashlib.sha256(file.read_bytes()).hexdigest()
provenance={'format':1,'parameters':{k:cfg[k] for k in ['speed','time','seed','shape']},'grid':n,'steps':steps,'dt':dt,'duration':cfg['duration'],'fps':cfg['fps'],'probe':cfg['probe'],'sonification':'220 Hz carrier; amplitude from |u(probe)|; same 2x slowed timeline, not physical sound','inputSHA256':hashlib.sha256(raw).hexdigest(),'scriptSHA256':sha(pathlib.Path(__file__)),'numpy':np.__version__,'ffmpeg':subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0],'outputs':{name:{'sha256':sha(ROOT/name),'bytes':(ROOT/name).stat().st_size} for name in ['experiment.mp4','sonification.wav','final.bin','recording-poster.png']}}
(ROOT/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n');print(json.dumps(provenance,indent=2))
