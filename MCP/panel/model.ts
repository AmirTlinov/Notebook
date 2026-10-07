import type { WorldPoint } from "../src/domain.js";

export type Point={x:number;y:number};
export type Frame=Point&{width:number;height:number};
export type PanelTarget={kind:"board"|"page";id:string};
export type PanelAddress={workspaceID:string;target:PanelTarget;socketKey:string};
export type PanelCheckpoint={id:string;epoch:string;readCursor:string;changeCursor:string};
export type PanelChanges=PanelAddress&{checkpoint:PanelCheckpoint;changed:boolean;reset?:boolean};

export function isPanelCheckpoint(value:unknown):value is PanelCheckpoint {
  if(!value||typeof value!=="object"||Array.isArray(value))return false;
  const checkpoint=value as Record<string,unknown>;
  const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const cursor=(value:unknown)=>typeof value==="string"&&/^(0|[1-9]\d{0,18})$/.test(value)
    &&BigInt(value)<=9_223_372_036_854_775_807n;
  return typeof checkpoint.id==="string"&&uuid.test(checkpoint.id)
    &&typeof checkpoint.epoch==="string"&&uuid.test(checkpoint.epoch)
    &&cursor(checkpoint.readCursor)&&cursor(checkpoint.changeCursor);
}
export type NativeElement=Record<string,unknown>&{
  id:string;kind:string;frame:Frame;worldOrigin?:WorldPoint;source:string;
  graphic?:Record<string,any>;textStyle?:Record<string,unknown>&{fontSize?:number;weight?:number;format?:unknown;runs?:unknown[]};
};
export type Resolution={state:string;frame?:Frame;worldOrigin?:WorldPoint;label?:Point;
  curves?:{start:Point;control1:Point;control2:Point;end:Point}[];
  heads?:{points:Point[];filled:boolean;closed:boolean}[];
  projection?:{size:{width:number;height:number};transform:{a:number;b:number;c:number;d:number;tx:number;ty:number}};
};
export type PanelElement={source:NativeElement;graphicResolution?:Resolution;appearance?:unknown;editable?:boolean};
export type PanelSelection={kind:"element"|"item";id:string};
export type PlacementSource={id:string;placements:Record<string,unknown>[]};
export type PanelCard={item:{id:string;kind:string;title:string;[key:string]:unknown};center:WorldPoint;stackID?:string;
  frame?:Frame;worldOrigin?:WorldPoint;source?:PlacementSource;editable?:boolean};
export type PanelView={viewport:{x:number;y:number};pixelScale:number;camera?:{center:WorldPoint;scale:number}};
export type AppearanceLayer={id:string;order:number;worldOrigin:WorldPoint;frame:Frame;
  pixelWidth:number;pixelHeight:number;assetID:string;pngBase64?:string;sha256?:string;elementID?:string;itemID?:string;
  subjectFrame?:Frame;repeatSize?:{width:number;height:number}};
export type PanelAppearance={status:"ready"|"pending"|"error";requestID:string;sourceRevision:string;
  camera:{center:WorldPoint;scale:number};viewport:{x:number;y:number};layers:AppearanceLayer[];
  coverage?:{anchor:WorldPoint;region:Frame;level:number;pixelDensity:number};
  diagnostics?:{message?:string;[key:string]:unknown}[]};
export type PanelSnapshot=PanelAddress&{worldOrigin:WorldPoint|null;size:{width:number;height:number};
  elements:PanelElement[];cards:PanelCard[];rawInkPresent:boolean;
  unsupportedElements:{id:string;kind:string;reason:string}[];cursor:string;
  history:{undoActionID?:string};truncated:boolean;appearance?:PanelAppearance;checkpoint?:PanelCheckpoint;
  fitBounds?:{anchor:WorldPoint;region:Frame};
  navigation?:{parentBoard?:PanelTarget;itemID?:string;position?:{index:number;pageID:string};
    directory?:{header:{item:{title:string;pageCount:number}};pages:{position:{index:number;pageID:string}}[]}}};
export type PanelOperation={kind:"insertElement"|"updateElement"|"removeElement"|"moveItem"|"appendInkStroke";target:PanelTarget;id:string;values:Record<string,unknown>};
export type PanelSource={id:string;page?:NativeElement;spatial?:NativeElement;placements?:Record<string,unknown>[]};
export type PanelMutation=PanelAddress&{actionID:string;summary:string;operations:PanelOperation[];sources:PanelSource[]};
export type Camera={x:number;y:number;scale:number};

export function capturedSource(target:PanelTarget,source:NativeElement):PanelSource {
  return target.kind==="page"?{id:source.id,page:source}:{id:source.id,spatial:source};
}
