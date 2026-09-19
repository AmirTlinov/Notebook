// One WebGL renderer with per-pixel depth testing; camera and playback are independent.
(() => {
  const {$,mount}=Science,TAU=Math.PI*2;
  const brass=[211,178,115],steel=[192,199,210],copper=[211,155,113],plate=[201,206,216];
  function camera(yaw,tilt,reveal){
    const cy=Math.cos(yaw),sy=Math.sin(yaw),ct=Math.cos(tilt),st=Math.sin(tilt);
    const rotation=[cy,sy*ct,sy*st,-sy,cy*ct,cy*st,0,-st,ct];
    const raw=([x,y,z])=>{const u=x*cy-y*sy,v=x*sy+y*cy,depth=v*st+z*ct,p=1250/(1250-depth);return [u*p,(v*ct-z*st)*p];};
    const bounds=[];for(const x of [-246,246])for(const y of [-143,143])for(const z of [-29,48+reveal*130])bounds.push(raw([x,y,z]));
    const xs=bounds.map(p=>p[0]),ys=bounds.map(p=>p[1]),left=Math.min(...xs),right=Math.max(...xs),top=Math.min(...ys),bottom=Math.max(...ys);
    return {rotation,frame:[(left+right)/2,(top+bottom)/2,Math.min(1.35,840/(right-left),430/(bottom-top))]};
  }
  function renderer(canvas){
    const gl=canvas.getContext('webgl',{alpha:false,antialias:true,depth:true});
    if(!gl)throw new Error('Для объёмного механизма нужен WebGL.');
    function shader(type,source){const result=gl.createShader(type);gl.shaderSource(result,source);gl.compileShader(result);if(!gl.getShaderParameter(result,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(result));return result;}
    const vertex=shader(gl.VERTEX_SHADER,`
      attribute vec3 position; attribute vec3 normal; attribute vec3 color;
      uniform mat3 rotation; uniform vec3 frame;
      varying vec3 vNormal; varying vec3 vColor; varying vec3 vPosition;
      void main(){
        vec3 p=rotation*position; float w=1250.0-p.z;
        gl_Position=vec4(frame.z*(1250.0*p.x-frame.x*w)/450.0,
          -frame.z*(1250.0*p.y-frame.y*w)/245.0,
          (2600.0*w-2400000.0)/1400.0,w);
        vNormal=rotation*normal;vColor=color;vPosition=p;
      }`);
    const fragment=shader(gl.FRAGMENT_SHADER,`
      precision mediump float;
      varying vec3 vNormal; varying vec3 vColor; varying vec3 vPosition;
      void main(){
        vec3 n=normalize(vNormal),light=normalize(vec3(-0.3,-0.45,0.85));
        vec3 view=normalize(vec3(-vPosition.xy,1250.0-vPosition.z));
        float diffuse=0.52+0.48*max(dot(n,light),0.0);
        float specular=0.13*pow(max(dot(n,normalize(light+view)),0.0),32.0);
        gl_FragColor=vec4(vColor*diffuse+specular,1.0);
      }`);
    const program=gl.createProgram();gl.attachShader(program,vertex);gl.attachShader(program,fragment);gl.linkProgram(program);
    if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(program));
    gl.deleteShader(vertex);gl.deleteShader(fragment);gl.useProgram(program);
    const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
    ['position','normal','color'].forEach((name,i)=>{const location=gl.getAttribLocation(program,name);gl.enableVertexAttribArray(location);gl.vertexAttribPointer(location,3,gl.FLOAT,false,36,i*12);});
    const rotation=gl.getUniformLocation(program,'rotation'),frame=gl.getUniformLocation(program,'frame');
    gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LEQUAL);gl.clearDepth(1);gl.clearColor(1,1,1,1);
    let lastVertices;
    return (vertices,view)=>{
      const ratio=Math.min(devicePixelRatio||1,2),width=Math.max(1,Math.round(canvas.clientWidth*ratio)),height=Math.max(1,Math.round(canvas.clientHeight*ratio));
      if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
      gl.viewport(0,0,width,height);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
      if(vertices!==lastVertices){gl.bufferData(gl.ARRAY_BUFFER,vertices,gl.DYNAMIC_DRAW);lastVertices=vertices;}
      gl.uniformMatrix3fv(rotation,false,view.rotation);gl.uniform3f(frame,...view.frame);gl.drawArrays(gl.TRIANGLES,0,vertices.length/9);
    };
  }
  function mesh(){
    const vertices=[];
    function face(points,color){
      const a=points[0],b=points[1],c=points[2],u=b.map((v,i)=>v-a[i]),v=c.map((w,i)=>w-a[i]);
      const cross=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]],length=Math.hypot(...cross);
      if(length<1e-9)return;
      const normal=cross.map(v=>v/length),rgb=color.map(v=>v/255);
      for(let i=1;i<points.length-1;i++)for(const point of [a,points[i],points[i+1]])vertices.push(...point,...normal,...rgb);
    }
    function extrude(points,z,height,color){
      face(points.map(([x,y])=>[x,y,z+height]),color);
      face(points.slice().reverse().map(([x,y])=>[x,y,z]),color);
      for(let i=0;i<points.length;i++){const a=points[i],b=points[(i+1)%points.length];face([[...a,z],[...b,z],[...b,z+height],[...a,z+height]],color);}
    }
    function ring(outer,inner,z,height,color){
      for(let i=0;i<outer.length;i++){
        const j=(i+1)%outer.length,a=outer[i],b=outer[j],c=inner[i],d=inner[j];
        face([[...a,z+height],[...b,z+height],[...d,z+height],[...c,z+height]],color);
        face([[...c,z],[...d,z],[...b,z],[...a,z]],color);
        face([[...a,z],[...b,z],[...b,z+height],[...a,z+height]],color);
        face([[...c,z+height],[...d,z+height],[...d,z],[...c,z]],color);
      }
    }
    function circle(cx,cy,r,n=32){return Array.from({length:n},(_,i)=>[cx+r*Math.cos(TAU*i/n),cy+r*Math.sin(TAU*i/n)]);}
    function cylinder(cx,cy,r,z,h,color){extrude(circle(cx,cy,r),z,h,color);}
    function wheel(cx,r,teeth,angle,color){
      const inner=r*.7,outer=[],inside=[];
      for(let j=0;j<teeth;j++)for(const [part,rr] of [[-.5,r-3],[-.27,r+3],[.27,r+3],[.5,r-3]]){
        const a=(j+part)*TAU/teeth+angle;outer.push([cx+rr*Math.cos(a),rr*Math.sin(a)]);inside.push([cx+inner*Math.cos(a),inner*Math.sin(a)]);
      }
      ring(outer,inside,0,7,color);
      for(let j=0;j<6;j++){
        const a=angle+j*TAU/6,c=Math.cos(a),s=Math.sin(a),pts=[[9,-5],[inner+2,-5],[inner+2,5],[9,5]].map(([x,y])=>[cx+x*c-y*s,x*s+y*c]);extrude(pts,1,5,color);
      }
      cylinder(cx,0,r*.19,0,11,color);cylinder(cx,0,5,-18,66,steel);
      cylinder(cx+(r-9)*Math.cos(angle),(r-9)*Math.sin(angle),3.2,7,1,[242,92,52]);
    }
    return {extrude,ring,cylinder,wheel,finish:()=>new Float32Array(vertices)};
  }
  function geometry(s){
    const m=mesh(),z=37+s.reveal*130;
    const outer=Array.from({length:96},(_,i)=>[242*Math.cos(TAU*i/96),139*Math.sin(TAU*i/96)]),inner=Array.from({length:96},(_,i)=>[225*Math.cos(TAU*i/96),119*Math.sin(TAU*i/96)]);
    m.ring(outer,inner,-29,12,plate);
    m.extrude([[-233,-18],[233,-18],[233,18],[-233,18]],-28,10,plate);
    const xs=[-130,45,157],rs=[105,70,42],teeth=[60,40,24],angles=ScienceModels.gears(s.phase);
    for(let i=0;i<3;i++)m.wheel(xs[i],rs[i],teeth[i],angles[i],[brass,steel,copper][i]);
    for(const x of [-223,218]){m.cylinder(x,0,8,-18,55,steel);m.cylinder(x,0,14,z,9,plate);m.cylinder(x,0,5,z+9,2,steel);}
    m.extrude([[-225,-15],[208,-15],[227,-4],[227,10],[211,18],[-210,18],[-228,7]],z,7,plate);
    for(const x of xs){m.cylinder(x,0,11,z+7,3,steel);m.cylinder(x,0,5,z+10,1,[119,127,145]);}
    return m.finish();
  }
  const el=$('gear-canvas');let render,vertices,key,lost=false;
  try{render=renderer(el);}catch(error){$('gear-error').hidden=false;$('gear-error').textContent=error.message;notebook.ready(Promise.reject(error));return;}
  const app=mount({defaults:{phase:.08,reveal:.3,yaw:-.42,tilt:.82},ranges:{phase:[0,1],reveal:[0,1],yaw:[-Math.PI,Math.PI],tilt:[.25,1.3]},
    tick:(s,dt)=>({phase:(s.phase+dt/16000)%1}),draw(s){
      if(lost)return;
      const nextKey=`${s.phase}/${s.reveal}`;if(nextKey!==key){vertices=geometry(s);key=nextKey;}
      render(vertices,camera(s.yaw,s.tilt,s.reveal));
    }});
  new ResizeObserver(()=>app.render()).observe(el);
  el.addEventListener('webglcontextlost',e=>{e.preventDefault();lost=true;app.stop();$('gear-error').hidden=false;$('gear-error').textContent='3D-контекст временно недоступен.';app.render();});
  el.addEventListener('webglcontextrestored',()=>{render=renderer(el);lost=false;$('gear-error').hidden=true;app.render();});
  $('gear-step').onclick=()=>app.change({phase:(app.state.phase+.05)%1});
  let drag=null;
  el.addEventListener('blur',()=>delete el.dataset.pointerFocus);
  el.onpointerdown=e=>{e.preventDefault();el.dataset.pointerFocus='';el.focus({preventScroll:true});drag={x:e.clientX,y:e.clientY,yaw:app.state.yaw,tilt:app.state.tilt};el.setPointerCapture(e.pointerId);};
  // Rotate the near surface with the pointer, not against it.
  el.onpointermove=e=>{if(!drag)return;app.change({yaw:drag.yaw-(e.clientX-drag.x)*.006,tilt:drag.tilt-(e.clientY-drag.y)*.005},false,{pause:false});};
  function release(){if(drag){drag=null;app.save();}}el.onpointerup=release;el.onpointercancel=release;
  el.onkeydown=e=>{delete el.dataset.pointerFocus;if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();app.change({yaw:app.state.yaw+(e.key==='ArrowLeft'?.1:e.key==='ArrowRight'?-.1:0),tilt:app.state.tilt+(e.key==='ArrowUp'?.1:e.key==='ArrowDown'?-.1:0)},true,{pause:false});};
})();
