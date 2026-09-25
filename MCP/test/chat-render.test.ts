import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';

// Counts actual chat-shell work; native WebKit tests separately exercise layout,
// selection, offline MathJax and scrolling on the same production renderer.
class Element {
  dataset:Record<string,string>={};children:Element[]=[];parentElement:Element|null=null;
  className='';textContent='';innerHTML='';open=false;
  classList={add:()=>{}};
  constructor(public tagName:string){}
  append(...nodes:Element[]){for(const n of nodes)this.insertBefore(n,null);}
  prepend(...nodes:Element[]){for(const n of nodes.reverse())this.insertBefore(n,this.children[0]??null);}
  insertBefore(node:Element,before:Element|null){node.remove();const i=before?this.children.indexOf(before):this.children.length;this.children.splice(i,0,node);node.parentElement=this;}
  remove(){if(this.parentElement){const a=this.parentElement.children;a.splice(a.indexOf(this),1);this.parentElement=null;}}
  replaceChildren(...nodes:Element[]){for(const n of [...this.children])n.remove();this.append(...nodes);}
  get childElementCount(){return this.children.length;}
  get firstElementChild(){return this.children[0];}get lastElementChild(){return this.children.at(-1);}
  setAttribute(){}addEventListener(){}scrollIntoView(){}
  matches(selector:string){return selector.startsWith('.')?this.className===selector.slice(1):selector==='details[open]'?this.tagName==='details'&&this.open:this.tagName===selector;}
  querySelectorAll(selector:string):Element[]{return this.children.flatMap(x=>[...(x.matches(selector)?[x]:[]),...x.querySelectorAll(selector)]);}
  querySelector(selector:string){return this.querySelectorAll(selector)[0];}
  getBoundingClientRect(){return {top:0,bottom:20,height:20};}
}
test('chat delta retains unchanged nodes and typesets only changed message bodies',async()=>{
  const html=readFileSync(new URL('../../Applications/WebResources/chat-shell.html',import.meta.url),'utf8');
  const source=html.slice(html.indexOf('<script>\nconst escapeMath')+8,html.lastIndexOf('</script>'));
  let parses=0;const typesets:number[]=[];const root=new Element('main');
  const window:any={};
  runInNewContext(source,{window,document:{getElementById:()=>root,createElement:(s:string)=>new Element(s),createElementNS:(_:string,s:string)=>new Element(s),documentElement:{scrollHeight:100}},
    MathJax:{startup:{promise:Promise.resolve()},typesetClear(){},async typesetPromise(nodes:Element[]){typesets.push(nodes.length);}},
    marked:{use(){},parse(s:string){parses++;return s;}},DOMPurify:{sanitize:(s:string)=>s},scrollY:0,innerHeight:1000,scrollTo(){},scrollBy(){}});
  const messages=Array.from({length:128},(_,i)=>({id:'message-'+i,role:'assistant',text:'Body '+i}));
  const base={conversation:'one',reset:false,order:messages.map(m=>m.id),upserts:messages,removed:[],work:null,turnStatuses:{},focus:null};
  await window.updateMessages(base);assert.equal(parses,128);assert.deepEqual(typesets,[128]);
  const first=root.children[0]!,changed=root.children[127];
  await window.updateMessages({...base,upserts:[{...messages[127],text:'Changed'}]});
  assert.equal(parses,129);assert.equal(root.children[0],first);assert.equal(root.children[127],changed);assert.deepEqual(typesets,[128,1]);
  await window.updateMessages({...base,upserts:[],work:{turnID:'work',title:'Working',running:true}});
  assert.equal(parses,129);assert.equal(root.children[0],first);assert.deepEqual(typesets,[128,1]);
  await window.updateMessages({...base,upserts:[],order:messages.slice(1).map(m=>m.id),removed:[messages[0]!.id]});
  assert.equal(root.children.length,127);assert.equal(first.parentElement,null);
  const activity={id:'tool',turnID:'turn',role:'assistant',text:'Command',activity:{kind:'command',status:'completed'}};
  await window.updateMessages({...base,order:['tool'],removed:messages.map(m=>m.id),upserts:[activity]});
  const group=root.children[0]!;group.open=true;const article=group.children[1];
  await window.updateMessages({...base,order:['tool'],upserts:[],turnStatuses:{turn:'interrupted'}});
  assert.equal(root.children[0],group);assert.equal(group.open,true);assert.equal(group.children[1],article);
  assert.match(group.querySelector('.work-label')!.textContent,/Остановлено/);
  assert.equal(parses,129);
});
