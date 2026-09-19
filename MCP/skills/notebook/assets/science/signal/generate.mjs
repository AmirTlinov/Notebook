#!/usr/bin/env node
// Run with the pinned tsx loader. Data are author assets, not a runtime computation.
import {writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {count,sampleRate,binSize,seed,impulseIndex,generateSamples,envelope} from './model.ts';
const samples=generateSamples(),overview=envelope(samples);
const encode=values=>{const bytes=Buffer.alloc(values.length*4);values.forEach((value,i)=>bytes.writeFloatLE(value,i*4));return bytes};
const raw=encode(samples),bins=encode(overview);
await writeFile(new URL('data.bin',import.meta.url),raw);
await writeFile(new URL('overview.bin',import.meta.url),bins);
await writeFile(new URL('data.json',import.meta.url),JSON.stringify({format:1,count,sampleRate,binSize,seed,impulseIndex,
  encoding:'float32-le',unit:'arbitrary',model:'exp(-t/55)*(sin(2*pi*2*t)+0.3*sin(2*pi*7*t))+uniform[-0.08,0.08]; additive impulse [1.4,2.5,1.4]',
  sha256:createHash('sha256').update(raw).digest('hex')},null,2)+'\n');
