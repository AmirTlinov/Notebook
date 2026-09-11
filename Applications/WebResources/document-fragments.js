(() => {
  'use strict';

  // The browser that measured a source supplies the physical cut. This compiler
  // copies its DOM values, not another markdown rendering or another page order.
  const maximumNodes = 16_384;
  const maximumUTF8Bytes = 4 * 1024 * 1024;
  const atomicTags = new Set(['img', 'svg', 'mjx-container', 'br', 'hr']);
  const cellTags = new Set(['td', 'th']);

  const create = async (root, geometry, isCancelled) => {
    const {sourceKey, pageCount, width, height, stride, originX, originY, contentTop, contentBottom, regions} = geometry;
    if (typeof sourceKey !== 'string' || !Number.isInteger(pageCount) || pageCount < 1 || pageCount > 4096
      || ![width,height,stride,originX,originY].every(Number.isFinite) || width<=0 || height<=0 || stride<width
      || !Array.isArray(regions)) throw new Error('document_fragment_invalid_geometry');
    const segmenter=new Intl.Segmenter('und',{granularity:'grapheme'});
    const range=document.createRange(), listValues=new WeakMap(), entries=new WeakMap(), tableColumns=new WeakMap();
    const regionsByPage=new Map();
    for(const region of regions) {
      if(!Number.isInteger(region.pageIndex)||region.pageIndex<0||region.pageIndex>=pageCount)throw new Error('document_fragment_invalid_geometry');
      if(!regionsByPage.has(region.pageIndex))regionsByPage.set(region.pageIndex,[]);
      regionsByPage.get(region.pageIndex).push(region);
    }
    // Index the measured DOM once. A table page visits its own rows, not every
    // row before and after it. Atomic SVG/MathJax trees keep one physical address.
    const rootEntry={node:root,childrenByPage:new Map()}, stack=[];
    for(let index=root.childNodes.length-1;index>=0;index--)stack.push({node:root.childNodes[index],parent:rootEntry});
    let indexedNodes=0,indexedEdges=0,anchorBytes=0;
    const anchors=new Map();
    // This bounded DOM walk yields an actual browser task, not a chained timer.
    // Hidden WebKit timer throttling must not become part of source layout time.
    // The source owns exactly one channel and closes it on completion or refusal.
    const channel=new MessageChannel();
    let resumeYield=null;
    channel.port1.onmessage=()=>{const resume=resumeYield;resumeYield=null;resume?.()};
    const yieldToBrowser=()=>new Promise(resolve=>{resumeYield=resolve;channel.port2.postMessage(null)});
    try {
      while(stack.length) {
        if(isCancelled())throw new Error('document_source_preparation_cancelled');
        const job=stack.pop();
        if(job.entry) {
          const {entry,parent}=job;
          // A row group or display-contents ancestor need not expose a rect for
          // every child page. The children's physical addresses still belong to it.
          for(const page of new Set([...entry.pages.keys(),...entry.childrenByPage.keys()])) {
            if(++indexedEdges>524288)throw new Error('document_fragment_index_budget');
            if(!parent.childrenByPage.has(page))parent.childrenByPage.set(page,[]);
            parent.childrenByPage.get(page).push(entry);
          }
          continue;
        }
        const {node,parent}=job;
        if(++indexedNodes>262144)throw new Error('document_fragment_index_budget');
        let rects;
        if(node.nodeType===Node.TEXT_NODE){range.selectNodeContents(node);rects=[...range.getClientRects()]}
        else if(node.nodeType===Node.ELEMENT_NODE)rects=[...node.getClientRects()];
        else continue;
        const pages=new Map();
        for(const rect of rects) {
          const page=Math.max(0,Math.floor((rect.x-originX)/stride));
          if(page>=pageCount || rect.width<=0 || rect.height<=0)continue;
          if(!pages.has(page))pages.set(page,[]);
          pages.get(page).push(rect);
        }
        const entry={node,pages,childrenByPage:new Map()};
        entries.set(node,entry);
        // A link names the original DOM, not whichever page fragment happens
        // to be mounted. Include zero-width named anchors and keep the first
        // occurrence of duplicate HTML IDs, just as the source document does.
        if(node.nodeType===Node.ELEMENT_NODE && !node.closest('svg,mjx-container')) {
          const rect=rects[0];
          const page=rect && Math.max(0,Math.floor((rect.x-originX)/stride));
          if(Number.isInteger(page)&&page<pageCount)for(const name of [node.id,node.localName==='a'&&node.getAttribute('name')]) {
            if(!name || anchors.has(name))continue;
            const bytes=new TextEncoder().encode(name).length;
            anchorBytes+=bytes;
            if(bytes>4096||anchors.size>=16384||anchorBytes>1024*1024)throw Error('document_link_index_budget');
            anchors.set(name,page);
          }
        }
        if(node.nodeType===Node.ELEMENT_NODE&&cellTags.has(node.localName)) {
          const table=node.closest('table'), tableEntry=entries.get(table);
          const first=pages.entries().next().value;
          const tableRect=first&&tableEntry?.pages.get(first[0])?.[0], cellRect=first?.[1][0];
          if(tableRect&&cellRect) {
            if(!tableColumns.has(table))tableColumns.set(table,new Set());
            const edges=tableColumns.get(table);
            edges.add(cellRect.x-tableRect.x);edges.add(cellRect.right-tableRect.x);
          }
        }
        stack.push({entry,parent});
        if(node.nodeType===Node.ELEMENT_NODE&&!atomicTags.has(node.localName)) {
          for(let index=node.childNodes.length-1;index>=0;index--)stack.push({node:node.childNodes[index],parent:entry});
        }
        if(indexedNodes%256===0)await yieldToBrowser();
      }
    } finally {
      channel.port1.onmessage=null;
      channel.port1.close();channel.port2.close();
    }

    // HTML counters belong to their original list, including explicit resets
    // and reversed lists. Removing preceding items does not renumber a fragment.
    for (const list of root.querySelectorAll('ol')) {
      const items = [...list.children].filter(node => node.localName === 'li');
      let value = list.hasAttribute('start') ? list.start : list.reversed ? items.length : 1;
      for (const item of items) {
        if (item.hasAttribute('value')) value = item.value;
        listValues.set(item, value);
        value += list.reversed ? -1 : 1;
      }
    }

    const compile = pageIndex => {
      if(!Number.isInteger(pageIndex)||pageIndex<0||pageIndex>=pageCount||isCancelled())throw new Error('document_fragment_page_mismatch');
      const pageRegions=regionsByPage.get(pageIndex)||[];
      const left=originX+pageIndex*stride,right=left+width;
      const tablePlacements=[],rowPlacements=new Map(),blockContentPlacements=[],cellPlacements=[],textAnchors=new WeakMap();
      let nodeCount=0,visitedNodes=0;
      const admit=count=>{nodeCount+=count;if(nodeCount>maximumNodes)throw new Error('document_fragment_node_budget')};
      const cut=entry=>entry.pages.get(pageIndex)?.[0];

    // Prefix bounds are monotone in the horizontal page flow. A cut can start
    // inside one text node; no off-page paragraph or source string is copied.
    const boundary = (node, edge) => {
      let low = 1, high = node.length + 1;
      while (low < high) {
        const mid = Math.floor((low + high) / 2);
        range.setStart(node, 0); range.setEnd(node, mid);
        if (range.getBoundingClientRect().right > edge) high = mid;
        else low = mid + 1;
      }
      return low - 1;
    };

    const extract = entry => {
      const node=entry.node;
      visitedNodes+=1;
      if (node.nodeType === Node.TEXT_NODE) {
        // A vertically aligned table cell may continue across columns while
        // its complete text occupies only one. WebKit's partial-range bounds
        // can then refer to the first cell fragment; the measured whole-text
        // address, not a synthetic prefix, owns that indivisible text node.
        const whole = entry.pages.size === 1;
        const start = whole ? 0 : boundary(node, left), end = whole ? node.length : boundary(node, right);
        if (end <= start) return null;
        admit(1);
        const clone=document.createTextNode(node.data.slice(start,end));
        const length=segmenter.segment(clone.data)[Symbol.iterator]().next().value.segment.length;
        range.setStart(node,start);range.setEnd(node,start+length);
        const first=[...range.getClientRects()].find(rect=>rect.width>0&&rect.height>0&&rect.x>=left&&rect.x<right);
        if(first)textAnchors.set(clone,{y:first.y-originY,length});
        return clone;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return null;
      if (atomicTags.has(node.localName)) {
        if (!cut(entry)) return null;
        // Admit an indivisible SVG/MathJax/image before allocating its clone.
        let count = 1;
        const descendants = document.createTreeWalker(node, NodeFilter.SHOW_ALL);
        while (descendants.nextNode()) {
          count += 1;
          if (count + nodeCount > maximumNodes) throw new Error('document_fragment_node_budget');
        }
        admit(count);
        const clone=node.cloneNode(true);
        if(node.localName==='mjx-container') {
          // MathJax's local font cache belongs to this physical copy. Reusing
          // the source's IDs binds <use> to another SVG and invalidates glyphs
          // throughout the still-measured book every time a page is mounted.
          const names=new Map();
          for(const glyph of clone.querySelectorAll('[id]')) {
            const previous=glyph.id;
            if(names.has(previous))throw new Error('document_fragment_duplicate_glyph');
            const next=`nb-${sourceKey}-${pageIndex}-${nodeCount}-${names.size}`;
            names.set(previous,next);glyph.id=next;
          }
          for(const glyph of clone.querySelectorAll('*'))for(const attribute of [...glyph.attributes]) {
            const next=attribute.value.startsWith('#')&&names.get(attribute.value.slice(1));
            if(next)glyph.setAttributeNS(attribute.namespaceURI,attribute.name,'#'+next);
          }
        }
        return clone;
      }
      const children = [];
      for (const child of entry.childrenByPage.get(pageIndex)||[]) { const part = extract(child); if (part) children.push(part); }
      const physicalCut = cut(entry);
      const isProgram = node.dataset.kind === 'interactive';
      if (!children.length && !(cellTags.has(node.localName) && physicalCut) && !(isProgram && physicalCut)) return null;
      admit(1);
      const clone = node.cloneNode(false);
      if (node.localName === 'li') {
        if (listValues.has(node)) clone.value = listValues.get(node);
        const first = entry.pages.values().next().value?.[0];
        if (first && first.right <= left) clone.style.listStyleType = 'none';
      }
      if (node.localName === 'table') {
        clone.style.tableLayout = 'fixed';
        // A continuation can begin with just a rowspan owner or a colspan.
        // Its first visible row cannot infer the missing source columns.
        const edges=[...(tableColumns.get(node)||[])].sort((a,b)=>a-b);
        if(edges.length>1) {
          admit(edges.length);
          const columns=document.createElement('colgroup');
          for(let index=1;index<edges.length;index++) {
            const column=document.createElement('col');column.style.width=`${edges[index]-edges[index-1]}px`;columns.append(column);
          }
          clone.append(columns);
        }
        if (physicalCut) tablePlacements.push({clone, x:physicalCut.x - left, y:physicalCut.y - originY});
      }
      if(node.localName==='tr'&&physicalCut) {
        const table=node.closest('table');
        if(!rowPlacements.has(table))rowPlacements.set(table,[]);
        rowPlacements.get(table).push({clone,y:physicalCut.y-originY});
      }
      if (cellTags.has(node.localName) && physicalCut) {
        const pages=[...entry.pages.keys()];
        Object.assign(clone.style, {width:`${physicalCut.width}px`, minWidth:`${physicalCut.width}px`,
          maxWidth:`${physicalCut.width}px`, height:`${physicalCut.height}px`});
        if (pages.length > 1) {
          clone.style.paddingTop = '0'; clone.style.paddingBottom = '0';clone.style.verticalAlign='top';
          if (pageIndex > pages[0]) clone.style.borderTopWidth = '0';
          if (pageIndex < pages[pages.length-1]) clone.style.borderBottomWidth = '0';
        }
      }
      clone.append(...children);
      if(node.parentNode===root && children.length) {
        const first=(entry.childrenByPage.get(pageIndex)||[]).find(value=>value.node.nodeType===Node.ELEMENT_NODE);
        const childRect=first && cut(first), sectionRect=cut(entry);
        if(childRect&&sectionRect&&clone.firstElementChild) {
          const style=getComputedStyle(node), inset=parseFloat(style.paddingTop)+parseFloat(style.borderTopWidth);
          clone.firstElementChild.style.marginTop=`${Math.max(0,childRect.y-sectionRect.y-inset)}px`;
          const target={clone:clone.firstElementChild,y:childRect.y-originY};
          const text=document.createTreeWalker(target.clone,NodeFilter.SHOW_TEXT);
          while(text.nextNode())if(textAnchors.has(text.currentNode)) {
            // A continued line keeps the original paragraph's baseline,
            // including fallback-font ascent from the preceding column.
            // Tables instead place each measured cell in their own grid.
            if(!text.currentNode.parentElement.closest('table'))Object.assign(target,{anchor:text.currentNode,...textAnchors.get(text.currentNode)});
            break;
          }
          blockContentPlacements.push(target);
        }
      }
      if(cellTags.has(node.localName)&&entry.pages.size>1) {
        const text=document.createTreeWalker(clone,NodeFilter.SHOW_TEXT);
        while(text.nextNode())if(textAnchors.has(text.currentNode)) {
          cellPlacements.push({clone,anchor:text.currentNode,...textAnchors.get(text.currentNode)});break;
        }
      }
      return clone;
    };

    const measurement = document.createElement('div');
    measurement.className = 'document-content';
    measurement.setAttribute('aria-hidden', 'true');
    Object.assign(measurement.style, {position:'absolute', left:'0', top:'0', visibility:'hidden',
      width:`${width}px`, height:`${height}px`, pointerEvents:'none'});
    try {
      const byID = new Map(pageRegions.map(region => [region.id, region]));
      const blockIDs = [];
      for (const entry of rootEntry.childrenByPage.get(pageIndex)||[]) {
        const section=entry.node;
        const region = byID.get(section.dataset.blockId);
        if (!region) continue;
        const clone = extract(entry);
        if (!clone) continue;
        // Text glyphs may overhang their line box. Only the physical paper
        // clips them; clipping every block would shave off its first glyphs.
        Object.assign(clone.style, {position:'absolute', left:`${region.x}px`, top:`${region.y}px`,
          width:`${region.width}px`, height:`${region.height}px`, margin:'0', overflow:'visible'});
        measurement.append(clone);
        blockIDs.push(section.dataset.blockId);
      }
      // Keep the source's exact inherited typography. A computed line-height
      // string is a rounded length, not its original unitless font relation;
      // copying it changes the baseline when this DOM is installed on a page.
      root.parentElement.append(measurement);
      const base = measurement.getBoundingClientRect();
      for(const target of blockContentPlacements) {
        let actual=target.clone.getBoundingClientRect();
        if(target.anchor) {
          range.setStart(target.anchor,0);range.setEnd(target.anchor,target.length);
          actual=[...range.getClientRects()].find(rect=>rect.width>0&&rect.height>0)||actual;
        }
        const margin=parseFloat(getComputedStyle(target.clone).marginTop);
        target.clone.style.marginTop=`${margin+target.y-(actual.y-base.y)}px`;
      }
      for (const target of tablePlacements) {
        const actual = target.clone.getBoundingClientRect();
        Object.assign(target.clone.style, {position:'relative',
          left:`${target.x - (actual.x - base.x)}px`, top:`${target.y - (actual.y - base.y)}px`});
      }
      for(const rows of rowPlacements.values())for(let index=0;index+1<rows.length;index++) {
        const row=rows[index],next=rows[index+1];
        if(next.y<=row.y)continue;
        // A td's fragmented box may overhang the following row. Preserve the
        // source grid's next boundary, rather than enlarging that row on reuse.
        for(const cell of row.clone.cells)if(cell.rowSpan===1) {
          cell.style.height=`${Math.min(parseFloat(cell.style.height),next.y-row.y)}px`;
        }
      }
      for(const target of cellPlacements) {
        range.setStart(target.anchor,0);range.setEnd(target.anchor,target.length);
        const actual=[...range.getClientRects()].find(rect=>rect.width>0&&rect.height>0);
        if(actual)target.clone.style.paddingTop=`${target.y-(actual.y-base.y)}px`;
      }
      const html = measurement.innerHTML;
      const utf8Bytes = new TextEncoder().encode(html).length;
      if (utf8Bytes > maximumUTF8Bytes) throw new Error('document_fragment_byte_budget');
      return {format:1, sourceKey, pageIndex, width, height, contentTop, contentBottom, blockIDs, regions:pageRegions, html, nodeCount, utf8Bytes, visitedNodes};
    } finally { measurement.remove(); }
    };
    return Object.freeze({compile,anchors:[...anchors].map(([name,pageIndex])=>({name,pageIndex}))});
  };

  window.notebookDocumentFragments = Object.freeze({create});
})();
