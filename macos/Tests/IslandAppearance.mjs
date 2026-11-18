// Run from the repository root. PERCH_DOM_MODULE may point to an external happy-dom installation.
const {Window} = await import(process.env.PERCH_DOM_MODULE || 'happy-dom');
import assert from 'node:assert/strict';
import fs from 'node:fs';
const w = new Window({url:'https://island.test/',settings:{disableCSSFileLoading:true,disableJavaScriptFileLoading:true}});
try {
 w.document.head.innerHTML=['dist/ui.css','theme-controls.css','island.css'].map(f=>'<style>'+fs.readFileSync('macos/Island/ui/'+f,'utf8')+'</style>').join('');
 w.document.body.innerHTML='<div id="scene"></div>';
 w.webkit={messageHandlers:{perch:{postMessage(){}}}};
 for(const f of ['blob-avatar.js','orbs.js','app.js']) w.eval(fs.readFileSync('macos/Island/ui/'+f,'utf8'));
 const p={id:'test-theme',name:'Theme check',topic:'Perch',away:'1m',at:'10:00',headline:'Review theme',context:'Reply here',next:'',app:'codex',attention:false,fresh:false,line:'',status:{kind:'idle',text:'Ready',app:'codex'},steps:[],ask:null,now:null,section:'Today',canReply:true,manage:[]};
 const base={phase:'open',screen:{hasNotch:false,notchW:148,notchH:32},projects:[p],shown:[0],selected:0,icons:{},character:{shape:'ghost',color:'#B9A2F5'},timerToken:1,activeIds:[],quiet:false,scanning:false};
 w.perch.apply({...base,appearance:'dark',palette:{'--perch-ink':'#F4F5FC'}});
 w.perch.replyMenu(true);
 const input=w.document.querySelector('.r-in');input.value='Keep my draft';input.dispatchEvent(new w.Event('input',{bubbles:true}));
 for(const appearance of ['light','dark','light']) {
  const ink=appearance==='light'?'#202432':'#F4F5FC';
  w.perch.apply({...base,appearance,palette:{'--perch-ink':ink}});
  assert.equal(w.document.documentElement.dataset.appearance,appearance);
  assert.equal(w.document.documentElement.style.getPropertyValue('--perch-ink'),ink);
  assert.equal(w.document.querySelector('.r-in'),input);
  assert.equal(input.value,'Keep my draft');
  assert.equal(w.document.querySelector('.f-rep').style.display,'flex');
  assert(w.getComputedStyle(w.document.documentElement).colorScheme===appearance);
 }
 console.log('PASS live dark/light switching retains reply input, draft and open session; native palette reaches CSS');
 // CSSOM verifies the actual winning paint declarations, including ::after which
 // happy-dom does not render. Test the state before the first native snapshot too.
 const cssRules=[...w.document.styleSheets].flatMap(sheet=>[...sheet.cssRules]);
 function backgroundLayers(node, pseudo=false) {
  const matches=cssRules.filter(rule=>rule.selectorText && rule.style).flatMap((rule,index)=>
   rule.selectorText.split(',').map(selector=>({rule,index,selector:selector.trim()})))
   .filter(({selector})=>pseudo ? selector.endsWith('::after') : !selector.includes('::'))
   .filter(({selector})=>{try{return node.matches(pseudo?selector.slice(0,-7):selector);}catch{return false;}});
  // These surface selectors contain only classes, attributes and pseudo-elements.
  const specificity=selector=>(selector.match(/\.[a-zA-Z_-][\w-]*|\[[^\]]+\]/g)||[]).length;
  matches.sort((a,b)=>specificity(a.selector)-specificity(b.selector)||a.index-b.index);
  let background='';
  for(const {rule} of matches) if(rule.style.background) background=rule.style.background;
  return background;
 }
 const n=w.document.querySelector('.n');
 for(const appearance of ['light','dark']) {
  for(const hasNotch of [true,false]) {
   w.perch.apply({...base,appearance,phase:'idle',projects:[],screen:{hasNotch,notchW:185,notchH:32}});
   assert.equal(n.dataset.act,'');
   assert.equal(backgroundLayers(n),'transparent');
   assert.equal(backgroundLayers(n,true),'transparent');
   assert.equal(n.dataset.shape,hasNotch?'1':'');
   assert.equal(n.dataset.hide,hasNotch?'':'1');
   w.perch.apply({...base,appearance});
   assert(backgroundLayers(n).includes('--perch-gradient'));
  }
 }
 n.dataset.s='idle';delete n.dataset.act;
 assert.equal(backgroundLayers(n),'transparent');
 assert.equal(backgroundLayers(n,true),'transparent');
 // A real notification must still paint its panel; never hide the entire idle phase.
 n.dataset.act='full';n.dataset.shape='';
 assert(backgroundLayers(n).includes('--perch-gradient'));
 console.log('PASS resting notch is transparent before first snapshot and on both display types; open cards and notifications retain gradients');
} finally {await w.happyDOM.abort();await w.happyDOM.close();}
