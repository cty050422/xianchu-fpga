// App-owned lease. KEEP renews an existing authenticated grant; it never ARM's.
function createControlLease({setTimer=setTimeout,clearTimer=clearTimeout,now=Date.now}={}){
 let driver=null,authorized=false,suspended=false,timer=null,revision=0,pendingGrant=null;
 function cancel(){if(timer!==null)clearTimer(timer);timer=null;}
 function schedule(){cancel();if(!driver||!authorized||suspended)return;
  const rev=revision;timer=setTimer(async()=>{timer=null;if(rev!==revision||!authorized||suspended)return;
   try{await driver.keepAlive();}catch(e){if(rev===revision){authorized=false;if(driver.onExpired)driver.onExpired(e);}}
   if(rev===revision)schedule();
  },5000);if(timer&&timer.unref)timer.unref();
 }
 return {bind(next){cancel();revision++;driver=next;authorized=!!(pendingGrant&&pendingGrant.generation===next.generation&&pendingGrant.ok);pendingGrant=null;schedule();},
  authorize(generation,ok){if(!driver){pendingGrant={generation,ok:!!ok};return;}if(driver.generation!==generation)return;authorized=!!ok;schedule();},
  suspend(){suspended=true;cancel();},resume(){suspended=false;
   if(driver&&driver.reconcile){const rev=revision;cancel();Promise.resolve(driver.reconcile()).then(ok=>{if(rev===revision){authorized=!!ok;schedule();}}).catch(()=>{if(rev===revision){authorized=false;cancel();}});}
   else schedule();},
  close(){revision++;cancel();driver=null;pendingGrant=null;authorized=false;},snapshot:()=>({authorized,suspended,generation:driver&&driver.generation,at:now()})};
}
module.exports={createControlLease};
