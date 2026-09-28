#!/usr/bin/env python3
"""Summarize tool arrays produced by measure_tool_surface.escript."""
import json,re,pathlib,hashlib,sys
root=pathlib.Path(sys.argv[1])
source=pathlib.Path("packages/tools/src/tools/prelude.gleam").read_text().split("pub const type_surfaces:")[1]
pattern=r'#\(\s*("(?:[^"\\]|\\.)*"),\s*("(?:[^"\\]|\\.)*"),?\s*\)'
surfaces=dict((json.loads(a,strict=False),json.loads(b,strict=False)) for a,b in re.findall(pattern,source))
results=[]
for label in ["workspace-effects","orchestration-full","both-full"]:
 tools=json.loads((root/f"loom-tools-{label}-request.json").read_text())["tools"]
 serialized=json.dumps(tools,ensure_ascii=False,separators=(",",":"))
 (root/f"loom-tools-{label}-array.json").write_text(serialized)
 desc=next(t["description"] for t in tools if t["name"]=="code_mode")
 selected={n:t for n,t in surfaces.items() if t and t in desc}
 typ=sum(len(t) for t in selected.values())
 r=dict(profile=label,count=len(tools),bytes=len(serialized.encode()),characters=len(serialized),estimate_low=len(serialized)/4,estimate_high=len(serialized)/3,description_characters=len(desc),type_characters=typ,type_share=typ/len(desc),type_modules=list(selected),sha256=hashlib.sha256(serialized.encode()).hexdigest(),names=[t["name"] for t in tools])
 results.append(r)
 print(json.dumps(r))
(root/"loom-tools-measurements.json").write_text(json.dumps(results,indent=2))
