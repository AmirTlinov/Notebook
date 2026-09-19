import * as THREE from 'three';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';
import {RoomEnvironment} from 'three/addons/environments/RoomEnvironment.js';
import {OrbitControls} from 'three/addons/controls/OrbitControls.js';
import './style.css';
import modelURL from './mechanism.gltf';
import geometryURL from './mechanism.bin';
import surfaceURL from './machined.png';
import roughnessURL from './roughness.png';
import posterURL from './poster.svg';
import metadata from './metadata.json';
import {design,centers,ratios,angles,selection,velocity,tau} from './model.ts';
const get=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const canvas=get<HTMLCanvasElement>('gear-canvas'),status=get('model-status'),errorView=get('model-error'),retry=get<HTMLButtonElement>('retry');
const phase=get<HTMLInputElement>('phase'),reveal=get<HTMLInputElement>('reveal'),field=get<HTMLInputElement>('field'),play=get<HTMLButtonElement>('play');
const events=new AbortController(),theme=matchMedia('(prefers-color-scheme:dark)');
let state=selection(notebook.state),suspended=false,disposed=false,lost=false,playing=false,frame=0,previous=0;
let renderer:THREE.WebGLRenderer|undefined,controls:OrbitControls|undefined,model:THREE.Group|undefined;
let environment:THREE.WebGLRenderTarget|undefined,environmentDirty=true;
let loading:Promise<void>|undefined,request:AbortController|undefined,manager:THREE.LoadingManager|undefined;
const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(38,1,1,1600),fieldGroup=new THREE.Group();
const meshes:THREE.Mesh[]=[],resources=new Set<THREE.BufferGeometry|THREE.Material|THREE.Texture>();
const active=()=>!disposed&&!suspended;
const light=new THREE.HemisphereLight(0xffffff,0x888e9a,.7);scene.add(light);
for(const [position,power] of [[[0,300,150],2],[[-200,80,-180],.8]] as const){const l=new THREE.DirectionalLight(0xffffff,power);l.position.fromArray(position);scene.add(l);}
scene.add(fieldGroup);
function collect(root:THREE.Object3D) {root.traverse(o=>{if(o instanceof THREE.Mesh||o instanceof THREE.Line){resources.add(o.geometry);for(const m of Array.isArray(o.material)?o.material:[o.material])resources.add(m);}});}
function releaseModel() {
  model?.removeFromParent();model=undefined;meshes.length=0;fieldGroup.clear();
  for(const r of resources){r.dispose();if(r instanceof THREE.Texture && r.image instanceof ImageBitmap)r.image.close();}
  resources.clear();
}
function sync() {
  phase.value=String(state.phase);reveal.value=String(state.reveal);field.checked=state.field;
  get('phase-value').textContent=(state.phase*16).toLocaleString('ru-RU',{minimumFractionDigits:1,maximumFractionDigits:1})+' с';play.textContent=playing?'Пауза':'Пуск';
  for(const el of document.querySelectorAll<HTMLInputElement|HTMLButtonElement>('input,button'))el.disabled=!active()||lost||(!model&&el!==retry);
  for(const b of document.querySelectorAll<HTMLButtonElement>('[data-part]'))b.setAttribute('aria-pressed',String(b.dataset.part===state.selected));
  const i=design.gears.findIndex(g=>g.id===state.selected),g=design.gears[i]!;
  get('part-description').textContent=`${g.label}: ${g.teeth} ${g.teeth===24?'зуба':'зубьев'}, делительный радиус ${g.teeth*design.module/2} мм. ${i===1?'Меняет направление, но не итоговое передаточное отношение.':i===2?'Вращается в ту же сторону, в 2,5 раза быстрее ведущего.':'Задаёт движение всей передачи.'}`;
}
function commit() {if(active())notebook.commit({...state,camera:[...state.camera]});}
function snapshotCamera() {state={...state,camera:camera.position.toArray() as [number,number,number]};}
function applyCamera() {camera.position.set(...state.camera);camera.lookAt(0,0,0);controls?.update();}
function draw() {
  frame=0;if(!active()||lost||!renderer||!model)return;
  const now=performance.now();if(playing){state={...state,phase:(state.phase+Math.min(50,previous?now-previous:0)/16000)%1};previous=now;phase.value=String(state.phase);get('phase-value').textContent=(state.phase*16).toLocaleString('ru-RU',{minimumFractionDigits:1,maximumFractionDigits:1})+' с';}
  const rotation=angles(state.phase);design.gears.forEach((g,i)=>{model!.getObjectByName(g.id)!.rotation.y=rotation[i]!;});
  model.getObjectByName('bridge')!.position.y=state.reveal*65;
  fieldGroup.visible=state.field;
  for(const mesh of meshes){const material=mesh.material as THREE.MeshStandardMaterial;material.emissive.setHex(mesh.userData.partID===state.selected?0x292315:0);}
  const {width,height}=canvas.getBoundingClientRect(),w=Math.max(1,Math.round(width)),h=Math.max(1,Math.round(height));
  const dpr=Math.min(devicePixelRatio||1,2,1600/Math.max(w,h));
  if(renderer.getPixelRatio()!==dpr||canvas.width!==Math.round(w*dpr)||canvas.height!==Math.round(h*dpr)){renderer.setPixelRatio(dpr);renderer.setSize(w,h,false);camera.aspect=w/h;camera.fov=2*Math.atan(Math.max(190,345/camera.aspect)/800)*180/Math.PI;camera.updateProjectionMatrix();}
  if(environmentDirty){environment?.dispose();const studio=new RoomEnvironment(),pmrem=new THREE.PMREMGenerator(renderer);environment=pmrem.fromScene(studio,.04);scene.environment=environment.texture;scene.environmentIntensity=.7;// RoomEnvironment.dispose releases materials/geometries, not its InstancedMesh attributes.
    studio.traverse(o=>{if(o instanceof THREE.InstancedMesh)o.dispose();});studio.dispose();pmrem.dispose();environmentDirty=false;}
  scene.background=new THREE.Color(theme.matches?0x17191f:0xffffff);
  renderer.render(scene,camera);if(playing)frame=requestAnimationFrame(draw);
}
// One requested static frame is synchronous, including offscreen preparation and
// checkpoint. Only continuous playback is scheduled on the display clock.
function renderNow(){cancelAnimationFrame(frame);frame=0;draw();}
function invalidate(){if(active()&&!lost&&!frame&&model)frame=requestAnimationFrame(draw);}
function stop(){playing=false;previous=0;cancelAnimationFrame(frame);frame=0;}
function change(patch:Partial<typeof state>,save=true){if(!active()||lost)return;state=selection({...state,...patch});sync();invalidate();if(save)commit();}
function showError(error:unknown) {if(disposed||suspended)return;errorView.hidden=false;errorView.textContent=error instanceof Error?error.message:String(error);status.textContent='3D не готово';get('poster').hidden=false;retry.hidden=!renderer;sync();}
function vectors() {
  for(let i=0;i<design.gears.length;i++)for(const radius of [.35,.62,.88])for(let j=0;j<12;j++){
    const r=design.gears[i]!.teeth*design.module/2*radius,a=j*tau/12,x=r*Math.cos(a),z=r*Math.sin(a),v=velocity(i,x,z);
    const arrow=new THREE.ArrowHelper(new THREE.Vector3(v[0],0,v[1]).normalize(),new THREE.Vector3(centers[i]!+x,8,z),Math.hypot(...v)*.2,0x8c489b,2.5,1.6);fieldGroup.add(arrow);
  }
  collect(fieldGroup);
}
async function load() {
  if(loading)return loading;
  if(!active()||model||!renderer)return;
  errorView.hidden=true;retry.hidden=true;status.textContent='Загрузка локальной модели…';
  const abort=new AbortController();request=abort;const owner=new THREE.LoadingManager();manager=owner;
  const work=(async()=>{
    const response=await fetch(modelURL,{signal:abort.signal});if(!response.ok)throw new Error('Не удалось прочитать локальную модель.');
    const json=await response.json();
    if(json.asset?.version!=='2.0'||json.buffers?.length!==1||json.buffers[0].uri!=='mechanism.bin'||json.images?.length!==2||json.images[0].uri!=='machined.png'||json.images[1].uri!=='roughness.png')throw new Error('Неверная модель зубчатой передачи.');
    json.buffers[0].uri=geometryURL;
    // This recipe owns its two texture decodes: every late bitmap is closed, including
    // deletion/pause during decode. The standard glTF parser still owns geometry/materials.
    const textures=new Map<number,Promise<THREE.Texture>>();
    const loader=new GLTFLoader(owner).register(()=>({name:'NotebookGearTextures',loadTexture(index:number){
      if(!textures.has(index))textures.set(index,(async()=>{
        const url=[surfaceURL,roughnessURL][index];if(!url)throw new Error('Неизвестная текстура модели.');
        const response=await fetch(url,{signal:abort.signal});if(!response.ok)throw new Error('Не удалось прочитать текстуру модели.');
        const bitmap=await createImageBitmap(await response.blob(),{premultiplyAlpha:'none',colorSpaceConversion:'none'});
        if(abort.signal.aborted||disposed){bitmap.close();throw new DOMException('Aborted','AbortError');}
        const texture=new THREE.Texture(bitmap);texture.flipY=false;texture.wrapS=texture.wrapT=THREE.RepeatWrapping;texture.needsUpdate=true;resources.add(texture);return texture;
      })());return textures.get(index)!;
    }}));
    const result=await loader.parseAsync(JSON.stringify(json),'');collect(result.scene);
    if(abort.signal.aborted||!active()){result.scene.removeFromParent();return;}
    for(const id of [...design.gears.map(g=>g.id),'bridge'])if(!result.scene.getObjectByName(id))throw new Error('В модели отсутствует деталь: '+id);
    model=result.scene;model.scale.setScalar(1000);get('poster').hidden=true;model.traverse(o=>{if(o instanceof THREE.Mesh){meshes.push(o);o.material=o.material.clone();resources.add(o.material);}});
    scene.add(model);vectors();status.textContent='Вращайте · коснитесь колеса';sync();renderNow();
  })();
  loading=work;
  try{await work;}catch(error){if(!abort.signal.aborted)showError(error);throw error;}
  finally{
    // Late texture decodes see this abort and close their bitmap before registering it.
    const interrupted=abort.signal.aborted;abort.abort();owner.abort();loading=undefined;request=undefined;manager=undefined;
    if(!model)releaseModel();
    if(interrupted&&active()&&!model)queueMicrotask(startLoad);
  }
}
function startLoad(){void load().catch(()=>{});}
const observer=new ResizeObserver(invalidate);observer.observe(canvas);
try {
  const context=canvas.getContext('webgl2',{antialias:true,alpha:false});
  if(!context)throw new Error('WebGL 2 недоступен. 3D-модель не запущена; формула и параметры передачи остаются доступны.');
  renderer=new THREE.WebGLRenderer({canvas,context,antialias:true,alpha:false});renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=.95;
  controls=new OrbitControls(camera,canvas);controls.enablePan=false;controls.enableDamping=false;controls.minDistance=180;controls.maxDistance=720;controls.maxPolarAngle=Math.PI*.87;controls.minPolarAngle=.02;
  applyCamera();controls.addEventListener('change',()=>{if(active()){snapshotCamera();invalidate();}});controls.addEventListener('end',commit);
  canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();lost=true;environmentDirty=true;stop();if(controls)controls.enabled=false;sync();errorView.hidden=false;errorView.textContent='3D-контекст временно потерян. Ракурс и выбранная деталь сохранены; ожидается восстановление.';status.textContent='Ожидание WebGL';},{signal:events.signal});
  canvas.addEventListener('webglcontextrestored',()=>{if(disposed)return;lost=false;if(controls)controls.enabled=active();errorView.hidden=true;status.textContent='Вращайте · коснитесь колеса';sync();renderNow();},{signal:events.signal});
}catch(error){showError(error);}
let pointer:{x:number;y:number;id:number}|undefined,moved=false;
canvas.addEventListener('pointerdown',e=>{if(!active()||lost)return;canvas.dataset.pointerFocus='';if(pointer)moved=true;else{pointer={x:e.clientX,y:e.clientY,id:e.pointerId};moved=false;}},{signal:events.signal});
canvas.addEventListener('pointermove',e=>{if(pointer&&Math.hypot(e.clientX-pointer.x,e.clientY-pointer.y)>6)moved=true;},{signal:events.signal});
canvas.addEventListener('pointerup',e=>{
  if(active()&&!lost&&pointer?.id===e.pointerId&&!moved&&model){const rect=canvas.getBoundingClientRect(),ray=new THREE.Raycaster();ray.setFromCamera(new THREE.Vector2((e.clientX-rect.left)/rect.width*2-1,-(e.clientY-rect.top)/rect.height*2+1),camera);
    const hit=ray.intersectObjects(meshes)[0];if(hit&&design.gears.some(g=>g.id===hit.object.userData.partID))change({selected:hit.object.userData.partID});}
  pointer=undefined;delete canvas.dataset.pointerFocus;
},{signal:events.signal});
canvas.addEventListener('pointercancel',()=>{pointer=undefined;delete canvas.dataset.pointerFocus;},{signal:events.signal});
canvas.addEventListener('keydown',e=>{if(!active()||lost||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','+','-'].includes(e.key))return;e.preventDefault();const p=new THREE.Spherical().setFromVector3(camera.position);p.theta+=e.key==='ArrowLeft'?-.12:e.key==='ArrowRight'?.12:0;p.phi=Math.max(.02,Math.min(Math.PI*.87,p.phi+(e.key==='ArrowUp'?-.12:e.key==='ArrowDown'?.12:0)));p.radius=Math.max(180,Math.min(720,p.radius*(e.key==='+'?.9:e.key==='-'?1.1:1)));camera.position.setFromSpherical(p);controls?.update();snapshotCamera();commit();invalidate();},{signal:events.signal});
for(const input of [phase,reveal]){input.addEventListener('input',()=>{if(input===phase)stop();change({[input.id]:Number(input.value)},false);},{signal:events.signal});input.addEventListener('change',commit,{signal:events.signal});}
field.addEventListener('change',()=>change({field:field.checked}),{signal:events.signal});
for(const b of document.querySelectorAll<HTMLButtonElement>('[data-part]'))b.addEventListener('click',()=>change({selected:b.dataset.part}),{signal:events.signal});
play.addEventListener('click',()=>{if(!active()||lost||!model)return;if(playing){stop();commit();}else playing=true;sync();invalidate();},{signal:events.signal});
get('front').addEventListener('click',()=>{change({camera:[0,390,1]});applyCamera();},{signal:events.signal});
get('reset').addEventListener('click',()=>{change({camera:selection(null).camera});applyCamera();},{signal:events.signal});
retry.addEventListener('click',startLoad,{signal:events.signal});theme.addEventListener('change',invalidate,{signal:events.signal});
addEventListener('notebookstate',()=>{if(disposed)return;stop();state=selection(notebook.state);applyCamera();sync();invalidate();},{signal:events.signal});
notebook.semantic(()=>{
  if(!model||lost||disposed)return null;
  const i=design.gears.findIndex(g=>g.id===state.selected),gear=design.gears[i];if(!gear)return null;
  const projected=new THREE.Vector3(centers[i]!,9,0).project(camera),rect=canvas.getBoundingClientRect();
  const x=(rect.left+(projected.x+1)/2*rect.width)/innerWidth,y=(rect.top+(1-projected.y)/2*rect.height)/innerHeight;
  if(projected.z < -1||projected.z>1||x<0||x>1||y<0||y>1)return null;
  return {objectID:gear.id,label:gear.label,anchor:{x,y},values:[{label:'Зубья',value:gear.teeth,unit:'1'},
    {label:'Делительный радиус',value:design.module*gear.teeth/2,unit:'mm'},
    {label:'Угол',value:angles(state.phase)[i]!,unit:'rad'}],
    model:{time:state.phase*16,timeUnit:'s',ratio:ratios[i]!,reveal:state.reveal,camera:[...state.camera]}};
});
notebook.lifecycle({pause(){stop();renderNow();suspended=true;request?.abort();manager?.abort();if(controls)controls.enabled=false;sync();},checkpoint(){return {...state,camera:[...state.camera]};},resume(){if(disposed)return;suspended=false;if(controls)controls.enabled=!lost;sync();if(!model)startLoad();else renderNow();},dispose(){disposed=true;stop();events.abort();observer.disconnect();request?.abort();manager?.abort();controls?.dispose();controls=undefined;releaseModel();environment?.dispose();environment=undefined;scene.environment=null;renderer?.dispose();renderer?.forceContextLoss();renderer=undefined;}});
get('model-size').textContent=`Локальный glTF: ${metadata.triangles.toLocaleString('ru-RU')} треугольников, две текстуры 2048 × 2048. Геометрия не пересобирается при движении; неподвижная сцена не запрашивает кадры.`;
get<HTMLImageElement>('poster').src=posterURL;sync();
// Ready describes the visible program UI. An explicit static/error view is not a
// successful 3D scene; retry/resume never redeclare the one startup obligation.
notebook.ready(renderer ? load().catch(()=>{}) : Promise.resolve()).catch(()=>{});
