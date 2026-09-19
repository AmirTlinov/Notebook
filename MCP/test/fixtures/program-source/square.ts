import {square} from './model';
const scope=self as DedicatedWorkerGlobalScope;
scope.onmessage=(event:MessageEvent<number>)=>scope.postMessage(square(event.data));
