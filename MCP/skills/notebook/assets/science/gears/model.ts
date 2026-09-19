import design from './design.json' with {type:'json'};
export {design};
export const tau = 2 * Math.PI;
export const centers = design.gears.reduce<number[]>((xs,g,i) => [...xs,i ? xs[i-1]! + design.module * (design.gears[i-1]!.teeth + g.teeth) / 2 : -75],[]);
export const ratios = design.gears.map((g,i) => (i % 2 ? -1 : 1) * design.gears[0]!.teeth / g.teeth);
export function angles(phase:number) {return ratios.map((ratio,i) => tau * 2 * phase * ratio + (i % 2 ? Math.PI / design.gears[i]!.teeth : 0));}
export type State = {phase:number;reveal:number;selected:string;field:boolean;camera:[number,number,number]};
const bounded = (v:unknown,min:number,max:number,fallback:number) => typeof v==='number' && Number.isFinite(v) ? Math.max(min,Math.min(max,v)) : fallback;
export function selection(raw:unknown):State {
  const v=(raw && typeof raw==='object' ? raw : {}) as Partial<State>;
  let camera:[number,number,number]=[100,245,300];
  if(Array.isArray(v.camera)&&v.camera.length===3&&v.camera.every(n=>typeof n==='number'&&Number.isFinite(n))) {
    const length=Math.hypot(...v.camera);if(length>=180&&length<=720)camera=[...v.camera];
  }
  return {phase:bounded(v.phase,0,1,.08),reveal:bounded(v.reveal,0,1,.5),selected:design.gears.some(g=>g.id===v.selected)?v.selected!:'input',field:v.field===true,camera};
}
/** Tangential velocity in model mm/s; input makes 2 turns in 16 seconds. */
export function velocity(gear:number,x:number,z:number) {const omega=ratios[gear]! * tau / 8;return [omega*z,-omega*x] as const;}
