#!/bin/bash
# Confirm a crash report is THE target BNNS crash, not some other bug.
# STRICT: all markers must be ON THE FAULTING THREAD. An earlier version OR'd
# markers across every thread and produced a false positive, because unrelated
# threads legitimately carry BNNS frames while other Core ML work is in flight.
# usage: check_signature.sh <report.ips>
python3 - "$1" <<'PY'
import json,sys
raw=open(sys.argv[1]).read(); head,_,body=raw.partition("\n")
try: h=json.loads(head)
except Exception: h={}
d=json.loads(body); imgs=d.get("usedImages",[])
def nm(i):
    try: return imgs[i].get("name","?")
    except Exception: return "?"
ft=d["faultingThread"]; ths=d["threads"]
fblob=" | ".join([(f.get("symbol") or "")+" @"+nm(f.get("imageIndex",-1)) for f in ths[ft].get("frames",[])])
checks={
 "faulting queue == com.apple.e5rt.concurrentExecutionQueue": ths[ft].get("queue")=="com.apple.e5rt.concurrentExecutionQueue",
 "_platform_memmove on faulting thread": "_platform_memmove" in fblob,
 "BNNSGraphContextExecute_v2 on faulting thread": "BNNSGraphContextExecute_v2" in fblob,
 "BnnsCpuInferenceOperation on faulting thread": "BnnsCpuInferenceOperation" in fblob,
}
print(f"{sys.argv[1].split('/')[-1]}  os={h.get('os_version')}")
print("  exception:", d["exception"].get("type"), d["exception"].get("signal"), "|", d["exception"].get("subtype"))
print("  faulting thread queue:", ths[ft].get("queue"))
for k,v in checks.items(): print(f"  {'YES' if v else 'NO ':<4} {k}")
print("  VERDICT:", "TARGET SIGNATURE" if all(checks.values()) else "DIFFERENT CRASH (report separately, do not count)")
PY
