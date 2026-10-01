import type { WorldPoint } from "../src/domain.js";
import type { SceneBounds } from "../src/spatial.js";

export type Point={x:number;y:number};
export type Frame=Point&{width:number;height:number};
export type PanelTarget={kind:"board"|"page";id:string};
export type PanelAddress={workspaceID:string;target:PanelTarget;socketKey:string};
export type NativeElement=Record<string,unknown>&{
  id:string;kind:string;frame:Frame;worldOrigin?:WorldPoint;source:string;
  graphic?:Record<string,any>;textStyle?:Record<string,number>;
};
export type Resolution={state:string;frame?:Frame;worldOrigin?:WorldPoint;label?:Point;
  curves?:{start:Point;control1:Point;control2:Point;end:Point}[];
  heads?:{points:Point[];filled:boolean;closed:boolean}[];
  projection?:{size:{width:number;height:number};transform:{a:number;b:number;c:number;d:number;tx:number;ty:number}};
};
export type PanelElement={source:NativeElement;graphicResolution?:Resolution;appearance?:unknown};
export type PanelCard={item:{id:string;kind:string;title:string;[key:string]:unknown};center:WorldPoint;stackID?:string};
export type PanelSnapshot=PanelAddress&{worldOrigin:WorldPoint|null;size:{width:number;height:number};
  elements:PanelElement[];cards:PanelCard[];rawInkPresent:boolean;
  unsupportedElements:{id:string;kind:string;reason:string}[];cursor:string;
  history:{undoActionID?:string};truncated:boolean};
export type PanelOperation={kind:"insertElement"|"updateElement"|"removeElement";target:PanelTarget;id:string;values:Record<string,unknown>};
export type PanelSource={id:string;page?:NativeElement;spatial?:NativeElement};
export type PanelMutation=PanelAddress&{actionID:string;summary:string;operations:PanelOperation[];sources:PanelSource[]};
export type Camera={x:number;y:number;scale:number};
export type PanelRead=PanelAddress&{bounds?:SceneBounds;knownCursor?:string};

export function capturedSource(target:PanelTarget,source:NativeElement):PanelSource {
  return target.kind==="page"?{id:source.id,page:source}:{id:source.id,spatial:source};
}
