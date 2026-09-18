import assert from "node:assert/strict";
import test from "node:test";
import { presentationStepSchema } from "../src/presentation.js";
const reference={id:"c17e6b88-7e7a-4000-8000-000000000001",target:{kind:"board",id:"c17e6b88-7e7a-4000-8000-000000000002"},elementID:"shape",revision:"current"};
test("material attention is bounded and does not require a camera or SVG",()=>{
  assert.equal(presentationStepSchema.safeParse({attention:[reference]}).success,true);
  for(const attention of [[],Array(17).fill(reference),[{...reference,revision:""}], [{...reference,target:{...reference.target,kind:"workspace"}}]])
    assert.equal(presentationStepSchema.safeParse({attention}).success,false);
  const {elementID,...wholeBoard}=reference;
  assert.equal(presentationStepSchema.safeParse({attention:[wholeBoard]}).success,false);
  assert.equal(presentationStepSchema.safeParse({attention:[{...wholeBoard,region:{x:0,y:0,width:100,height:100}}]}).success,true);
});
