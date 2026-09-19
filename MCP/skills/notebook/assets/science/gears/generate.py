"""Original educational involute train. Blender 5.1, background, isolated scene.
Reference (viewed before modeling): ciechanow.ski/mechanical-watch/#mainplate.
Transfer: stable color roles, open spokes, stepped shafts, bearing-supported bridge,
constant center distances during explosion; not a copy of the watch assets.
Run: Blender --background --factory-startup --disable-autoexec --python generate.py
"""
import bpy, math, json, pathlib, numpy as np
from mathutils import Vector
ROOT=pathlib.Path(__file__).resolve().parent
D=json.loads((ROOT/'design.json').read_text()); TAU=math.tau
# The process owns a factory scene, not the user's open Blender scene.
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
collection=bpy.data.collections.new('NotebookGearTrain'); bpy.context.scene.collection.children.link(collection)
def own(o,name,part):
    o.name=name
    for c in list(o.users_collection): c.objects.unlink(o)
    collection.objects.link(o);o['partID']=part
    return o

def texture(name,rough=False):
    n=2048; y,x=np.mgrid[0:n,0:n].astype(np.float32)/n
    rng=np.random.default_rng(245)
    rings=np.sin(np.hypot(x-.5,y-.5)*950)*.015
    grain=rng.uniform(-.008,.008,(n,n)).astype(np.float32)
    v=np.clip((.43 if rough else .87)+rings+grain,0,1)
    rgba=np.ones((n,n,4),np.float32);rgba[:,:,:3]=v[:,:,None]
    im=bpy.data.images.new(name,width=n,height=n,alpha=False)
    if rough:im.colorspace_settings.name='Non-Color'
    im.pixels.foreach_set(rgba.ravel());im.filepath_raw=str(ROOT/(name+'.png'));im.file_format='PNG';im.save()
    return im
base=texture('machined');rough=texture('roughness',True)
def material(name,color,metal=.65):
    m=bpy.data.materials.new(name);m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*color,1);p.inputs['Metallic'].default_value=metal;p.inputs['Roughness'].default_value=.4
    tex=m.node_tree.nodes.new('ShaderNodeTexImage');tex.image=base
    # glTF base factor preserves material-specific role colors.
    mul=m.node_tree.nodes.new('ShaderNodeMixRGB');mul.blend_type='MULTIPLY';mul.inputs[0].default_value=1;mul.inputs[2].default_value=(*color,1)
    m.node_tree.links.new(tex.outputs['Color'],mul.inputs[1]);m.node_tree.links.new(mul.outputs[0],p.inputs['Base Color'])
    rt=m.node_tree.nodes.new('ShaderNodeTexImage');rt.image=rough;m.node_tree.links.new(rt.outputs['Color'],p.inputs['Roughness'])
    return m
steel=material('Satin steel',(.57,.62,.69));plate=material('Pale aluminium',(.77,.79,.8),.4)
ruby=material('Bearing bronze',(.35,.22,.1),.65)
def mesh(name,verts,faces,mat,part):
    data=bpy.data.meshes.new(name);data.from_pydata(verts,[],faces);data.update()
    o=own(bpy.data.objects.new(name,data),name,part);data.materials.append(mat)
    uv=data.uv_layers.new(name='Machining')
    for loop in data.loops:
        v=data.vertices[loop.vertex_index].co;uv.data[loop.index].uv=(v.x/150+.5,v.y/150+.5)
    bevel=o.modifiers.new('Edge light','BEVEL');bevel.width=.14;bevel.segments=1
    bevel.limit_method='ANGLE';bevel.angle_limit=.35
    weighted=o.modifiers.new('Weighted faces','WEIGHTED_NORMAL');weighted.keep_sharp=True
    return o

def annulus(name,outer,inner,z,h,mat,part):
    n=len(outer);v=[(x,y,zz) for zz in [z,z+h] for ring in [outer,inner] for x,y in ring];f=[]
    for i in range(n):
        j=(i+1)%n
        f.extend([(i,j,j+2*n,i+2*n),(i+n,i+3*n,j+3*n,j+n),
                  (i+2*n,j+2*n,j+3*n,i+3*n),(i,i+n,j+n,j)])
    return mesh(name,v,f,mat,part)
def ring(name,r,ri,z,h,mat,part,n=128):
    return annulus(name,[(r*math.cos(TAU*i/n),r*math.sin(TAU*i/n)) for i in range(n)],
                   [(ri*math.cos(TAU*i/n),ri*math.sin(TAU*i/n)) for i in range(n)],z,h,mat,part)
def box(name,loc,scale,mat,part):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);o=own(bpy.context.object,name,part);o.scale=scale
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True);o.data.materials.append(mat)
    b=o.modifiers.new('Machined corners','BEVEL');b.width=.7;b.segments=4
    o.modifiers.new('Weighted faces','WEIGHTED_NORMAL');return o

def group(name,loc=(0,0,0)):
    o=own(bpy.data.objects.new(name,None),name,name);o.location=loc;return o

def tooth_outline(n):
    m=D['module'];rp=n*m/2;rb=rp*math.cos(math.radians(D['pressureAngleDegrees']));ra=rp+m;rf=rp-1.25*m
    inv=lambda r: math.sqrt(max(0,(r/rb)**2-1))-math.acos(min(1,rb/r))
    half=math.pi/(2*n)-D['backlash']/(2*rp);start=max(rb,rf)
    pts=[]
    for t in range(n):
        center=TAU*t/n
        # Counter-clockwise outline: root, involute flank, addendum, opposite flank.
        left=-half-inv(rp)
        pts.append((rf,center-math.pi/n));pts.append((rf,center+left))
        for i in range(13):
            r=start+(ra-start)*i/12;pts.append((r,center-half-inv(rp)+inv(r)))
        tip=half+inv(rp)-inv(ra)
        for i in range(1,5):pts.append((ra,center-tip+2*tip*i/4))
        for i in range(11,-1,-1):
            r=start+(ra-start)*i/12;pts.append((r,center+half+inv(rp)-inv(r)))
        pts.append((rf,center-left))
    return [(r*math.cos(a),r*math.sin(a)) for r,a in pts]

xs=[-75.]
for a,b in zip(D['gears'],D['gears'][1:]):xs.append(xs[-1]+D['module']*(a['teeth']+b['teeth'])/2)
for spec,x in zip(D['gears'],xs):
    part=spec['id'];n=spec['teeth'];r=n*D['module']/2;g=group(part,(x,0,0))
    srgb=[int(spec['color'][i:i+2],16)/255 for i in (1,3,5)];color=tuple(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in srgb);mat=material(part,color)
    outer=tooth_outline(n);inner=[(r*.69*math.cos(math.atan2(y,x)),r*.69*math.sin(math.atan2(y,x))) for x,y in outer]
    o=annulus(part+'-rim',outer,inner,-3,6,mat,part);o.parent=g
    for i in range(6):
        a=TAU*i/6;length=r*.69-5
        o=box(part+'-spoke-'+str(i),((length/2+5)*math.cos(a),(length/2+5)*math.sin(a),0),(length,3.1,4),mat,part);o.rotation_euler.z=a;o.parent=g
    for suffix,rr,ri,z,h,ma in [('hub',r*.18,3.2,-4,9,mat),('shaft',3.2,.01,-12,38,steel),('shoulder',5,3.2,-7,3,steel),('collar',5,3.2,5,2,steel)]:
        o=ring(part+'-'+suffix,rr,ri,z,h,ma,part);o.parent=g
    # A single index mark provides unambiguous angular identity.
    o=box(part+'-index',(r*.83,0,3.25),(4,1.4,.5),steel,part);o.parent=g
baseGroup=group('base')
# Open support chassis; the gears remain visible above it.
outline=[(0+146*math.cos(TAU*i/192),78*math.sin(TAU*i/192)) for i in range(192)]
inner=[(0+137*math.cos(TAU*i/192),69*math.sin(TAU*i/192)) for i in range(192)]
o=annulus('chassis',outline,inner,-16,6,plate,'base');o.parent=baseGroup
for y in [-16,16]:
    o=box('base-rail',(0,y,-13),(277,7,6),plate,'base');o.parent=baseGroup
bridge=group('bridge')
for y in [-10,10]:
    o=box('bridge-rail',(0,y,21),(276,6,5),plate,'bridge');o.parent=bridge
for x in xs:
    for z,par in [(-12,baseGroup),(21,bridge)]:
        for name,r,ri,h,ma in [('housing',9,5,5,steel),('bearing',5,3.25,5,ruby)]:
            o=ring(name+str(x)+str(z),r,ri,z,h,ma,par.name);o.location.x=x;o.parent=par
        for y in [-10,10]:
            o=box('bearing-web',(x,y,z+2),(16,6,5),plate,par.name);o.parent=par
for x in [-138,138]:
    for y in [-10,10]:
        o=ring('post',3.4,.01,-10,31,steel,'base');o.location=(x,y,0);o.parent=baseGroup
        o=ring('screw',4.4,.01,26,3,steel,'bridge',64);o.location=(x,y,0);o.parent=bridge
        o=box('screw-slot',(x,y,29),(5,.8,.3),ruby,'bridge');o.parent=bridge
# glTF uses metres in general, but this educational scene explicitly labels its model units mm.
# Keep numeric mm coordinates, documented in design and glTF extras.
scene=bpy.context.scene;scene['units']='mm';scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=.001
for o in collection.objects:o.select_set(True)
bpy.ops.export_scene.gltf(filepath=str(ROOT/'mechanism.gltf'),export_format='GLTF_SEPARATE',use_selection=True,export_apply=True,export_extras=True,export_yup=True,export_animations=False,export_cameras=False,export_lights=False)
# The exporter may bake the multiply node. Set factors explicitly and use the one original map.
p=ROOT/'mechanism.gltf';gltf=json.loads(p.read_text())
# Normalize names and materials to two shared local maps, no baked copies.
gltf['images']=[{'uri':'machined.png'},{'uri':'roughness.png'}];gltf['textures']=[{'source':0},{'source':1}]
for mat in gltf['materials']:
    pbr=mat.setdefault('pbrMetallicRoughness',{});pbr['baseColorTexture']={'index':0};pbr['metallicRoughnessTexture']={'index':1}
    original=bpy.data.materials.get(mat['name']);principled=original.node_tree.nodes.get('Principled BSDF')
    pbr['baseColorFactor']=list(principled.inputs['Base Color'].default_value)
    # G is roughness, B metallic multiplier; normalize factor so the shared map doesn't darken all metals.
    pbr['metallicFactor']=min(1,principled.inputs['Metallic'].default_value/.43);pbr['roughnessFactor']=1
    mat.pop('extensions',None)
gltf['extensionsUsed']=[];gltf.pop('extensionsRequired',None)
# Standard glTF world units are metres; the named mechanism nodes retain mm local coordinates.
roots=gltf['scenes'][gltf.get('scene',0)]['nodes'];gltf['nodes'].append({'name':'millimetres','scale':[.001,.001,.001],'children':roots});gltf['scenes'][gltf.get('scene',0)]['nodes']=[len(gltf['nodes'])-1]
p.write_text(json.dumps(gltf,separators=(',',':'))+'\n')
triangles=sum(gltf['accessors'][p['indices']]['count']//3 for m in gltf['meshes'] for p in m['primitives'])
(ROOT/'metadata.json').write_text(json.dumps({'triangles':triangles,'textures':[{'path':'machined.png','width':2048,'height':2048},{'path':'roughness.png','width':2048,'height':2048}], 'units':'mm','blender':bpy.app.version_string},indent=2)+'\n')
# Explicit static plan from the same involute outline, not a fake 3D success.
svg=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="-153 -90 306 180"><title>Статический план передачи, начальный момент</title><rect x="-153" y="-90" width="306" height="180" fill="#f7f8fa"/>']
for i,(spec,x) in enumerate(zip(D['gears'],xs)):
    r=spec['teeth']*D['module']/2;angle=math.pi/spec['teeth'] if i%2 else 0
    points=' '.join(f'{a:.3f},{b:.3f}' for a,b in tooth_outline(spec['teeth']))
    svg.append(f'<g transform="translate({x},0) rotate({angle*180/math.pi})"><polygon points="{points}" fill="{spec["color"]}" stroke="#384452" stroke-width=".3"/><circle r="{r*.68}" fill="#f7f8fa"/>')
    for j in range(6):svg.append(f'<path d="M 0 0 H {r*.7}" transform="rotate({j*60})" stroke="{spec["color"]}" stroke-width="3"/>')
    svg.append('<circle r="5" fill="#536171"/></g>')
svg.append('<text x="0" y="82" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#384452">Статический план · 60 : 40 : 24 · не интерактивный 3D</text></svg>')
(ROOT/'poster.svg').write_text(''.join(svg)+'\n')
# Retain a viewable source scene outside the published package.
artifacts=ROOT.parents[5]/'.build'/'gui-245-model';artifacts.mkdir(parents=True,exist_ok=True)
bpy.context.preferences.filepaths.save_version=0
bpy.ops.wm.save_as_mainfile(filepath=str(artifacts/'mechanism.blend'))
print('GUI245_MODEL',triangles,'triangles',artifacts)
