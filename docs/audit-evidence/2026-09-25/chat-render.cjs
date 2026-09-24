const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const repo=path.resolve(process.argv[2]||process.cwd());
const html=fs.readFileSync(path.join(repo,'Applications/WebResources/chat-shell.html'),'utf8');
const source=html.slice(html.indexOf('<script>\nconst escapeMath')+'<script>'.length,html.lastIndexOf('</script>'));
assert(source.includes('window.showMessages=async function'));
let parses=0,clears=0,typesets=0;
class Element{
 constructor(tag){this.tagName=tag;this.dataset={};this.children=[];this.classList={add(){}};}
 append(...items){this.children.push(...items);} prepend(...items){this.children.unshift(...items);}
 replaceChildren(...items){this.children=items;} querySelectorAll(){return [];}
 setAttribute(){} addEventListener(){} get childElementCount(){return this.children.length;}
}
const root=new Element('main');
const sandbox={window:{},document:{createElement:t=>new Element(t),createElementNS:(_,t)=>new Element(t),getElementById:()=>root,querySelectorAll:()=>[],documentElement:{scrollHeight:100}},MathJax:{startup:{promise:Promise.resolve()},typesetClear(){clears++;},async typesetPromise(){typesets++;}},DOMPurify:{sanitize:x=>x},marked:{use(){},parse(text){parses++;return text;}},scrollY:0,innerHeight:1000,scrollTo(){},scrollBy(){}};
vm.createContext(sandbox);vm.runInContext(source,sandbox);
(async()=>{
 const messages=Array.from({length:128},(_,i)=>({id:'message-'+i,turnID:'turn-'+i,role:'assistant',text:'Formula $x^2$ '+i}));
 await sandbox.window.showMessages(JSON.stringify(messages),'conversation');
 const original=root.children[0],first=parses;
 messages[127].text+=' delta';await sandbox.window.showMessages(JSON.stringify(messages),'conversation');
 const afterDelta=parses;
 await sandbox.window.showMessages(JSON.stringify(messages),'conversation','',{turnID:'working',title:'Working',running:true});
 const result={test:'actual chat-shell showMessages function with counting DOM and parser doubles; not a WebKit frame benchmark',messages:128,markdownParses:[first,afterDelta-first,parses-afterDelta],mathJaxClearCalls:clears,mathJaxFullRootTypesets:typesets,unchangedFirstArticleRetained:root.children[0]===original};
 console.log(JSON.stringify(result,null,2));assert.deepEqual(result.markdownParses,[128,128,128]);assert.equal(result.unchangedFirstArticleRetained,false);
})().catch(e=>{console.error(e);process.exitCode=1});
