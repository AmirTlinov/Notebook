/** The surface computes in memory: no files, sockets, arguments or environment. */
export function surfaceWasi(memory:()=>WebAssembly.Memory) {
  const view=()=>new DataView(memory().buffer);
  const empty=(count:number,bytes:number)=>{view().setUint32(count,0,true);view().setUint32(bytes,0,true);return 0;};
  const badDescriptor=()=>8;
  return {
    args_get:()=>0,args_sizes_get:empty,environ_get:()=>0,environ_sizes_get:empty,
    clock_res_get:(_clock:number,result:number)=>{view().setBigUint64(result,1_000n,true);return 0;},
    clock_time_get:(clock:number,_precision:bigint,result:number)=>{
      if(clock!==0&&clock!==1)return 28;
      view().setBigUint64(result,BigInt(Math.floor((clock===0?Date.now():performance.now())*1e6)),true);return 0;
    },
    random_get:(pointer:number,size:number)=>{
      for(let i=0;i<size;i+=65_536)crypto.getRandomValues(new Uint8Array(memory().buffer,pointer+i,Math.min(65_536,size-i)));
      return 0;
    },
    fd_fdstat_get:(fd:number,pointer:number)=>{
      if(fd!==1&&fd!==2)return 8;
      new Uint8Array(memory().buffer,pointer,24).fill(0);view().setUint8(pointer,2);return 0;
    },
    fd_write:(fd:number,iovs:number,count:number,written:number)=>{
      if(fd!==1&&fd!==2)return 8;
      let size=0;
      for(let i=0;i<count;i++){
        const v=view(),pointer=v.getUint32(iovs+i*8,true),length=v.getUint32(iovs+i*8+4,true);
        console.error(new TextDecoder().decode(new Uint8Array(memory().buffer,pointer,length)));size+=length;
      }
      view().setUint32(written,size,true);return 0;
    },
    fd_close:badDescriptor,fd_read:badDescriptor,fd_seek:badDescriptor,
    fd_prestat_get:badDescriptor,fd_prestat_dir_name:badDescriptor,
    path_open:()=>76,poll_oneoff:()=>58,
    proc_exit:(code:number)=>{throw new Error(`NotebookSurface exited (${code})`);},
  };
}
