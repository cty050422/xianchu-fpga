import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
function boot(){
  const make=dataset=>({dataset,events:{},attrs:{},hidden:false,focus(){this.focused=true},
    setAttribute(k,v){this.attrs[k]=v},addEventListener(k,fn){this.events[k]=fn}});
  const tabs=['performance','controls','device'].map(view=>make({view}));
  const els=Object.fromEntries(['performancePanel','controlsPanel','devicePanel','presentationButton'].map(id=>[id,make({})]));
  const classes=new Set();
  const document={querySelectorAll:()=>tabs,getElementById:id=>els[id],documentElement:{classList:{
    toggle(c){if(classes.has(c)){classes.delete(c);return false}classes.add(c);return true}}}};
  vm.runInNewContext(fs.readFileSync(new URL('./studio.mjs',import.meta.url),'utf8'),{document});
  return {tabs,els,classes};
}
test('only one workspace is visible and keyboard navigation selects/focuses it',()=>{
  const f=boot();assert.equal(f.els.performancePanel.hidden,false);assert.equal(f.els.devicePanel.hidden,true);
  let prevented=false;f.tabs[0].events.keydown({key:'End',preventDefault(){prevented=true}});
  assert.equal(prevented,true);assert.equal(f.tabs[2].focused,true);assert.equal(f.els.devicePanel.hidden,false);
  assert.equal(f.els.performancePanel.hidden,true);assert.equal(f.tabs[2].attrs['aria-selected'],'true');
  f.tabs[2].events.keydown({key:'ArrowRight',preventDefault(){}});
  assert.equal(f.els.performancePanel.hidden,false);assert.equal(f.tabs[0].tabIndex,0);
});
test('presentation mode is reversible and needs no device/fullscreen permission',()=>{
  const f=boot(),button=f.els.presentationButton;
  button.events.click({currentTarget:button});assert.equal(f.classes.has('presentation'),true);
  assert.equal(button.attrs['aria-pressed'],'true');
  button.events.click({currentTarget:button});assert.equal(f.classes.size,0);
});
