/* Presentation only. No source/state edits, DOM clones, selection, or input handlers. */
(() => {
  'use strict';
  const style = document.createElement('style');
  style.textContent = `
    [data-nb-feedback-ink] {
      background-image:linear-gradient(105deg,var(--nb-ink) 10%,var(--nb-ink) 28%,var(--nb-crest) 54%,var(--nb-shoulder) 65%,var(--nb-ink) 82%) !important;
      background-size:250% 100% !important;
      background-position:var(--nb-position) 0 !important;
      background-clip:text !important;-webkit-background-clip:text !important;
      -webkit-text-fill-color:transparent !important;
    }
    [data-nb-feedback-surface]::after {
      content:'';position:absolute;inset:0;pointer-events:none;border-radius:inherit;z-index:2;mix-blend-mode:multiply;
      background:radial-gradient(at var(--nb-x) 25%,#99c5ef 0,transparent 58%),radial-gradient(at 80% 80%,#cbbce8 0,transparent 60%),radial-gradient(at 15% 85%,#eff8ff 0,transparent 60%);
      opacity:var(--nb-strength);
    }
  `;
  document.head.append(style);
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let records = [], frame = 0, suspension = 0, signature = '', gradientSequence = 0;
  const svgNS = 'http://www.w3.org/2000/svg';
  function clear() {
    cancelAnimationFrame(frame); frame = 0;
    for (const r of records) {
      for (const el of r.ink) {
        el.removeAttribute('data-nb-feedback-ink');
        for (const name of ['--nb-ink','--nb-position','--nb-crest','--nb-shoulder']) el.style.removeProperty(name);
      }
      for (const el of r.surfaces) {
        el.removeAttribute('data-nb-feedback-surface');
        for (const name of ['--nb-x','--nb-strength']) el.style.removeProperty(name);
      }
      for (const v of r.vectors) {
        if (v.old) v.el.style.setProperty(v.attr,v.old,v.priority); else v.el.style.removeProperty(v.attr);
        v.defs.remove();
      }
    }
    records = [];
  }
  function paint() {
    cancelAnimationFrame(frame); frame = 0;
    const now = Date.now();
    let moving = false;
    for (const r of records) {
      const e = r.effect, age = (now-e.start)/1000, left = (e.end-now)/1000;
      const active = e.attention || left > 0;
      const phase = reduced.matches || e.attention ? .48 : ((age % 2.4)+2.4)%2.4/2.4;
      const strength = !active ? 0 : e.attention ? .32 : reduced.matches ? .5 : Math.max(0,Math.min(1,age/.18,left/.55));
      for (const el of r.ink) {
        if (suspension || strength === 0) el.removeAttribute('data-nb-feedback-ink');
        else { el.setAttribute('data-nb-feedback-ink',''); el.style.setProperty('--nb-position',`${150-phase*300}%`); el.style.setProperty('--nb-crest',`color-mix(in srgb, var(--nb-ink) ${100-strength*90}%, white)`); el.style.setProperty('--nb-shoulder',`color-mix(in srgb, var(--nb-ink) ${100-strength*65}%, #bad7f6)`); }
      }
      for (const el of r.surfaces) {
        if (suspension || strength === 0) el.removeAttribute('data-nb-feedback-surface');
        else el.setAttribute('data-nb-feedback-surface','');
        el.style.setProperty('--nb-x',`${25+Math.sin(phase*Math.PI*2)*30}%`);
        el.style.setProperty('--nb-strength',String(strength*.55));
      }
      for (const v of r.vectors) {
        if (suspension || strength === 0) {
          if (v.old) v.el.style.setProperty(v.attr,v.old,v.priority); else v.el.style.removeProperty(v.attr);
          continue;
        }
        v.el.style.setProperty(v.attr,`url(#${v.gradient.id})`,'important');
        const color = `color-mix(in srgb, ${v.color} ${100-strength*85}%, white)`;
        v.crest.setAttribute('stop-color',color);
        v.gradient.setAttribute('x1',String(v.x+(phase*3-1)*v.width));
        v.gradient.setAttribute('x2',String(v.x+phase*3*v.width));
      }
      moving ||= !suspension && active && !e.attention && !reduced.matches;
    }
    if (moving) frame = requestAnimationFrame(paint);
  }
  function update(effects) {
    const next = JSON.stringify(effects);
    if (signature === next) return;
    clear(); signature = next;
    const chosen = new Map();
    for (const root of document.querySelectorAll('#document .block[data-block-id]')) {
      for (const effect of effects) {
        if (effect.blockID != null && effect.blockID !== root.dataset.blockId) continue;
        const old = chosen.get(root);
        if (!old || effect.start > old.start || (effect.start === old.start && effect.blockID != null)) chosen.set(root,effect);
      }
    }
    for (const [selectedRoot,effect] of chosen) {
      const roots = [selectedRoot];
      const ink = [], surfaces = [], vectors = [];
      for (const root of roots) {
        if (root.classList.contains('interactive')) {
          for (const frame of document.querySelectorAll('#interactive-layer iframe[data-block-id]'))
            if (frame.dataset.blockId === root.dataset.blockId) surfaces.push(frame.parentElement);
          continue;
        }
        for (const el of [root,...root.querySelectorAll('*')]) {
          if (el.namespaceURI === svgNS || el.closest('svg,iframe,textarea,script,style') || ![...el.childNodes].some(n=>n.nodeType===3 && n.textContent.trim())) continue;
          el.style.setProperty('--nb-ink',getComputedStyle(el).color); ink.push(el);
        }
        for (const svg of root.querySelectorAll('svg')) {
          for (const el of svg.querySelectorAll('path,text,use,line,rect,circle,ellipse,polygon,polyline')) {
            if (el.closest('defs,clipPath,mask,symbol')) continue;
            const computed = getComputedStyle(el);
            for (const attr of ['fill','stroke']) {
              const color = computed[attr]; if (!color || color==='none' || color.includes('url(')) continue;
              const box=el.getBBox(), defs=document.createElementNS(svgNS,'defs'), gradient=document.createElementNS(svgNS,'linearGradient');
              let id; do { id=`nb-feedback-${++gradientSequence}`; } while (document.getElementById(id));
              gradient.id=id;gradient.setAttribute('gradientUnits','userSpaceOnUse');gradient.setAttribute('y1','0');gradient.setAttribute('y2','0');
              let crest;
              for (const [offset,c] of [[0,color],[.55,'white'],[1,color]]) {
                const stop=document.createElementNS(svgNS,'stop');stop.setAttribute('offset',String(offset));stop.setAttribute('stop-color',c);gradient.append(stop);if(offset===.55)crest=stop;
              }
              defs.append(gradient);svg.prepend(defs);
              vectors.push({el,attr,color,old:el.style.getPropertyValue(attr),priority:el.style.getPropertyPriority(attr),defs,gradient,crest,x:box.x,width:Math.max(box.width,1)});
              el.style.setProperty(attr,`url(#${id})`,'important');
            }
          }
        }
      }
      for (const el of surfaces) el.setAttribute('data-nb-feedback-surface','');
      records.push({effect,ink,surfaces,vectors});
    }
    paint();
  }
  window.notebookAgentFeedback = {
    update,
    suspend() { suspension++;paint(); },
    resume() { suspension=Math.max(0,suspension-1);paint(); },
    clear() { clear(); signature=''; }
  };
  reduced.addEventListener('change',paint);
  addEventListener('pagehide',()=>window.notebookAgentFeedback.clear());
})();
