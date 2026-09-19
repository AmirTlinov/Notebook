// A real 3D mesh, projected into SVG. Camera and exploded view do not change kinematics.
(() => {
  const {$,clamp,point,svg,mount}=Science,TAU=Math.PI*2;
  const brass=[211,178,115],steel=[192,199,210],copper=[211,155,113],plate=[201,206,216];
  function makeProject(yaw,tilt){
    const cy=Math.cos(yaw),sy=Math.sin(yaw),ct=Math.cos(tilt),st=Math.sin(tilt);
    return ([x,y,z])=>{const u=x*cy-y*sy,v=x*sy+y*cy,depth=v*st+z*ct,p=1250/(1250-depth);return [450+u*1.35*p,295+(v*ct-z*st)*1.35*p,depth];};
  }
  function mesh(project){
    const faces=[];
    function face(points,color){
      const p=points.map(project),a=points[0],b=points[1],c=points[2];
      const u=b.map((v,i)=>v-a[i]),v=c.map((w,i)=>w-a[i]),n=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]],len=Math.hypot(...n)||1;
      const light=.67+.3*Math.max(0,(-.35*n[0]-.5*n[1]+.8*n[2])/len);
      const fill=`rgb(${color.map(v=>Math.round(clamp(v*light+20,0,255))).join(',')})`;
      faces.push({depth:p.reduce((s,v)=>s+v[2],0)/p.length,body:`<polygon points="${p.map(v=>v.slice(0,2).map(x=>x.toFixed(2)).join(',')).join(' ')}" fill="${fill}" stroke="${fill}" stroke-width=".45"/>`});
    }
    function extrude(points,z,height,color){
      face(points.map(([x,y])=>[x,y,z+height]),color);
      for(let i=0;i<points.length;i++){const a=points[i],b=points[(i+1)%points.length];face([[...a,z],[...b,z],[...b,z+height],[...a,z+height]],color);}
    }
    function ring(outer,inner,z,height,color){
      for(let i=0;i<outer.length;i++){
        const j=(i+1)%outer.length,a=outer[i],b=outer[j],c=inner[i],d=inner[j];
        face([[...a,z+height],[...b,z+height],[...d,z+height],[...c,z+height]],color);
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
    return {face,extrude,ring,circle,cylinder,wheel,finish:()=>faces.sort((a,b)=>a.depth-b.depth).map(f=>f.body).join('')};
  }
  const app=mount({defaults:{phase:.08,reveal:.3,yaw:-.42,tilt:.82},ranges:{phase:[0,1],reveal:[0,1],yaw:[-Math.PI,Math.PI],tilt:[.25,1.3]},
    tick:(s,dt)=>({phase:(s.phase+dt/16000)%1}),draw(s){
      const project=makeProject(s.yaw,s.tilt),m=mesh(project),z=37+s.reveal*130;
      const outer=Array.from({length:96},(_,i)=>[242*Math.cos(TAU*i/96),139*Math.sin(TAU*i/96)]),inner=Array.from({length:96},(_,i)=>[225*Math.cos(TAU*i/96),119*Math.sin(TAU*i/96)]);
      m.ring(outer,inner,-29,12,plate);
      for(let x=-233;x<233;x+=12)m.extrude([[x,-18],[Math.min(233,x+12),-18],[Math.min(233,x+12),18],[x,18]],-28,10,plate);
      const xs=[-130,45,157],rs=[105,70,42],teeth=[60,40,24],angles=ScienceModels.gears(s.phase);
      for(let i=0;i<3;i++)m.wheel(xs[i],rs[i],teeth[i],angles[i],[brass,steel,copper][i]);
      // The removable upper bearing bridge is suspended above its fixed support posts.
      for(const x of [-223,218]){m.cylinder(x,0,8,-18,55,steel);m.cylinder(x,0,14,z,9,plate);m.cylinder(x,0,5,z+9,2,steel);}
      m.extrude([[-225,-15],[208,-15],[227,-4],[227,10],[211,18],[-210,18],[-228,7]],z,7,plate);
      for(const x of xs){m.cylinder(x,0,11,z+7,3,steel);m.cylinder(x,0,5,z+10,1,[119,127,145]);}
      let body='<ellipse cx="465" cy="378" rx="350" ry="72" fill="url(#gear-shadow)"/>';
      if(s.reveal>.06)for(const x of [-223,...xs,218]){const a=project([x,0,xs.includes(x)?48:37]),b=project([x,0,z]);body+=`<path d="M${a[0]} ${a[1]}L${b[0]} ${b[1]}" stroke="#b9bfca" stroke-width="1" stroke-dasharray="3 6"/>`;}
      body+=m.finish();
      svg('mechanism',body);
    }});
  $('gear-step').onclick=()=>app.change({phase:(app.state.phase+.05)%1});
  const el=$('gear-svg');let drag=null;
  el.onpointerdown=e=>{drag={x:e.clientX,y:e.clientY,yaw:app.state.yaw,tilt:app.state.tilt};el.setPointerCapture(e.pointerId);app.stop();};
  el.onpointermove=e=>{if(!drag)return;app.change({yaw:drag.yaw+(e.clientX-drag.x)*.006,tilt:drag.tilt+(e.clientY-drag.y)*.005},false);};
  function release(){if(drag){drag=null;app.save();}}el.onpointerup=release;el.onpointercancel=release;
  el.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();app.change({yaw:app.state.yaw+(e.key==='ArrowLeft'?-.1:e.key==='ArrowRight'?.1:0),tilt:app.state.tilt+(e.key==='ArrowUp'?-.1:e.key==='ArrowDown'?.1:0)});};
})();
